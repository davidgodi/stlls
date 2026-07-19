/**
 * STLLS Instagram publishing worker (Cloudflare Workers + R2) — TEMPLATE.
 *
 * Deploy with wrangler. Required bindings/config:
 *   vars:    IG_APP_ID, APP_REDIRECT   (e.g. "stlls://ig-connected")
 *   secrets: IG_APP_SECRET
 *   r2:      MEDIA  (bucket; add a lifecycle rule: delete objects after 1 day)
 *
 * Endpoints:
 *   GET  /auth               → redirects to Instagram's business OAuth dialog
 *   GET  /callback?code=…    → code → short token → long-lived token,
 *                              then redirects to APP_REDIRECT#token=…&user_id=…&expires=…
 *   POST /refresh            {token} → refreshed long-lived token
 *   POST /media  (image/jpeg body) → {url} temporary public URL for Meta to fetch
 *   GET  /m/:key             → serves an uploaded image (public, short-lived)
 *   POST /publish            {token, userId, images:[url…], caption, kind}
 *                            kind: "feed" (1 image), "carousel" (2–10), "story"
 *
 * The Instagram Graph host below is versioned — bump IG_GRAPH when Meta
 * deprecates the version.
 */

const IG_GRAPH = 'https://graph.instagram.com/v23.0';
const IG_OAUTH = 'https://www.instagram.com/oauth/authorize';
const IG_TOKEN = 'https://api.instagram.com/oauth/access_token';

const SCOPES = 'instagram_business_basic,instagram_business_content_publish';

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      if (url.pathname === '/auth') return auth(url, env);
      if (url.pathname === '/callback') return callback(url, env);
      if (url.pathname === '/refresh' && req.method === 'POST') return refresh(req, env);
      if (url.pathname === '/media' && req.method === 'POST') return upload(req, env, url);
      if (url.pathname.startsWith('/m/')) return serve(url, env);
      if (url.pathname === '/publish' && req.method === 'POST') return publish(req, env);
      return json({ error: 'not found' }, 404);
    } catch (e) {
      return json({ error: String(e?.message || e) }, 500);
    }
  },
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*' },
  });
}

// ── OAuth ────────────────────────────────────────────────────────────────────

function auth(url, env) {
  const redirect = `${url.origin}/callback`;
  const dialog = `${IG_OAUTH}?client_id=${env.IG_APP_ID}` +
    `&redirect_uri=${encodeURIComponent(redirect)}` +
    `&response_type=code&scope=${encodeURIComponent(SCOPES)}`;
  return Response.redirect(dialog, 302);
}

async function callback(url, env) {
  const code = url.searchParams.get('code');
  if (!code) return json({ error: 'missing code' }, 400);

  // code → short-lived token (needs the app secret — this is why we're a server)
  const form = new FormData();
  form.set('client_id', env.IG_APP_ID);
  form.set('client_secret', env.IG_APP_SECRET);
  form.set('grant_type', 'authorization_code');
  form.set('redirect_uri', `${url.origin}/callback`);
  form.set('code', code);
  const short = await (await fetch(IG_TOKEN, { method: 'POST', body: form })).json();
  if (!short.access_token) return json({ error: 'token exchange failed', detail: short }, 502);

  // short → long-lived (~60 days)
  const long = await (await fetch(
    `${IG_GRAPH}/access_token?grant_type=ig_exchange_token` +
    `&client_secret=${env.IG_APP_SECRET}&access_token=${short.access_token}`
  )).json();
  const token = long.access_token || short.access_token;
  const expires = long.expires_in || 3600;

  // hand everything back to the app via its custom scheme
  const back = `${env.APP_REDIRECT}#token=${encodeURIComponent(token)}` +
    `&user_id=${encodeURIComponent(short.user_id || '')}&expires=${expires}`;
  return Response.redirect(back, 302);
}

async function refresh(req, env) {
  const { token } = await req.json();
  const r = await (await fetch(
    `${IG_GRAPH}/refresh_access_token?grant_type=ig_refresh_token&access_token=${token}`
  )).json();
  return json(r, r.access_token ? 200 : 502);
}

// ── Temporary public media hosting (Meta fetches from these URLs) ────────────

async function upload(req, env, url) {
  const key = `${Date.now()}-${crypto.randomUUID()}.jpg`;
  await env.MEDIA.put(key, req.body, { httpMetadata: { contentType: 'image/jpeg' } });
  return json({ url: `${url.origin}/m/${key}` });
}

async function serve(url, env) {
  const key = url.pathname.slice(3);
  const obj = await env.MEDIA.get(key);
  if (!obj) return new Response('gone', { status: 404 });
  return new Response(obj.body, { headers: { 'content-type': 'image/jpeg' } });
}

// ── Publishing ───────────────────────────────────────────────────────────────

async function createContainer(env, userId, token, params) {
  const q = new URLSearchParams({ ...params, access_token: token });
  const r = await (await fetch(`${IG_GRAPH}/${userId}/media?${q}`, { method: 'POST' })).json();
  if (!r.id) throw new Error('container failed: ' + JSON.stringify(r));
  return r.id;
}

async function waitReady(env, id, token) {
  for (let i = 0; i < 30; i++) {
    const r = await (await fetch(`${IG_GRAPH}/${id}?fields=status_code&access_token=${token}`)).json();
    if (r.status_code === 'FINISHED') return;
    if (r.status_code === 'ERROR') throw new Error('container error');
    await new Promise(res => setTimeout(res, 1000));
  }
  throw new Error('container timed out');
}

async function publish(req, env) {
  const { token, userId, images, caption = '', kind = 'feed' } = await req.json();
  if (!token || !userId || !images?.length) return json({ error: 'bad request' }, 400);

  let creationId;
  if (kind === 'carousel') {
    const children = [];
    for (const img of images.slice(0, 10)) {
      children.push(await createContainer(env, userId, token, { image_url: img, is_carousel_item: 'true' }));
    }
    for (const c of children) await waitReady(env, c, token);
    creationId = await createContainer(env, userId, token, {
      media_type: 'CAROUSEL', children: children.join(','), caption,
    });
  } else if (kind === 'story') {
    creationId = await createContainer(env, userId, token, { media_type: 'STORIES', image_url: images[0] });
  } else {
    creationId = await createContainer(env, userId, token, { image_url: images[0], caption });
  }
  await waitReady(env, creationId, token);

  const q = new URLSearchParams({ creation_id: creationId, access_token: token });
  const pub = await (await fetch(`${IG_GRAPH}/${userId}/media_publish?${q}`, { method: 'POST' })).json();
  if (!pub.id) return json({ error: 'publish failed', detail: pub }, 502);
  return json({ id: pub.id });
}
