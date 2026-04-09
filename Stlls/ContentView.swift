import SwiftUI
import WebKit
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

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
            callback(false)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                self?.callback(false)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, _ in
                self?.callback(success)
            }
        }
    }

    private func callback(_ success: Bool) {
        DispatchQueue.main.async { [weak self] in
            let js = "window.exportComplete(\(success ? "true" : "false"))"
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - WKURLSchemeHandler — serves local video files to WKWebView
//         Used for H.264 / HEVC files so the browser can seek natively.

class VideoSchemeHandler: NSObject, WKURLSchemeHandler {
    private var files: [String: URL] = [:]
    private let lock = NSLock()

    func register(key: String, url: URL) {
        lock.lock(); files[key] = url; lock.unlock()
    }

    func unregister(key: String) {
        lock.lock(); files.removeValue(forKey: key); lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard
            let reqURL   = urlSchemeTask.request.url,
            let comps    = URLComponents(url: reqURL, resolvingAgainstBaseURL: false),
            let key      = comps.queryItems?.first(where: { $0.name == "k" })?.value
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        lock.lock(); let fileURL = files[key]; lock.unlock()
        guard let fileURL = fileURL else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let attrs     = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                let totalSize = attrs[.size] as? Int
            else {
                urlSchemeTask.didFailWithError(URLError(.cannotReadFile)); return
            }

            var start = 0, end = totalSize - 1, statusCode = 200
            var headers: [String: String] = [
                "Accept-Ranges":  "bytes",
                "Content-Type":   fileURL.pathExtension.lowercased() == "mov"
                                    ? "video/quicktime" : "video/mp4",
            ]

            if let rangeHdr = urlSchemeTask.request.value(forHTTPHeaderField: "Range"),
               rangeHdr.hasPrefix("bytes=") {
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

            urlSchemeTask.didReceive(response)

            if let fh = try? FileHandle(forReadingFrom: fileURL) {
                try? fh.seek(toOffset: UInt64(start))
                let chunk = fh.readData(ofLength: length)
                try? fh.close()
                urlSchemeTask.didReceive(chunk)
            }
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

// MARK: - JS → Swift bridge for native video frame extraction

class VideoMessageHandler: NSObject, WKScriptMessageHandler, PHPickerViewControllerDelegate {

    weak var viewController: UIViewController?
    weak var webView: WKWebView?
    weak var schemeHandler: VideoSchemeHandler?

    // AVAssets stored by UUID key (ProRes / heavy codecs)
    private var assets:    [String: AVAsset] = [:]
    private var tempFiles: [String: URL]     = [:]

    // Web-served assets (H.264 / HEVC) — key only used for temp-file cleanup
    private var webKeys: Set<String> = []

    // Active image generators keyed by assetKey
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
        default:
            break
        }
    }

    // MARK: Video picker

    private func presentVideoPicker() {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.selectionLimit = 1
        cfg.filter = .videos
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        viewController?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let result = results.first,
              result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            sendToJS("window.nativeVideoReady(null)")
            return
        }

        result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url = url else {
                self?.sendToJS("window.nativeVideoReady(null)")
                return
            }

            // Hardlink (instant) or copy (fallback)
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            do {
                try FileManager.default.linkItem(at: url, to: dest)
            } catch {
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                } catch {
                    self?.sendToJS("window.nativeVideoReady(null)")
                    return
                }
            }

            let asset = AVURLAsset(url: dest)
            asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { [weak self] in
                guard let self = self else { return }

                var duration = 0.0
                var w = 1920, h = 1080
                var fps: Float = 30.0

                if asset.statusOfValue(forKey: "duration", error: nil) == .loaded {
                    duration = max(0, CMTimeGetSeconds(asset.duration))
                }

                if asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
                   let track = asset.tracks(withMediaType: .video).first {
                    let sz = track.naturalSize.applying(track.preferredTransform)
                    w = Int(abs(sz.width));  if w == 0 { w = Int(track.naturalSize.width) }
                    h = Int(abs(sz.height)); if h == 0 { h = Int(track.naturalSize.height) }
                    if track.nominalFrameRate > 0 { fps = track.nominalFrameRate }
                }

                let key = UUID().uuidString

                // Detect codec — web-compatible codecs (H.264, HEVC) go through
                // the URL scheme handler so the browser can seek natively (fast).
                // ProRes and other heavy codecs use AVAssetImageGenerator.
                let codec = self.videoCodec(asset: asset)
                let useWebPath = self.isWebCompatible(codec: codec)

                DispatchQueue.main.async {
                    self.tempFiles[key] = dest   // always track for cleanup

                    if useWebPath {
                        // Register with scheme handler and pass URL to JS
                        self.webKeys.insert(key)
                        self.schemeHandler?.register(key: key, url: dest)
                        let payload: [String: Any] = [
                            "webURL":    "stlls-video://v?k=\(key)",
                            "assetKey":  key,
                            "duration":  duration,
                            "width":     w,
                            "height":    h,
                            "frameRate": fps,
                        ]
                        self.webView?.callAsyncJavaScript(
                            "if (typeof window.nativeVideoReady === 'function') window.nativeVideoReady(payload)",
                            arguments: ["payload": payload],
                            in: nil, in: .page, completionHandler: nil
                        )
                    } else {
                        // ProRes / unknown — use AVAssetImageGenerator
                        self.assets[key] = asset
                        let payload: [String: Any] = [
                            "assetKey":  key,
                            "duration":  duration,
                            "width":     w,
                            "height":    h,
                            "frameRate": fps,
                        ]
                        self.webView?.callAsyncJavaScript(
                            "if (typeof window.nativeVideoReady === 'function') window.nativeVideoReady(payload)",
                            arguments: ["payload": payload],
                            in: nil, in: .page, completionHandler: nil
                        )
                    }
                }
            }
        }
    }

    // MARK: Codec detection

    private func videoCodec(asset: AVAsset) -> String {
        guard asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
              let track = asset.tracks(withMediaType: .video).first,
              let desc  = track.formatDescriptions.first else { return "" }
        let fmtDesc = desc as! CMFormatDescription
        let sub = CMFormatDescriptionGetMediaSubType(fmtDesc)
        let bytes: [UInt8] = [
            UInt8((sub >> 24) & 0xFF), UInt8((sub >> 16) & 0xFF),
            UInt8((sub >> 8)  & 0xFF), UInt8( sub        & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// H.264, HEVC — WebKit can decode these natively via <video> element.
    private func isWebCompatible(codec: String) -> Bool {
        return ["avc1", "hvc1", "hev1", "mp4v"].contains(codec)
    }

    // MARK: Frame extraction (ProRes / native path)

    private func extractFrame(_ body: [String: Any]) {
        guard let assetKey = body["assetKey"] as? String,
              let time     = body["time"]     as? Double,
              let reqId    = body["requestId"] as? String else { return }

        let isPreview = body["preview"] as? Bool ?? false

        guard let asset = assets[assetKey] else {
            sendFrame(requestId: reqId, dataURL: nil)
            return
        }

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
            var dataURL: String? = nil
            if let cgImage = cgImage {
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
        let payload: [String: Any] = [
            "requestId": requestId,
            "dataURL":   dataURL ?? NSNull()
        ]
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
            // Web-served asset — unregister from scheme handler
            schemeHandler?.unregister(key: key)
        } else {
            // Native AVAsset
            assets.removeValue(forKey: key)
        }

        if let url = tempFiles.removeValue(forKey: key) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Helpers

    private func sendToJS(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - UIViewController that hosts WKWebView

class WebViewController: UIViewController, WKUIDelegate, PHPickerViewControllerDelegate {

    private var webView: WKWebView!
    private let exportHandler = ExportMessageHandler()
    private let videoHandler  = VideoMessageHandler()
    private let schemeHandler = VideoSchemeHandler()
    private var filePickerCompletionHandler: (([URL]?) -> Void)?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        setupWebView()
        loadApp()
    }

    private func setupWebView() {
        let userContent = WKUserContentController()
        userContent.add(exportHandler, name: "exportImage")
        userContent.add(videoHandler,  name: "requestVideoSelection")
        userContent.add(videoHandler,  name: "extractVideoFrame")
        userContent.add(videoHandler,  name: "releaseVideoAsset")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Register custom scheme so JS can stream local video files
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "stlls-video")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.uiDelegate = self

        exportHandler.webView      = webView
        videoHandler.webView       = webView
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
        let webDir = indexURL.deletingLastPathComponent()
        webView.loadFileURL(indexURL, allowingReadAccessTo: webDir)
    }

    // MARK: - WKUIDelegate — intercept file inputs (images only)

    @available(iOS 18.4, *)
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        // Video is handled natively via requestVideoSelection message.
        // This delegate only handles image selection.
        filePickerCompletionHandler = completionHandler

        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0
        config.filter = .images

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - PHPickerViewControllerDelegate (images)

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard !results.isEmpty else {
            filePickerCompletionHandler?(nil)
            filePickerCompletionHandler = nil
            return
        }

        var urls: [URL] = []
        let group = DispatchGroup()
        let tempDir = FileManager.default.temporaryDirectory

        for result in results {
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }

            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                defer { group.leave() }
                guard let url = url else { return }
                if let data = try? Data(contentsOf: url),
                   let uiImage = UIImage(data: data),
                   let jpeg = uiImage.jpegData(compressionQuality: 0.9) {
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
    func makeUIViewController(context: Context) -> WebViewController {
        WebViewController()
    }
    func updateUIViewController(_ uiViewController: WebViewController, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        WebView().ignoresSafeArea()
    }
}
