import SwiftUI
import WebKit
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import UserNotifications

// MARK: - JS → Swift bridge for image & video export

class ExportMessageHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Native looping-video compositor: payload is a dictionary, not a dataURL string.
        if message.name == "exportVideoNative" {
            guard let body = message.body as? [String: Any] else { callback(false); return }
            exportComposition(body); return
        }

        guard let dataURL = message.body as? String else { return }
        let parts = dataURL.components(separatedBy: ",")
        guard parts.count == 2, let data = Data(base64Encoded: parts[1]) else { callback(false); return }

        if message.name == "exportVideo" {
            saveVideo(data: data, mimePrefix: parts[0]); return
        }
        // exportImage
        guard let image = UIImage(data: data) else { callback(false); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else { self?.callback(false); return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, _ in self?.callback(success) }
        }
    }

    private func saveVideo(data: Data, mimePrefix: String) {
        // Photos accepts .mp4 / .mov; MediaRecorder on iOS produces H.264 mp4.
        let ext = mimePrefix.contains("quicktime") ? "mov" : "mp4"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        do { try data.write(to: tmp) } catch { callback(false); return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: tmp); self?.callback(false); return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tmp)
            }) { success, _ in
                try? FileManager.default.removeItem(at: tmp)
                self?.callback(success)
            }
        }
    }

    // MARK: Native looping-video composition (Phase 2 export)
    // Builds one video track per clip, each looped to fill `duration`, and composites
    // each into its slot via crop + affine transform. The loop is pre-rendered, so the
    // exported MP4 has no live-playback stall at the seam.

    private func nums(_ v: Any?) -> [Double] {
        (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
    }

    private func exportComposition(_ body: [String: Any]) {
        guard let width    = (body["width"]    as? NSNumber)?.intValue,
              let height   = (body["height"]   as? NSNumber)?.intValue,
              let duration = (body["duration"] as? NSNumber)?.doubleValue,
              let clips    = body["clips"] as? [[String: Any]], !clips.isEmpty
        else { callback(false); return }

        let bitrate = (body["bitrate"] as? NSNumber)?.intValue ?? 12_000_000
        let renderSize = CGSize(width: width, height: height)
        let totalDur   = CMTime(seconds: duration, preferredTimescale: 600)
        // Corner rounding: gap 0 → round the whole board; gap > 0 → round each frame.
        let radius  = CGFloat((body["radius"] as? NSNumber)?.doubleValue ?? 0)
        let gap     = (body["gap"] as? NSNumber)?.doubleValue ?? 0
        let bgColor = UIColor(hexString: (body["bg"] as? String) ?? "#000000")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let comp = AVMutableComposition()
            var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
            var destRects: [CGRect] = []
            var stills: [(image: UIImage, dest: CGRect, crop: [Double])] = []
            var temps: [URL] = []

            for clip in clips {
                guard let b64 = clip["data"] as? String,
                      let data = Data(base64Encoded: b64) else { continue }
                let dest = self.nums(clip["dest"]), crop = self.nums(clip["crop"])
                guard dest.count == 4, crop.count == 4 else { continue }
                let destRect = CGRect(x: CGFloat(dest[0]), y: CGFloat(dest[1]),
                                      width: CGFloat(dest[2]), height: CGFloat(dest[3]))

                // Still → stamped as a static frame after compositing (not a video track).
                if (clip["still"] as? Bool) == true {
                    if let img = UIImage(data: data) {
                        stills.append((img, destRect, crop)); destRects.append(destRect)
                    }
                    continue
                }

                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mp4")
                do { try data.write(to: tmp) } catch { continue }
                temps.append(tmp)

                let asset = AVURLAsset(url: tmp)
                guard let srcTrack = asset.tracks(withMediaType: .video).first,
                      let compTrack = comp.addMutableTrack(withMediaType: .video,
                                          preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }

                let clipDur = asset.duration
                if clipDur.seconds <= 0 { continue }

                // Loop-fill: concatenate the clip end-to-end until it covers the duration.
                var cursor = CMTime.zero
                while cursor < totalDur {
                    let insertDur = min(clipDur, totalDur - cursor)
                    if insertDur.seconds <= 0 { break }
                    try? compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: insertDur),
                                                   of: srcTrack, at: cursor)
                    cursor = cursor + insertDur
                }

                // Clips are re-encoded upright by the trim (identity preferredTransform),
                // so natural size == display size and we crop in those coords.
                let natW = srcTrack.naturalSize.width
                let natH = srcTrack.naturalSize.height
                let cropRect = CGRect(x: CGFloat(crop[0]) * natW, y: CGFloat(crop[1]) * natH,
                                      width: CGFloat(crop[2]) * natW, height: CGFloat(crop[3]) * natH)
                let sx = destRect.width  / max(1, cropRect.width)
                let sy = destRect.height / max(1, cropRect.height)
                // Map cropped region → slot: translate(-crop) · scale · translate(dest)
                var tf = CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
                tf = tf.concatenating(CGAffineTransform(scaleX: sx, y: sy))
                tf = tf.concatenating(CGAffineTransform(translationX: destRect.minX, y: destRect.minY))

                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
                li.setCropRectangle(cropRect, at: .zero)
                li.setTransform(tf, at: .zero)
                layerInstructions.append(li)
                destRects.append(destRect)
            }

            guard !layerInstructions.isEmpty else {
                temps.forEach { try? FileManager.default.removeItem(at: $0) }
                self.callback(false); return
            }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: totalDur)
            instruction.layerInstructions = layerInstructions

            let videoComp = AVMutableVideoComposition()
            videoComp.renderSize    = renderSize
            videoComp.frameDuration = CMTime(value: 1, timescale: 30)
            videoComp.instructions  = [instruction]

            // Stills are static, so they're stamped once into a layer that's drawn onto every
            // frame (they occupy their own slots, never overlapping the clip video tracks).
            let stillsLayer = self.makeStillsLayer(size: renderSize, stills: stills)
            // Rounded-corner overlay: bg colour with rounded holes punched for the content
            // (clips AND stills), composited last. Whole board when gap==0, each frame otherwise.
            let overlay = self.makeCornerOverlay(size: renderSize, radius: radius, gap: gap,
                                                 bg: bgColor, destRects: destRects)

            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            self.renderComposition(comp, videoComp: videoComp, size: CGSize(width: width, height: height),
                                   duration: duration, bitrate: bitrate,
                                   stillsLayer: stillsLayer, overlay: overlay,
                                   outURL: outURL, temps: temps)
        }
    }

    // Build the rounded-corner overlay (top-left coords, matching the JS dest rects):
    // background colour everywhere except inside the rounded content rectangles, which are
    // left transparent so the composed video shows through.
    private func makeCornerOverlay(size: CGSize, radius: CGFloat, gap: Double,
                                   bg: UIColor, destRects: [CGRect]) -> CGImage? {
        guard radius > 0, size.width > 0, size.height > 0 else { return nil }
        let contentRects = gap > 0 ? destRects : [CGRect(origin: .zero, size: size)]
        guard !contentRects.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1; format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { c in
            let cg = c.cgContext
            cg.setFillColor(bg.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setBlendMode(.clear)
            for r in contentRects {
                let rr = min(radius, r.width / 2, r.height / 2)
                cg.addPath(UIBezierPath(roundedRect: r, cornerRadius: rr).cgPath)
                cg.fillPath()
            }
        }
        return image.cgImage
    }

    // A transparent layer with each still cover-cropped into its slot (top-left coords),
    // stamped onto every frame so stills appear as static frames in a mixed clip+still video.
    private func makeStillsLayer(size: CGSize,
                                 stills: [(image: UIImage, dest: CGRect, crop: [Double])]) -> CGImage? {
        guard !stills.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1; format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { c in
            let cg = c.cgContext
            for s in stills where s.crop.count == 4 {
                let iw = s.image.size.width, ih = s.image.size.height
                guard iw > 0, ih > 0 else { continue }
                let sx = s.dest.width  / max(1, CGFloat(s.crop[2]) * iw)
                let sy = s.dest.height / max(1, CGFloat(s.crop[3]) * ih)
                let drawRect = CGRect(x: s.dest.minX - CGFloat(s.crop[0]) * iw * sx,
                                      y: s.dest.minY - CGFloat(s.crop[1]) * ih * sy,
                                      width: iw * sx, height: ih * sy)
                cg.saveGState()
                cg.clip(to: s.dest)
                s.image.draw(in: drawRect)
                cg.restoreGState()
            }
        }
        return image.cgImage
    }

    // Composite the overlay onto a (BGRA, top-down) frame buffer in place.
    private func drawOverlay(_ overlay: CGImage, into pixelBuffer: CVPixelBuffer, size: CGSize) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
        // CG y=0 is the buffer's first (top) row; flip so the top-down overlay lands upright.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(overlay, in: CGRect(origin: .zero, size: size))
    }

    // Reader/writer transcode so we can honour an explicit average bitrate (presets
    // don't expose one). Falls back to AVAssetExportSession (highest quality) if the
    // reader/writer can't be set up.
    private func renderComposition(_ comp: AVMutableComposition,
                                   videoComp: AVMutableVideoComposition,
                                   size: CGSize, duration: Double, bitrate: Int,
                                   stillsLayer: CGImage? = nil,
                                   overlay: CGImage? = nil,
                                   outURL: URL, temps: [URL]) {
        let cleanup = { temps.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            let reader = try AVAssetReader(asset: comp)
            let readerOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: comp.tracks(withMediaType: .video),
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            readerOutput.videoComposition = videoComp
            // Need writable frame buffers to stamp the stills layer / rounded-corner overlay.
            readerOutput.alwaysCopiesSampleData = (overlay != nil || stillsLayer != nil)
            guard reader.canAdd(readerOutput) else { throw NSError(domain: "stlls", code: 1) }
            reader.add(readerOutput)

            let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey:  AVVideoCodecType.h264,
                AVVideoWidthKey:  Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey:      bitrate,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey:        AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw NSError(domain: "stlls", code: 2)
            }
            let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            writerInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerInput) else { throw NSError(domain: "stlls", code: 3) }
            writer.add(writerInput)

            guard reader.startReading() else { throw NSError(domain: "stlls", code: 4) }
            guard writer.startWriting() else { reader.cancelReading(); throw NSError(domain: "stlls", code: 5) }
            writer.startSession(atSourceTime: .zero)

            let q = DispatchQueue(label: "stlls.export")
            writerInput.requestMediaDataWhenReady(on: q) { [weak self] in
                guard let self else { return }
                while writerInput.isReadyForMoreMediaData {
                    if reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() {
                        let pt = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if let imgBuf = CMSampleBufferGetImageBuffer(sample) {
                            if let stillsLayer { self.drawOverlay(stillsLayer, into: imgBuf, size: size) }
                            if let overlay     { self.drawOverlay(overlay,     into: imgBuf, size: size) }
                        }
                        writerInput.append(sample)
                        let p = duration > 0 ? min(1.0, pt / duration) : 0
                        DispatchQueue.main.async {
                            self.webView?.evaluateJavaScript("window.exportProgress && window.exportProgress(\(p))",
                                                             completionHandler: nil)
                        }
                    } else {
                        writerInput.markAsFinished()
                        if reader.status == .reading { reader.cancelReading() }
                        writer.finishWriting {
                            cleanup()
                            DispatchQueue.main.async {
                                if writer.status == .completed { self.saveVideoFile(outURL) }
                                else { try? FileManager.default.removeItem(at: outURL); self.callback(false) }
                            }
                        }
                        break
                    }
                }
            }
        } catch {
            // Fallback: proven export-session path (no custom bitrate).
            self.renderWithExportSession(comp, videoComp: videoComp, outURL: outURL, temps: temps)
        }
    }

    private func renderWithExportSession(_ comp: AVMutableComposition,
                                         videoComp: AVMutableVideoComposition,
                                         outURL: URL, temps: [URL]) {
        guard let export = AVAssetExportSession(asset: comp,
                              presetName: AVAssetExportPresetHighestQuality) else {
            temps.forEach { try? FileManager.default.removeItem(at: $0) }
            callback(false); return
        }
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.videoComposition = videoComp
        export.exportAsynchronously {
            temps.forEach { try? FileManager.default.removeItem(at: $0) }
            DispatchQueue.main.async {
                if export.status == .completed { self.saveVideoFile(outURL) }
                else { self.callback(false) }
            }
        }
    }

    private func saveVideoFile(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url); self?.callback(false); return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, _ in
                try? FileManager.default.removeItem(at: url)
                self?.callback(success)
            }
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
                "Access-Control-Allow-Origin": "*",   // allow web fetch() → blob for seamless looping
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

    // When true, the next pick produces a low-res looping-clip PROXY (video boards)
    // instead of the still-grab flow. Reset to false as soon as a pick is handled.
    private var proxyMode = false
    // When true, the next pick allows MULTIPLE videos and each whole video becomes a
    // clip (no shot analysis). Reset to false as soon as a pick is handled.
    private var fullClipsMode = false

    // MARK: Message routing

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "requestVideoSelection":
            DispatchQueue.main.async { self.proxyMode = false; self.fullClipsMode = false; self.presentVideoPicker() }
        case "requestVideoProxy":
            DispatchQueue.main.async { self.proxyMode = true; self.fullClipsMode = false; self.presentVideoPicker() }
        case "requestFullClips":
            DispatchQueue.main.async { self.fullClipsMode = true; self.proxyMode = false; self.presentVideoPicker() }
        case "requestVideoClips":
            guard let body = message.body as? [String: Any] else { return }
            DispatchQueue.main.async { self.trimClips(body) }
        case "extractVideoFrame":
            guard let body = message.body as? [String: Any] else { return }
            extractFrame(body)
        case "releaseVideoAsset":
            guard let key = message.body as? String else { return }
            releaseAsset(key)
        case "clearCache":
            let body = (message.body as? [String: Any]) ?? [:]
            DispatchQueue.main.async { [weak self] in self?.clearCache(body) }
        default: break
        }
    }

    // Free cached/intermediate video files (trimmed clips, proxies, exports) from the
    // app's temp directory. Saved projects keep their footage as blobs in IndexedDB and
    // never read these files back, so this only reclaims space from inactive / deleted
    // projects. `keepKeys` protects the source of any video the user has open right now
    // (e.g. for "Add more from video"), so an in-progress session isn't disrupted.
    private func clearCache(_ body: [String: Any]) {
        let keepKeys = Set((body["keepKeys"] as? [String]) ?? [])
        let fm = FileManager.default
        var freed: Int64 = 0

        func sizeOf(_ url: URL) -> Int64 {
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }

        // 1. Tracked temp files this session that aren't protected — their footage already
        //    lives as blobs on the web side, so they're safe to drop.
        for (key, url) in tempFiles where !keepKeys.contains(key) {
            freed += sizeOf(url)
            try? fm.removeItem(at: url)
            schemeHandler?.unregister(key: key)
            tempFiles.removeValue(forKey: key)
            webKeys.remove(key)
            assets.removeValue(forKey: key)
            activeGenerators[key]?.cancelAllCGImageGeneration()
            activeGenerators.removeValue(forKey: key)
        }

        // 2. Orphaned media left in the temp dir by previous sessions.
        let keptPaths = Set(keepKeys.compactMap { tempFiles[$0]?.path })
        if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                   includingPropertiesForKeys: [.fileSizeKey]) {
            for url in items where !keptPaths.contains(url.path) {
                let ext = url.pathExtension.lowercased()
                guard ext == "mp4" || ext == "mov" || ext == "m4v" else { continue }
                freed += sizeOf(url)
                try? fm.removeItem(at: url)
            }
        }

        let payload: [String: Any] = ["freedBytes": freed]
        DispatchQueue.main.async { [weak self] in
            self?.webView?.callAsyncJavaScript(
                "if (typeof window.cacheCleared === 'function') window.cacheCleared(payload)",
                arguments: ["payload": payload], in: nil, in: .page, completionHandler: nil)
        }
    }

    // MARK: Video picker

    private func presentVideoPicker() {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.selectionLimit = fullClipsMode ? 10 : 1   // full-clips mode allows multiple
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

        // Full-clips mode: multiple whole videos, each → a low-res clip (no analysis).
        if fullClipsMode {
            fullClipsMode = false
            makeFullClips(results); return   // handles the empty case (sends count 0)
        }

        // Snapshot the mode now — the rest runs async and a later pick must not flip it.
        let doProxy = proxyMode
        proxyMode = false
        let failJS = doProxy
            ? "if (window.nativeVideoProxyReady) window.nativeVideoProxyReady(null)"
            : "window.nativeVideoReady(null)"

        guard let result = results.first,
              result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            sendToJS(failJS); return
        }

        result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
            guard let url else { self?.sendToJS(failJS); return }

            // Hardlink (instant, no copy) or fall back to a full copy
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            do    { try FileManager.default.linkItem(at: url, to: dest) }
            catch { do    { try FileManager.default.copyItem(at: url, to: dest) }
                    catch { self?.sendToJS(failJS); return } }

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
                    let fileName = url.lastPathComponent

                    // Video-board path. Detection runs on the ORIGINAL (no whole-video
                    // transcode → fast); individual shots are trimmed on demand when the
                    // user taps Add (see requestVideoClips). ProRes can't be web-played,
                    // so it falls back to a low-res proxy used for both detect + trim.
                    if doProxy {
                        if useWebPath {
                            self.tempFiles[key] = dest
                            self.assets[key]    = asset          // kept for trimming
                            self.webKeys.insert(key)
                            self.schemeHandler?.register(key: key, url: dest)
                            let payload: [String: Any] = [
                                "webURL":   "stlls-video://v?k=\(key)",
                                "assetKey": key,
                                "duration": finalDuration,
                                "width":    finalW,
                                "height":   finalH,
                                "fileName": fileName,
                            ]
                            self.webView?.callAsyncJavaScript(
                                "if (typeof window.nativeVideoProxyReady === 'function') window.nativeVideoProxyReady(payload)",
                                arguments: ["payload": payload], in: nil, in: .page, completionHandler: nil)
                        } else {
                            self.exportProxy(asset: asset, source: dest,
                                             duration: finalDuration, fileName: fileName)
                        }
                        return
                    }

                    self.tempFiles[key] = dest
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

    // MARK: Low-res proxy export (ProRes fallback only)
    // ProRes can't be played in <video>, so make one low-res H.264 proxy that the
    // web side detects on; individual shots are then trimmed from it on Add.

    private func exportProxy(asset: AVURLAsset, source: URL, duration: Double, fileName: String) {
        let fail = "if (window.nativeVideoProxyReady) window.nativeVideoProxyReady(null)"
        // 540p keeps decode cost low for multi-clip boards; the web side buffers each
        // short clip fully into memory so several can play at once without lag.
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) else {
            sendToJS(fail); cleanupTemp(source); return
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        export.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleanupTemp(source)   // original no longer needed
                guard export.status == .completed else { self.sendToJS(fail); return }

                let key = UUID().uuidString
                self.tempFiles[key] = outURL
                self.assets[key]    = AVURLAsset(url: outURL)   // kept for trimming
                self.webKeys.insert(key)
                self.schemeHandler?.register(key: key, url: outURL)
                let payload: [String: Any] = [
                    "webURL":   "stlls-video://v?k=\(key)",
                    "assetKey": key,
                    "duration": duration,
                    "fileName": fileName,
                ]
                self.webView?.callAsyncJavaScript(
                    "if (typeof window.nativeVideoProxyReady === 'function') window.nativeVideoProxyReady(payload)",
                    arguments: ["payload": payload], in: nil, in: .page, completionHandler: nil)
            }
        }
    }

    private func cleanupTemp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Whole-video clips (Clips strip + — multi-select, no analysis)
    // Each picked video is re-encoded to a low-res proxy and handed back as a clip.

    private func makeFullClips(_ results: [PHPickerResult]) {
        let movieType = UTType.movie.identifier
        let valid = results.filter { $0.itemProvider.hasItemConformingToTypeIdentifier(movieType) }

        // Tell the web how many clips are coming so it can build the loading slots now.
        webView?.callAsyncJavaScript(
            "if (typeof window.nativeFullClipsStart === 'function') window.nativeFullClipsStart(n)",
            arguments: ["n": valid.count], in: nil, in: .page, completionHandler: nil)
        guard !valid.isEmpty else { return }
        // Strictly ONE at a time: a single big iPhone transcode gets the whole device,
        // which avoids the memory/encoder exhaustion that made concurrent ones fail.
        processFullClipsSequentially(valid, index: 0, movieType: movieType)
    }

    private func processFullClipsSequentially(_ results: [PHPickerResult], index: Int, movieType: String) {
        if index >= results.count {
            webView?.callAsyncJavaScript(
                "if (typeof window.nativeFullClipsDone === 'function') window.nativeFullClipsDone()",
                arguments: [:], in: nil, in: .page, completionHandler: nil)
            return
        }
        let next: () -> Void = { [weak self] in
            self?.processFullClipsSequentially(results, index: index + 1, movieType: movieType)
        }
        results[index].itemProvider.loadFileRepresentation(forTypeIdentifier: movieType) { [weak self] url, _ in
            guard let self else { return }
            guard let url else { self.sendFullClip(index, nil); next(); return }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            do { try FileManager.default.linkItem(at: url, to: dest) }
            catch { do { try FileManager.default.copyItem(at: url, to: dest) }
                    catch { self.sendFullClip(index, nil); next(); return } }
            let fileName = url.deletingPathExtension().lastPathComponent
            self.exportFullProxy(asset: AVURLAsset(url: dest), source: dest, fileName: fileName) { info in
                self.sendFullClip(index, info)   // stream this clip in, then start the next
                next()
            }
        }
    }

    private func sendFullClip(_ index: Int, _ info: [String: Any]?) {
        DispatchQueue.main.async {
            let payload: [String: Any] = ["index": index, "clip": info ?? NSNull()]
            self.webView?.callAsyncJavaScript(
                "if (typeof window.nativeFullClipReady === 'function') window.nativeFullClipReady(payload)",
                arguments: ["payload": payload], in: nil, in: .page, completionHandler: nil)
        }
    }

    private func exportFullProxy(asset: AVURLAsset, source: URL, fileName: String,
                                 preset: String = AVAssetExportPreset960x540, retriesLeft: Int = 1,
                                 completion: @escaping ([String: Any]?) -> Void) {
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            // Can't even build this preset → last-resort passthrough, else give up.
            if preset != AVAssetExportPresetPassthrough {
                exportFullProxy(asset: asset, source: source, fileName: fileName,
                                preset: AVAssetExportPresetPassthrough, retriesLeft: 0, completion: completion)
            } else { cleanupTemp(source); completion(nil) }
            return
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        // Cap whole-video clips to the first 10s — also makes the transcode far faster on
        // long iPhone clips (only 10s is decoded/encoded). Works on passthrough too.
        let maxClipSeconds = 10.0
        if asset.duration.seconds > maxClipSeconds {
            export.timeRange = CMTimeRange(start: .zero,
                                           duration: CMTime(seconds: maxClipSeconds, preferredTimescale: 600))
        }
        // 960x540 orients + downscales every normal input. One export runs at a time
        // (sequential) with a retry; if it still fails (e.g. an HDR/Dolby-Vision clip the
        // H.264 preset can't convert), fall back to PASSTHROUGH (copies the original,
        // can't fail on format) so the clip loads instead of vanishing.
        export.exportAsynchronously { [weak self] in
            guard let self else { return }
            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: outURL)
                if retriesLeft > 0 {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) {
                        self.exportFullProxy(asset: asset, source: source, fileName: fileName,
                                             preset: preset, retriesLeft: retriesLeft - 1, completion: completion)
                    }
                } else if preset != AVAssetExportPresetPassthrough {
                    self.exportFullProxy(asset: asset, source: source, fileName: fileName,
                                         preset: AVAssetExportPresetPassthrough, retriesLeft: 0, completion: completion)
                } else {
                    self.cleanupTemp(source); completion(nil)
                }
                return
            }
            self.finalizeProxy(outURL, source: source, fileName: fileName, completion: completion)
        }
    }

    // Build the poster + metadata for a finished proxy (off-thread), register it, and
    // hand it back to the web. Shared by the downscale and passthrough export paths.
    private func finalizeProxy(_ outURL: URL, source: URL, fileName: String,
                               completion: @escaping ([String: Any]?) -> Void) {
        let proxyAsset = AVURLAsset(url: outURL)
        let dur = proxyAsset.duration.seconds
        var w = 0.0, h = 0.0
        if let track = proxyAsset.tracks(withMediaType: .video).first {
            let sz = track.naturalSize.applying(track.preferredTransform)
            w = abs(sz.width); h = abs(sz.height)
        }
        var poster: String? = nil
        let gen = AVAssetImageGenerator(asset: proxyAsset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 360)
        let at = CMTime(seconds: min(0.2, max(0, dur / 2)), preferredTimescale: 600)
        if let cg = try? gen.copyCGImage(at: at, actualTime: nil),
           let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.7) {
            poster = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        }
        DispatchQueue.main.async {
            self.cleanupTemp(source)
            let key = UUID().uuidString
            self.tempFiles[key] = outURL
            self.webKeys.insert(key)
            self.schemeHandler?.register(key: key, url: outURL)
            var info: [String: Any] = [
                "webURL": "stlls-video://v?k=\(key)", "fileName": fileName,
                "duration": dur, "width": w, "height": h,
            ]
            if let poster { info["poster"] = poster }
            completion(info)
        }
    }

    // MARK: Per-shot trimming (video-board clips)
    // Trims each selected shot range into its own tiny low-res clip. Each loops
    // seamlessly via the <video loop> attribute (no JS seek hitch), and re-encoding
    // the exact range means no transition frames bleed in from adjacent shots.

    private func trimClips(_ body: [String: Any]) {
        let fail = "if (window.nativeVideoClipsReady) window.nativeVideoClipsReady(null)"
        guard let key    = body["key"] as? String,
              let ranges = body["ranges"] as? [[Double]],
              let asset  = assets[key] else {
            sendToJS(fail); return
        }

        Task { [weak self] in
            guard let self else { return }
            var clips: [[String: Any]] = []
            for r in ranges where r.count == 2 {
                if let info = await self.trimOne(asset: asset, start: r[0], end: r[1]) {
                    clips.append(info)
                }
            }
            await MainActor.run {
                // Keep the source alive so "Add more from video" can trim further shots.
                // The web releases it (releaseVideoAsset) when it discards the analysed video.
                let payload: [String: Any] = ["clips": clips]
                self.webView?.callAsyncJavaScript(
                    "if (typeof window.nativeVideoClipsReady === 'function') window.nativeVideoClipsReady(payload)",
                    arguments: ["payload": payload], in: nil, in: .page, completionHandler: nil)
            }
        }
    }

    private func trimOne(asset: AVAsset, start: Double, end: Double) async -> [String: Any]? {
        guard let srcTrack = asset.tracks(withMediaType: .video).first else { return nil }
        let dur = max(0.1, end - start)

        // Bake the source's orientation into the pixels so the trimmed clip is genuinely
        // upright with an identity transform. iPhone video stores portrait frames as
        // landscape pixels + a 90° preferredTransform; a plain preset export keeps that
        // transform as metadata. The composition exporter reads naturalSize and assumes
        // natural == display, so without baking, portrait clips export rotated + squeezed.
        let natSize  = srcTrack.naturalSize
        let prefT    = srcTrack.preferredTransform
        let oriented = CGRect(origin: .zero, size: natSize).applying(prefT)
        let dispW = abs(oriented.width), dispH = abs(oriented.height)
        guard dispW > 0, dispH > 0 else { return nil }

        // Keep clips at full-HD (long edge ~1920) so portrait clips fill a 9:16 export
        // canvas without upscaling. Never enlarge beyond the source; cap 4K down to 1920.
        // Rounded to even dimensions (H.264-friendly).
        let scale = min(1, 1920 / max(dispW, dispH))
        func even(_ v: CGFloat) -> CGFloat { let n = max(2, (v * scale).rounded()); return n.truncatingRemainder(dividingBy: 2) == 0 ? n : n + 1 }
        let outW = even(dispW), outH = even(dispH)

        // natural → upright (correct negative origin from rotation) → fill the output size.
        let fix = CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY)
        var tf = prefT.concatenating(fix)
        tf = tf.concatenating(CGAffineTransform(scaleX: outW / dispW, y: outH / dispH))

        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: srcTrack)
        li.setTransform(tf, at: .zero)
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        inst.layerInstructions = [li]

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize    = CGSize(width: outW, height: outH)
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.instructions  = [inst]

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.videoComposition = videoComp
        export.timeRange = CMTimeRange(
            start:    CMTime(seconds: max(0, start), preferredTimescale: 600),
            duration: CMTime(seconds: dur,           preferredTimescale: 600))

        return await withCheckedContinuation { cont in
            export.exportAsynchronously {
                DispatchQueue.main.async {
                    guard export.status == .completed else { cont.resume(returning: nil); return }
                    let k = UUID().uuidString
                    self.tempFiles[k] = outURL
                    self.webKeys.insert(k)
                    self.schemeHandler?.register(key: k, url: outURL)
                    cont.resume(returning: ["webURL": "stlls-video://v?k=\(k)", "dur": dur])
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
        }
        assets.removeValue(forKey: key)   // web clip sources also keep an asset for trimming
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
        userContent.add(exportHandler,    name: "exportVideo")
        userContent.add(exportHandler,    name: "exportVideoNative")
        userContent.add(videoHandler,     name: "requestVideoSelection")
        userContent.add(videoHandler,     name: "requestVideoProxy")
        userContent.add(videoHandler,     name: "requestFullClips")
        userContent.add(videoHandler,     name: "requestVideoClips")
        userContent.add(videoHandler,     name: "extractVideoFrame")
        userContent.add(videoHandler,     name: "releaseVideoAsset")
        userContent.add(videoHandler,     name: "clearCache")
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

// MARK: - Hex colour helper (for the export background / corner fill)

extension UIColor {
    convenience init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8)  & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255;         a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
