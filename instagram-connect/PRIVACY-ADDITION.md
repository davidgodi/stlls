# Privacy policy addition — publish BEFORE shipping "Connect to Instagram"

Add this section to https://davidgodi.github.io/stlls-privacy/ (the
stlls-privacy repo) when the Instagram connection feature ships. The current
"Open Instagram" shortcut needs **no** policy change — it only opens the
Instagram app and no data leaves the device.

---

## Instagram connection (optional)

STLLS lets you optionally connect an Instagram Professional (Business or
Creator) account so you can publish your exports directly from the app.

**What we access.** When you connect, Instagram (Meta) provides STLLS with
your Instagram account ID, username and an access token. The token is stored
only on your device, in the iOS Keychain. We do not run user accounts and we
do not store your Instagram credentials — the login happens on Instagram's
own pages.

**What we share.** When you tap "Share to Instagram", the images you chose to
publish are transferred over an encrypted connection to a temporary storage
endpoint we operate, solely so Instagram's servers can fetch them for
publishing. These files are deleted automatically within 24 hours and are not
used for anything else. Your images, caption and account token are then sent
to Meta's Instagram API to create the post. Meta's handling of that data is
governed by Meta's own Privacy Policy.

**What we don't do.** We do not read your Instagram messages, followers or
feed; we request only the permissions needed to publish
(`instagram_business_basic`, `instagram_business_content_publish`). We do not
sell or share your data with anyone else, and we do not use it for
advertising or tracking.

**Disconnecting.** You can disconnect Instagram at any time in STLLS
Settings, which deletes the stored token from your device. You can also
revoke STLLS's access in your Instagram app under
Settings → Website permissions / Apps.

---

Also update the intro list of collected data ("What STLLS collects") to
mention: *Instagram account ID and username, and the media you choose to
publish (only when you use the optional Instagram connection).*
