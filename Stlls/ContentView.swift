import SwiftUI
import WebKit
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import UserNotifications

// MARK: - JS → Swift bridge for image export

class ExportMessageHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "exportImage",
              let dataURL = message.body as? String else { return }

        let parts = dataURL.components(separatedBy: ",")
        guard parts.count == 2,
              let data = Data(base64Encoded: parts[1]),
              let image = UIImage(data: data) else {
            callback(false); return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                self?.callback(false); return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, _ in self?.callback(success) }
        }
    }

    private func callback(_ success: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(
                "window.exportComplete(\(success ? "true" : "false"))",
                completionHandler: nil
            )
        }
    }
}

// MARK: - WKURLSchemeHandler — serves local video files to WKWebView
//         Used for H.264 / HEVC so the browser can seek natively (fast).

class VideoSchemeHandler: NSObject, WKURLSchemeHandler {
    private var files: [String: URL] = [:]
    // Accessed only on the main queue — same queue stop() fires on, so no lock needed
    private var activeTasks = Set<ObjectIdentifier>()

    // Must be called on the main queue (matches where start/stop are called)
    func register(key: String, url: URL)  { files[key] = url }
    func unregister(key: String)          { files.removeValue(forKey: key) }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // Called on main queue
        let taskID = ObjectIdentifier(urlSchemeTask)
        activeTasks.insert(taskID)

        guard
            let reqURL = urlSchemeTask.request.url,
            let comps  = URLComponents(url: reqURL, resolvingAgainstBaseURL: false),
            let key    = comps.queryItems?.first(where: { $0.name == "k" })?.value,
            let fileURL = files[key]
        else {
            activeTasks.remove(taskID)
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Snapshot the range header now (on main) before going to background
        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            guard
                let attrs     = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                let totalSize = attrs[.size] as? Int
            else {
                DispatchQueue.main.async {
                    guard self.activeTasks.remove(taskID) != nil else { return }
                    urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
                }
                return
            }

            var start = 0, end = totalSize - 1, statusCode = 200
            var headers: [String: String] = [
                "Accept-Ranges": "bytes",
                "Content-Type":  fileURL.pathExtension.lowercased() == "mov"
                                   ? "video/quicktime" : "video/mp4",
            ]

            if let rangeHdr = rangeHeader, rangeHdr.hasPrefix("bytes=") {
                let parts = String(rangeHdr.dropFirst(6)).components(separatedBy: "-")
                start      = Int(parts[0]) ?? 0
                end        = (parts.count > 1 && !parts[1].isEmpty) ? (Int(parts[1]) ?? end) : end
                end        = min(end, totalSize - 1)
                statusCode = 206
                headers["Content-Range"] = "bytes \(start)-\(end)/\(totalSize)"
            }
            let length = end - start + 1
            headers["Content-Length"] = "\(length)"

            guard let response = HTTPURLResponse(
                url: reqURL, statusCode: statusCode,
                httpVersion: "HTTP/1.1", headerFields: headers
            ) else { return }

            // Read file data on background queue
            var data = Data()
            if let fh = try? FileHandle(forReadingFrom: fileURL) {
                try? fh.seek(toOffset: UInt64(start))
                data = fh.readData(ofLength: length)
                try? fh.close()
            }

            // Deliver response on main queue — same queue as stop(), so no race possible
            DispatchQueue.main.async {
                guard self.activeTasks.remove(taskID) != nil else { return }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Called on main queue — simply removing from the set is enough
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }
}

// MARK: - JS → Swift bridge for native video frame extraction

class VideoMessageHandler: NSObject, WKScriptMessageHandler, PHPickerViewControllerDelegate {

    weak var viewController: UIViewController?
    weak var webView: WKWebView?
    weak var schemeHandler: VideoSchemeHandler?

    private var assets:    [String: AVAsset] = [:]   // ProRes / heavy codecs
    private var tempFiles: [String: URL]     = [:]
    private var webKeys:   Set<String>       = []    // H.264 / HEVC web-served assets
    private var activeGenerators: [String: AVAssetImageGenerator] = [:]

    // MARK: Message routing

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "requestVideoSelection":
            DispatchQueue.main.async { self.presentVideoPicker() }
        case "extractVideoFrame":
            guard let body = message.body as? [String: Any] else { return }
            extractFrame(body)
        case "releaseVideoAsset":
            guard let key = message.body as? String else { return }
            releaseAsset(key)
        default: break
        }
    }

    // MARK: Video picker

    private func presentVideoPicker() {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.selectionLimit = 1
        cfg.filter = .videos
        // Deliver the original file as-is. The default (.automatic) transcodes
        // HEVC iPhone videos to H.264 for "compatibility", which adds ~3s before
        // the asset is handed over. WKWebView plays HEVC natively, so we don't
        // need that — .current skips the transcode and loads near-instantly.
        cfg.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        viewController?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let result = results.first,
              result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            sendToJS("window.nativeVideoReady(null)"); return
        }

        result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url else { self?.sendToJS("window.nativeVideoReady(null)"); return }

            // Hardlink (instant, no copy) or fall back to a full copy
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            do    { try FileManager.default.linkItem(at: url, to: dest) }
            catch { do    { try FileManager.default.copyItem(at: url, to: dest) }
                    catch { self?.sendToJS("window.nativeVideoReady(null)"); return } }

            let asset = AVURLAsset(url: dest)

            // Use modern async/await AVFoundation APIs (no deprecation warnings)
            Task { [weak self] in
                guard let self else { return }

                var duration = 0.0
                var w = 1920, h = 1080
                var fps: Float = 30.0
                var codec = ""

                // Load duration
                if let cmDur = try? await asset.load(.duration) {
                    duration = max(0, CMTimeGetSeconds(cmDur))
                }

                // Load video track properties
                if let tracks = try? await asset.loadTracks(withMediaType: .video),
                   let track  = tracks.first {

                    if let natSize  = try? await track.load(.naturalSize),
                       let prefXfrm = try? await track.load(.preferredTransform) {
                        let sz = natSize.applying(prefXfrm)
                        w = Int(abs(sz.width));  if w == 0 { w = Int(natSize.width) }
                        h = Int(abs(sz.height)); if h == 0 { h = Int(natSize.height) }
                    }

                    if let fRate = try? await track.load(.nominalFrameRate), fRate > 0 {
                        fps = fRate
                    }

                    // Codec detection — used to decide web vs native path
                    if let descs = try? await track.load(.formatDescriptions),
                       let desc  = descs.first {
                        let sub = CMFormatDescriptionGetMediaSubType(desc)
                        let bytes: [UInt8] = [
                            UInt8((sub >> 24) & 0xFF), UInt8((sub >> 16) & 0xFF),
                            UInt8((sub >> 8)  & 0xFF), UInt8( sub        & 0xFF),
                        ]
                        codec = String(bytes: bytes, encoding: .ascii) ?? ""
                    }
                }

                // Capture computed values as immutable lets before crossing
                // the actor boundary — required by Swift 6 strict concurrency.
                let finalDuration = duration
                let finalW        = w
                let finalH        = h
                let finalFps      = fps
                let useWebPath    = ["avc1", "hvc1", "hev1", "mp4v"].contains(codec)
                let key           = UUID().uuidString

                await MainActor.run {
                    self.tempFiles[key] = dest

                    let fileName = url.lastPathComponent
                    let jsCallback = "if (typeof window.nativeVideoReady === 'function') window.nativeVideoReady(payload)"

                    if useWebPath {
                        self.webKeys.insert(key)
                        self.schemeHandler?.register(key: key, url: dest)
                        let payload: [String: Any] = [
                            "webURL":    "stlls-video://v?k=\(key)",
                            "assetKey":  key,
                            "duration":  finalDuration,
                            "width":     finalW,
                            "height":    finalH,
                            "frameRate": finalFps,
                            "fileName":  fileName,
                        ]
                        self.webView?.callAsyncJavaScript(jsCallback,
                            arguments: ["payload": payload],
                            in: nil, in: .page, completionHandler: nil)
                    } else {
                        self.assets[key] = asset
                        let payload: [String: Any] = [
                            "assetKey":  key,
                            "duration":  finalDuration,
                            "width":     finalW,
                            "height":    finalH,
                            "frameRate": finalFps,
                            "fileName":  fileName,
                        ]
                        self.webView?.callAsyncJavaScript(jsCallback,
                            arguments: ["payload": payload],
                            in: nil, in: .page, completionHandler: nil)
                    }
                }
            }
        }
    }

    // MARK: Frame extraction (ProRes / native path)

    private func extractFrame(_ body: [String: Any]) {
        guard let assetKey = body["assetKey"] as? String,
              let time     = body["time"]     as? Double,
              let reqId    = body["requestId"] as? String else { return }

        let isPreview = body["preview"] as? Bool ?? false
        guard let asset = assets[assetKey] else { sendFrame(requestId: reqId, dataURL: nil); return }

        if isPreview {
            activeGenerators[assetKey]?.cancelAllCGImageGeneration()
            activeGenerators.removeValue(forKey: assetKey)
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let tol = CMTime(seconds: isPreview ? 1.0 : 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter  = tol
        if isPreview {
            gen.maximumSize = CGSize(width: 1280, height: 720)
            activeGenerators[assetKey] = gen
        }

        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: cmTime)]) { [weak self] _, cgImage, _, _, _ in
            var dataURL: String?
            if let cgImage {
                let quality: CGFloat = isPreview ? 0.75 : 0.90
                if let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: quality) {
                    dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
                }
            }
            DispatchQueue.main.async { [weak self] in
                if isPreview { self?.activeGenerators.removeValue(forKey: assetKey) }
                self?.sendFrame(requestId: reqId, dataURL: dataURL)
            }
        }
    }

    private func sendFrame(requestId: String, dataURL: String?) {
        let payload: [String: Any] = ["requestId": requestId, "dataURL": dataURL ?? NSNull()]
        webView?.callAsyncJavaScript(
            "if (typeof window.nativeVideoFrame === 'function') window.nativeVideoFrame(payload)",
            arguments: ["payload": payload],
            in: nil, in: .page, completionHandler: nil
        )
    }

    // MARK: Asset cleanup

    private func releaseAsset(_ key: String) {
        activeGenerators[key]?.cancelAllCGImageGeneration()
        activeGenerators.removeValue(forKey: key)
        if webKeys.remove(key) != nil {
            schemeHandler?.unregister(key: key)
        } else {
            assets.removeValue(forKey: key)
        }
        if let url = tempFiles.removeValue(forKey: key) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func sendToJS(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - JS → Swift bridge for scheduling local notifications

class RemindersMessageHandler: NSObject, WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "scheduleReminders",
              let body = message.body as? [String: Any] else { return }

        let frequency  = body["frequency"]  as? String ?? "off"
        let quietStart = body["quietStart"] as? Int    ?? 22
        let quietEnd   = body["quietEnd"]   as? Int    ?? 8

        var msgs: [(title: String, body: String)] = []
        if let rawMsgs = body["messages"] as? [[String: String]] {
            msgs = rawMsgs.compactMap { dict in
                guard let t = dict["title"], let b = dict["body"] else { return nil }
                return (title: t, body: b)
            }
        }

        let center = UNUserNotificationCenter.current()

        if frequency == "off" {
            center.removeAllPendingNotificationRequests()
            return
        }

        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            guard granted, let self else { return }
            center.removeAllPendingNotificationRequests()
            self.scheduleNotifications(
                center:      center,
                frequency:   frequency,
                messages:    msgs,
                quietStart:  quietStart,
                quietEnd:    quietEnd
            )
        }
    }

    private func scheduleNotifications(
        center:     UNUserNotificationCenter,
        frequency:  String,
        messages:   [(title: String, body: String)],
        quietStart: Int,
        quietEnd:   Int
    ) {
        guard !messages.isEmpty else { return }
        let count = messages.count   // 15

        if frequency == "test" {
            // Fire at 60 s, 120 s, 180 s … for easy testing
            for i in 0..<count {
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: TimeInterval((i + 1) * 60), repeats: false)
                let msg = messages[i % count]
                addRequest(center: center, id: "stlls-remind-\(i)",
                           title: msg.title, body: msg.body, trigger: trigger)
            }
            return
        }

        // Gap between notifications (seconds)
        let gapSeconds: Int
        switch frequency {
        case "daily":  gapSeconds = 86_400
        case "twice":  gapSeconds = 86_400 * 7 / 2   // 3.5 days
        case "weekly": gapSeconds = 86_400 * 7
        default:       gapSeconds = 86_400
        }

        // Delivery hour — just outside quiet window
        let safeHour = clampedHour(quietEnd + 2, quietStart: quietStart, quietEnd: quietEnd)

        let cal = Calendar.current
        var comps    = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = safeHour
        comps.minute = 0
        comps.second = 0
        var base = cal.date(from: comps) ?? Date()
        // Push to tomorrow if today's slot has already passed
        if base <= Date() {
            base = cal.date(byAdding: .day, value: 1, to: base) ?? base
        }

        for i in 0..<count {
            let fireDate  = base.addingTimeInterval(TimeInterval(i * gapSeconds))
            var fireComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            fireComps.second = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: fireComps, repeats: false)
            let msg     = messages[i % count]
            addRequest(center: center, id: "stlls-remind-\(i)",
                       title: msg.title, body: msg.body, trigger: trigger)
        }
    }

    // Clamps `hour` so it never falls inside the quiet window [quietStart, quietEnd)
    private func clampedHour(_ hour: Int, quietStart: Int, quietEnd: Int) -> Int {
        let h = ((hour % 24) + 24) % 24
        // Quiet window wraps midnight, e.g. 22–8: quiet if h >= 22 OR h < 8
        let inQuiet = quietStart > quietEnd
            ? (h >= quietStart || h < quietEnd)
            : (h >= quietStart && h < quietEnd)
        return inQuiet ? quietEnd + 2 : h
    }

    private func addRequest(
        center:  UNUserNotificationCenter,
        id:      String,
        title:   String,
        body:    String,
        trigger: UNNotificationTrigger
    ) {
        let content       = UNMutableNotificationContent()
        content.title     = title
        content.body      = body
        content.sound     = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request, withCompletionHandler: nil)
    }
}

// MARK: - UIViewController that hosts WKWebView

class WebViewController: UIViewController, WKUIDelegate, PHPickerViewControllerDelegate {

    private var webView: WKWebView!
    private let exportHandler    = ExportMessageHandler()
    private let videoHandler     = VideoMessageHandler()
    private let schemeHandler    = VideoSchemeHandler()
    private let remindersHandler = RemindersMessageHandler()
    private var filePickerCompletionHandler: (([URL]?) -> Void)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        setupWebView()
        loadApp()
    }

    private func setupWebView() {
        let userContent = WKUserContentController()
        userContent.add(exportHandler,    name: "exportImage")
        userContent.add(videoHandler,     name: "requestVideoSelection")
        userContent.add(videoHandler,     name: "extractVideoFrame")
        userContent.add(videoHandler,     name: "releaseVideoAsset")
        userContent.add(remindersHandler, name: "scheduleReminders")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "stlls-video")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.uiDelegate = self

        exportHandler.webView       = webView
        videoHandler.webView        = webView
        videoHandler.viewController = self
        videoHandler.schemeHandler  = schemeHandler

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func loadApp() {
        guard let indexURL = Bundle.main.url(
            forResource: "index", withExtension: "html", subdirectory: "web"
        ) else { return }
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    }

    // MARK: WKUIDelegate — file input (images only; video goes via native bridge)

    @available(iOS 18.4, *)
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        filePickerCompletionHandler = completionHandler
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    // target="_blank" links (e.g. the Privacy Policy) open in the system
    // browser instead of navigating the app's web view away from its UI.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            UIApplication.shared.open(url)
        }
        return nil
    }

    // MARK: PHPickerViewControllerDelegate (images)

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else {
            filePickerCompletionHandler?(nil); filePickerCompletionHandler = nil; return
        }

        var urls: [URL] = []
        let group   = DispatchGroup()
        let tempDir = FileManager.default.temporaryDirectory

        for result in results {
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                if let data    = try? Data(contentsOf: url),
                   let uiImage = UIImage(data: data),
                   let jpeg    = uiImage.jpegData(compressionQuality: 0.9) {
                    let dest = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
                    try? jpeg.write(to: dest)
                    urls.append(dest)
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.filePickerCompletionHandler?(urls.isEmpty ? nil : urls)
            self?.filePickerCompletionHandler = nil
        }
    }        
}

// MARK: - SwiftUI wrapper

struct WebView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController { WebViewController() }
    func updateUIViewController(_ uiViewController: WebViewController, context: Context) {}
}

struct ContentView: View {
    var body: some View { WebView().ignoresSafeArea() }
}
