import SwiftUI
import WebKit
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers

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

// MARK: - UIViewController that hosts WKWebView

class WebViewController: UIViewController, WKUIDelegate, PHPickerViewControllerDelegate {

    private var webView: WKWebView!
    private let exportHandler = ExportMessageHandler()
    private var filePickerCompletionHandler: (([URL]?) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        setupWebView()
        loadApp()
    }

    private func setupWebView() {
        let userContent = WKUserContentController()
        userContent.add(exportHandler, name: "exportImage")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.uiDelegate = self   // ← enables custom file picker

        exportHandler.webView = webView

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

    // MARK: - WKUIDelegate — intercept file inputs (iOS 16+)

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        filePickerCompletionHandler = completionHandler

        var config = PHPickerConfiguration(photoLibrary: .shared())
        // multiple=true means stills mode; single means video mode
        config.selectionLimit = parameters.allowsMultipleSelection ? 0 : 1
        config.filter = parameters.allowsMultipleSelection ? .images : .videos

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - PHPickerViewControllerDelegate

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

            let typeId: String
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                typeId = UTType.movie.identifier
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                typeId = UTType.image.identifier
            } else {
                continue
            }

            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
                defer { group.leave() }
                guard let url = url else { return }

                if typeId == UTType.image.identifier {
                    // Convert to JPEG for reliable web decoding (handles HEIC etc.)
                    if let data = try? Data(contentsOf: url),
                       let uiImage = UIImage(data: data),
                       let jpeg = uiImage.jpegData(compressionQuality: 0.9) {
                        let dest = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
                        try? jpeg.write(to: dest)
                        urls.append(dest)
                    }
                } else {
                    // Copy video to a stable temp path WKWebView can read
                    let dest = tempDir.appendingPathComponent(
                        UUID().uuidString + "." + url.pathExtension
                    )
                    try? FileManager.default.copyItem(at: url, to: dest)
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
