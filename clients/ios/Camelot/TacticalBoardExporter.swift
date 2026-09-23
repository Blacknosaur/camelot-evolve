import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum BoardExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, mp4, hevc, gif

    var id: String { rawValue }
    var title: String {
        switch self {
        case .png: "PNG image"
        case .jpeg: "JPEG image"
        case .mp4: "Video (H.264)"
        case .hevc: "Video (HEVC)"
        case .gif: "Animated GIF"
        }
    }
    var symbol: String {
        switch self {
        case .png, .jpeg: "photo"
        case .mp4, .hevc: "film"
        case .gif: "square.stack.3d.forward.dottedline"
        }
    }
    var isImage: Bool { self == .png || self == .jpeg }
    var fileExtension: String { self == .hevc ? "mp4" : rawValue }
}

enum BoardExportFraming: String, CaseIterable, Identifiable, Sendable {
    case landscape, square, vertical

    var id: String { rawValue }
    var title: String {
        switch self {
        case .landscape: "Landscape 16:9"
        case .square: "Square 1:1"
        case .vertical: "Vertical 9:16"
        }
    }
    var symbol: String {
        switch self {
        case .landscape: "rectangle"
        case .square: "square"
        case .vertical: "rectangle.portrait"
        }
    }
    /// Video pixel size (1080p family).
    var videoSize: CGSize {
        switch self {
        case .landscape: CGSize(width: 1920, height: 1080)
        case .square: CGSize(width: 1080, height: 1080)
        case .vertical: CGSize(width: 1080, height: 1920)
        }
    }
    /// Image size in points before the 2x/3x scale.
    var imageSize: CGSize {
        switch self {
        case .landscape: CGSize(width: 640, height: 360)
        case .square: CGSize(width: 540, height: 540)
        case .vertical: CGSize(width: 540, height: 960)
        }
    }
    var gifSize: CGSize {
        switch self {
        case .landscape: CGSize(width: 720, height: 405)
        case .square: CGSize(width: 600, height: 600)
        case .vertical: CGSize(width: 540, height: 960)
        }
    }
}

struct BoardExportRequest: Sendable {
    var document: BoardDocument
    var name: String
    var format: BoardExportFormat = .png
    var framing: BoardExportFraming = .landscape
    var imageScale: CGFloat = 3
}

/// Renders boards to files with the same renderers the editor uses: `BoardRenderer` for
/// top views and the SceneKit scene (`TacticalBoard3DRenderer`) for 3D views. Every
/// function is safe to call off the main actor, so exports never block the UI.
enum TacticalBoardExporter {
    static let frameRate: Int32 = 30
    /// Boards without keyframes export as a short still clip.
    static let stillClipDuration = 2.0
    static let background = UIColor(red: 0.045, green: 0.047, blue: 0.055, alpha: 1)

    enum ExportError: LocalizedError {
        case encodingFailed(String)
        var errorDescription: String? {
            switch self { case .encodingFailed(let reason): "Export failed: \(reason)" }
        }
    }

    /// Exports into a fresh subfolder of `directory`, so the file keeps the board's name for the
    /// share sheet while two boards with the same name (or the same board as MP4 and HEVC, which
    /// share the "mp4" extension) can never overwrite each other. Nothing an earlier export handed
    /// out is deleted while it is in use: older subfolders are pruned, newest first, by `prune`.
    static func export(_ request: BoardExportRequest, to directory: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        prune(directory)
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName(request.name)).appendingPathExtension(request.format.fileExtension)
        do {
            switch request.format {
            case .png, .jpeg:
                guard let data = imageData(document: request.document, size: request.framing.imageSize, scale: request.imageScale, jpeg: request.format == .jpeg) else {
                    throw ExportError.encodingFailed("the image could not be rendered")
                }
                try data.write(to: url, options: .atomic)
                progress(1)
            case .mp4, .hevc:
                try await writeVideo(request, to: url, progress: progress)
            case .gif:
                try writeGIF(request, to: url, progress: progress)
            }
        } catch {
            // Cancelled or failed: leave no half-written file (or empty folder) behind.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return url
    }

    /// How many finished exports stay on disk. Each one may still be held by a share sheet, so the
    /// newest few are always kept and only older folders are removed.
    static let keptExports = 5

    /// Deletes all but the `keptExports` newest export folders in `directory`.
    private static func prune(_ directory: URL) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return }
        let sorted = folders.map { url -> (URL, Date) in
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            return (url, values?.creationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in sorted.dropFirst(keptExports) { try? manager.removeItem(at: url) }
    }

    static func videoDuration(_ document: BoardDocument) -> Double {
        document.isAnimated ? document.duration : stillClipDuration
    }

    // MARK: Images

    static func imageData(document: BoardDocument, time: Double? = nil, size: CGSize, scale: CGFloat, jpeg: Bool) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let time = time ?? (document.isAnimated ? 0 : nil)
        if document.viewAngle.is3D {
            guard let image = TacticalBoard3DRenderer.image(document: document, time: time, size: size, scale: scale) else { return nil }
            let uiImage = UIImage(cgImage: image, scale: scale, orientation: .up)
            return jpeg ? uiImage.jpegData(compressionQuality: 0.92) : uiImage.pngData()
        }
        let draw: (UIGraphicsImageRendererContext) -> Void = { context in
            drawFrame(document: document, time: time, in: context.cgContext, size: size)
        }
        return jpeg ? renderer.jpegData(withCompressionQuality: 0.92, actions: draw) : renderer.pngData(actions: draw)
    }

    /// Small opaque preview stored next to the board for project lists. The folder is kept out of
    /// the device backup: every thumbnail is re-rendered from the board itself when it is missing,
    /// so backing them up would only cost the user space (unlike squad photos, which are theirs).
    static func writeThumbnail(document: BoardDocument, to url: URL) throws {
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        guard let data = imageData(document: document, size: CGSize(width: 480, height: 300), scale: 2, jpeg: false) else {
            throw ExportError.encodingFailed("the thumbnail could not be rendered")
        }
        try data.write(to: url, options: .atomic)
    }

    /// Draws one frame into a y-down context. 3D boards render through SceneKit at the
    /// context's device resolution; `offscreen` lets callers reuse one scene across frames.
    static func drawFrame(document: BoardDocument, time: Double?, in cg: CGContext, size: CGSize, offscreen: TacticalBoard3DOffscreen? = nil) {
        cg.setFillColor(background.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        if document.viewAngle.is3D {
            let deviceScale = max(1, abs(cg.userSpaceToDeviceSpaceTransform.d))
            let pixels = CGSize(width: (size.width * deviceScale).rounded(), height: (size.height * deviceScale).rounded())
            let image = offscreen.map { $0.image(document: document, time: time, pixelSize: pixels) }
                ?? TacticalBoard3DRenderer.image(document: document, time: time, size: size, scale: deviceScale)
            guard let image else { return }
            cg.saveGState()
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.interpolationQuality = .high
            cg.draw(image, in: CGRect(origin: .zero, size: size))
            cg.restoreGState()
            return
        }
        // Offscreen: decode squad photos from disk rather than skipping the ones not cached yet.
        BoardRenderer(document: document, time: time, inset: min(size.width, size.height) * 0.04,
                      loadsPhotosSynchronously: true).draw(in: cg, size: size)
    }

    // MARK: Video

    private static func writeVideo(_ request: BoardExportRequest, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let size = request.framing.videoSize
        let width = Int(size.width), height = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: request.format == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ExportError.encodingFailed("this video format is not supported here") }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.encodingFailed(writer.error?.localizedDescription ?? "the writer could not start") }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int((videoDuration(request.document) * Double(frameRate)).rounded(.up)))
        // 3D boards reuse one scene for every frame; only transforms change.
        let offscreen = request.document.viewAngle.is3D ? TacticalBoard3DOffscreen() : nil
        do {
            for frame in 0..<frameCount {
                try Task.checkCancellation()
                // Wait for the encoder, but never forever: a stalled encoder fails the export.
                var waited = 0
                while !input.isReadyForMoreMediaData {
                    waited += 1
                    if waited > 2500 { throw ExportError.encodingFailed(writer.error?.localizedDescription ?? "the video encoder stopped responding") }
                    try await Task.sleep(for: .milliseconds(4))
                }
                guard let pool = adaptor.pixelBufferPool else { throw ExportError.encodingFailed("no pixel buffer pool") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw ExportError.encodingFailed("no pixel buffer") }
                render(document: request.document, time: Double(frame) / Double(frameRate), into: buffer, offscreen: offscreen)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate)) else {
                    throw ExportError.encodingFailed(writer.error?.localizedDescription ?? "frame \(frame) was rejected")
                }
                progress(Double(frame + 1) / Double(frameCount))
            }
        } catch {
            // Cancelled or failed mid-file: release the encoder and leave no partial movie behind.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.encodingFailed(writer.error?.localizedDescription ?? "the file could not be finished")
        }
    }

    private static func render(document: BoardDocument, time: Double, into buffer: CVPixelBuffer, offscreen: TacticalBoard3DOffscreen?) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let cg = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        // Bitmap contexts are bottom-up; flip so the renderer draws with y down like SwiftUI.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        drawFrame(document: document, time: time, in: cg, size: CGSize(width: width, height: height), offscreen: offscreen)
    }

    // MARK: GIF

    private static func writeGIF(_ request: BoardExportRequest, to url: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        let fps = 12.0
        let frameCount = max(1, Int((videoDuration(request.document) * fps).rounded(.up)))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ExportError.encodingFailed("the GIF file could not be created")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        // A GIF destination writes as it goes, so a cancelled export must not leave the part it
        // already wrote on disk.
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: url) } }
        let size = request.framing.gifSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let offscreen = request.document.viewAngle.is3D ? TacticalBoard3DOffscreen() : nil
        for frame in 0..<frameCount {
            try Task.checkCancellation()
            let time = Double(frame) / fps
            let rendered: CGImage? = if let offscreen {
                offscreen.image(document: request.document, time: time, pixelSize: size)
            } else {
                renderer.image { context in drawFrame(document: request.document, time: time, in: context.cgContext, size: size) }.cgImage
            }
            guard let cgImage = rendered else { throw ExportError.encodingFailed("frame \(frame) could not be rendered") }
            CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            progress(Double(frame + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed("the GIF could not be written") }
        finished = true
    }

    private static func fileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted).joined().trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Tactical board" : cleaned
    }
}
