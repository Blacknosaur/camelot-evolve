import AppKit
@preconcurrency import AVFoundation
import AVKit
import OSLog
import SwiftData
import SwiftUI

private let playerLog = Logger(subsystem: "com.camelot.evolve", category: "CompositionPlayer")

struct CompositionPlayerView: View {
    let composition: VideoComposition
    let allowsDeletion: Bool
    var onClose: (() -> Void)?
    private let clips: [CompositionClip]
    private let summaryDuration: Double
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query private var recordings: [Recording]
    @State private var player: AVPlayer?
    @State private var preparedAsset: AVMutableComposition?
    @State private var preparedVideoComposition: AVMutableVideoComposition?
    @State private var exportURL: URL?
    @State private var isPreparing = true
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?
    @State private var isDownloading = false
    /// Why the preview could not be built; shown inline in the player surface.
    @State private var preparationError: String?
    /// Export or download failure; shown as an alert.
    @State private var errorMessage: String?

    init(composition: VideoComposition, allowsDeletion: Bool = false, onClose: (() -> Void)? = nil) {
        self.composition = composition; self.allowsDeletion = allowsDeletion; self.onClose = onClose
        let decodedClips = composition.clipManifest.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([CompositionClip].self, from: $0) } ?? []
        clips = decodedClips
        summaryDuration = decodedClips.reduce(0) {
            $0 + $1.playbackDuration
        }
        let projectID = composition.projectID
        _recordings = Query(filter: #Predicate<Recording> { $0.projectID == projectID && !$0.pendingDeletion })
    }

    var body: some View {
        NavigationStack {
            AdaptiveLayout { layout in
                OrientationStack(isLandscape: layout.isLandscape, spacing: 0, alignment: .top) {
                    playerSurface
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: layout.isLandscape ? .infinity : nil)
                        .background(.black)
                    detailPanel(layout: layout)
                        .frame(maxWidth: layout.isLandscape ? 340 : .infinity)
                        .frame(maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(composition.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
            .task {
                exportURL = CompositionRenderer.existingExportURL(id: composition.id)
                await preparePlayer()
            }
            .alert(isDownloading ? "Download failed" : "Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "Unknown error") }
            .onDisappear { player?.pause(); exportTask?.cancel(); downloadTask?.cancel() }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var playerSurface: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else if isPreparing {
                ProgressView("Preparing video…").tint(.white).foregroundStyle(.white)
            } else {
                ContentUnavailableView {
                    Label("Cannot play video", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(preparationError ?? "Its original videos are unavailable.")
                } actions: {
                    if allowsDeletion { VideoDeletionButton(composition: composition) { close() } }
                }.foregroundStyle(.white)
            }
        }
        .aspectRatio(previewAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailPanel(layout: LayoutMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack(spacing: Theme.Space.sm) {
                    StatTile(value: "\(clips.count)", title: clips.count == 1 ? "Clip" : "Clips", symbol: "film.stack", tint: Theme.highlight)
                    StatTile(value: compactDuration(summaryDuration), title: "Duration", symbol: "clock", tint: Theme.brand)
                    StatTile(value: aspectTitle, title: "Format", symbol: "aspectratio", tint: .secondary)
                }

                VStack(spacing: Theme.Space.sm) {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share or save video", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.primary)
                    } else if composition.remoteMediaURL != nil {
                        Button(action: downloadRemoteExport) {
                            Label("Download for offline use", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.primary)
                        .disabled(isDownloading)
                    } else {
                        Button(action: export) {
                            Label("Render video", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.primary)
                        .disabled(isPreparing || isExporting || preparedAsset == nil)
                    }
                    if let value = composition.shareURL, let webURL = URL(string: value) {
                        ShareLink(item: webURL) {
                            Label("Share web player link", systemImage: "link")
                        }
                        .buttonStyle(.secondary)
                    }
                }

                if isExporting {
                    progressCard(title: exportProgress < 0.02 ? "Preparing export…" : "Rendering \(Int(exportProgress * 100))%", progress: exportProgress) {
                        exportTask?.cancel()
                    }
                }
                if isDownloading {
                    progressCard(title: "Downloading and checking video…", progress: nil) {
                        downloadTask?.cancel()
                    }
                }

                Text(footerText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: layout.isLandscape ? .infinity : Theme.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func progressCard(title: String, progress: Double?, cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let progress {
                ProgressView(value: progress).tint(Theme.brand)
            } else {
                ProgressView()
            }
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).font(.caption.bold())
            }
        }
        .padding(Theme.Space.md)
        .card()
    }

    private var aspectTitle: String {
        switch composition.aspectRatio {
        case "portrait": "9:16"
        case "square": "1:1"
        case "landscape": "16:9"
        default: "Original"
        }
    }

    private var footerText: String {
        if exportURL != nil {
            return "The exported file is stored on this device. Camelot uploads it during sync and creates a web-player link."
        }
        if composition.remoteMediaURL != nil {
            return "This video was exported on another device. Download it to watch offline or share the file."
        }
        return "Export creates one shareable video without changing the originals. Camelot uploads exported videos during sync and creates a web-player link."
    }

    private var previewAspectRatio: CGFloat {
        switch composition.aspectRatio {
        case "portrait": 9 / 16
        case "square": 1
        default: 16 / 9
        }
    }

    @MainActor private func preparePlayer() async {
        if let exportURL {
            player = AVPlayer(url: exportURL)
            isPreparing = false
            return
        }
        if let remoteURL = composition.remoteMediaURL {
            player = AVPlayer(url: remoteURL)
            isPreparing = false
            return
        }
        do {
            let asset = try await CompositionRenderer.makeAsset(clips: clips, recordings: recordings)
            preparedAsset = asset
            let videoComposition: AVMutableVideoComposition?
            if clips.count > 1 || clips.contains(where: { !$0.annotations.isEmpty || $0.freezeDuration != nil }) {
                videoComposition = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: clips, recordings: recordings, aspectRatio: composition.aspectRatio, maximumDimension: nil)
            } else {
                videoComposition = try await CompositionRenderer.makeCropComposition(asset: asset, aspectRatio: composition.aspectRatio)
            }
            preparedVideoComposition = videoComposition
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = videoComposition
            player = AVPlayer(playerItem: item)
        } catch {
            playerLog.error("Could not prepare composition \(composition.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            preparationError = Self.describe(error)
        }
        isPreparing = false
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(nsError.localizedDescription) (\(underlying.domain) \(underlying.code))"
        }
        return nsError.localizedFailureReason.map { "\(nsError.localizedDescription) \($0)" } ?? "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    private func export() {
        exportProgress = 0
        isExporting = true
        exportTask = Task { @MainActor in
            defer { isExporting = false; exportTask = nil }
            do {
                if let sourceURL = directExportSourceURL {
                    exportURL = try CompositionRenderer.cloneExport(sourceURL: sourceURL, id: composition.id)
                    exportProgress = 1
                } else {
                    let asset: AVAsset
                    if let preparedAsset {
                        asset = preparedAsset
                    } else {
                        asset = try await CompositionRenderer.makeAsset(clips: clips, recordings: recordings)
                    }
                    exportURL = try await CompositionRenderer.export(asset: asset, id: composition.id, videoComposition: preparedVideoComposition) { exportProgress = $0 }
                }
                composition.uploadState = "local"
                composition.uploadedBytes = 0
                composition.shareURL = nil
                try modelContext.save()
                Task { await appState.sync(modelContext: modelContext) }
            } catch is CancellationError {
                exportProgress = 0
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func downloadRemoteExport() {
        guard let remoteURL = composition.remoteMediaURL else { return }
        isDownloading = true
        downloadTask = Task { @MainActor in
            defer { isDownloading = false; downloadTask = nil }
            do {
                let folder = URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory)
                try RecordingLibrary.prepareMediaDirectory(folder)
                let staging = folder.appending(path: "\(composition.id.uuidString).download")
                let downloaded = try await ResumableMediaDownload.download(from: remoteURL, partialURL: staging)
                let asset = AVURLAsset(url: staging)
                async let loadedDuration = asset.load(.duration)
                async let loadedTracks = asset.loadTracks(withMediaType: .video)
                let (duration, tracks) = try await (loadedDuration, loadedTracks)
                guard duration.seconds.isFinite, duration.seconds > 0.05, !tracks.isEmpty else {
                    try? FileManager.default.removeItem(at: staging)
                    throw RemoteCompositionError.invalidMedia
                }
                try Task.checkCancellation()
                let fileExtension = downloaded.mimeType == "video/quicktime" ? "mov" : "mp4"
                let destination = folder.appending(path: composition.id.uuidString).appendingPathExtension(fileExtension)
                if FileManager.default.fileExists(atPath: destination.path()) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: destination)
                }
                exportURL = destination
                player?.pause()
                player = AVPlayer(url: destination)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var directExportSourceURL: URL? {
        guard composition.aspectRatio == "original",
              clips.count == 1,
              let clip = clips.first,
              clip.annotations.isEmpty, clip.freezeDuration == nil,
              abs(clip.rate - 1) < 0.001,
              let recording = recordings.first(where: { $0.id == clip.recordingID }),
              clip.startSeconds <= 0.05,
              clip.endSeconds >= recording.duration - 0.05,
              FileManager.default.fileExists(atPath: recording.fileURL.path()) else { return nil }
        return recording.fileURL
    }
}

private enum RemoteCompositionError: LocalizedError {
    case invalidResponse, invalidMedia

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server did not return the video."
        case .invalidMedia: "The downloaded video is not a playable video."
        }
    }
}

@MainActor enum CompositionRenderer {
    static func existingExportURL(id: UUID) -> URL? {
        let folder = URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        for fileExtension in ["mp4", "mov"] {
            let url = folder.appending(path: id.uuidString).appendingPathExtension(fileExtension)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { continue }
            return url
        }
        return nil
    }

    static func cloneExport(sourceURL: URL, id: UUID) throws -> URL {
        let folder = URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try RecordingLibrary.prepareMediaDirectory(folder)
        let sourceExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let destination = folder.appending(path: id.uuidString).appendingPathExtension(sourceExtension)
        let temporary = folder.appending(path: "\(id.uuidString).partial").appendingPathExtension(sourceExtension)
        try? FileManager.default.removeItem(at: temporary)
        var retainedOutput = false
        defer {
            if !retainedOutput { try? FileManager.default.removeItem(at: temporary) }
        }
        try FileManager.default.copyItem(at: sourceURL, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path()) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        retainedOutput = true
        return destination
    }

    static func makeAsset(clips: [CompositionClip], recordings: [Recording]) async throws -> AVMutableComposition {
        let result = AVMutableComposition()
        guard let videoOutput = result.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioOutput = result.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.cannotCreateTracks
        }
        let requestedIDs = Set(clips.map(\.recordingID))
        let requestedRecordings = recordings.filter {
            requestedIDs.contains($0.id) && FileManager.default.fileExists(atPath: $0.fileURL.path())
        }
        let requestedSources = requestedRecordings.map { ($0.id, $0.fileURL) }
        let sources = try await withThrowingTaskGroup(of: (UUID, SourceMedia).self) { group in
            for (id, url) in requestedSources {
                group.addTask {
                    (id, try await loadSourceMedia(url: url))
                }
            }
            var loaded: [UUID: SourceMedia] = [:]
            loaded.reserveCapacity(requestedRecordings.count)
            for try await (id, source) in group { loaded[id] = source }
            return loaded
        }
        var cursor = CMTime.zero
        var inserted = 0
        for clip in clips {
            guard let source = sources[clip.recordingID] else { continue }
            let duration = source.duration
            let start = max(0, min(duration, clip.startSeconds))
            let end = max(start, min(duration, clip.endSeconds))
            guard end > start else { continue }
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: end - start, preferredTimescale: 600))
            let outputDuration = CMTime(seconds: clip.playbackDuration, preferredTimescale: 600)
            let outputRange = CMTimeRange(start: cursor, duration: range.duration)
            if let sourceVideo = source.video, let sourceRange = source.videoRange {
                let available = CMTimeRangeGetIntersection(range, otherRange: sourceRange)
                guard CMTimeCompare(available.duration, .zero) > 0 else { continue }
                do {
                    try videoOutput.insertTimeRange(available, of: sourceVideo, at: cursor + (available.start - range.start))
                } catch {
                    playerLog.error("Video insert failed for \(clip.recordingID.uuidString, privacy: .public) range \(available.start.seconds)-\(available.end.seconds) source \(sourceRange.start.seconds)-\(sourceRange.end.seconds): \(String(describing: error), privacy: .public)")
                    throw error
                }
                if inserted == 0, let transform = source.videoTransform { videoOutput.preferredTransform = transform }
            }
            if clip.freezeDuration == nil, let sourceAudio = source.audio, let sourceRange = source.audioRange {
                let available = CMTimeRangeGetIntersection(range, otherRange: sourceRange)
                if CMTimeCompare(available.duration, .zero) > 0 {
                    do {
                        try audioOutput.insertTimeRange(available, of: sourceAudio, at: cursor + (available.start - range.start))
                    } catch {
                        playerLog.error("Audio insert failed for \(clip.recordingID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                        throw error
                    }
                }
            }
            if CMTimeCompare(outputDuration, range.duration) != 0 {
                videoOutput.scaleTimeRange(outputRange, toDuration: outputDuration)
                audioOutput.scaleTimeRange(outputRange, toDuration: outputDuration)
            }
            cursor = cursor + outputDuration
            inserted += 1
        }
        guard inserted > 0 else { throw RenderError.noMedia }
        // An empty audio track makes AVAssetExportSession reject otherwise valid
        // silent footage and held-frame sequences during media validation.
        if audioOutput.segments.allSatisfy(\.isEmpty) { result.removeTrack(audioOutput) }
        return result
    }

    private nonisolated static func loadSourceMedia(url: URL) async throws -> SourceMedia {
        let asset = AVURLAsset(url: url)
        async let loadedVideo = asset.loadTracks(withMediaType: .video)
        async let loadedAudio = asset.loadTracks(withMediaType: .audio)
        async let loadedDuration = asset.load(.duration)
        let (videoTracks, audioTracks, assetDuration) = try await (loadedVideo, loadedAudio, loadedDuration)
        let video = videoTracks.first
        let audio = audioTracks.first
        let videoRange = try await video?.load(.timeRange)
        let videoTransform = try await video?.load(.preferredTransform)
        let audioRange = try await audio?.load(.timeRange)
        return SourceMedia(
            asset: asset,
            duration: assetDuration.seconds,
            video: video,
            videoRange: videoRange,
            videoTransform: videoTransform,
            audio: audio,
            audioRange: audioRange
        )
    }

    private struct SourceMedia: @unchecked Sendable {
        /// Tracks only hold their asset weakly; keep it alive until the composition is built.
        let asset: AVURLAsset
        let duration: Double
        let video: AVAssetTrack?
        let videoRange: CMTimeRange?
        let videoTransform: CGAffineTransform?
        let audio: AVAssetTrack?
        let audioRange: CMTimeRange?
    }

    static func export(asset: AVAsset, id: UUID, videoComposition: AVVideoComposition? = nil, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let folder = URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try RecordingLibrary.prepareMediaDirectory(folder)
        var lastError: Error?
        let usesPassthrough = videoComposition == nil ? try await canPassthrough(asset) : false
        let presets = usesPassthrough ? [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] : [AVAssetExportPresetHighestQuality]
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let type: AVFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
            let fileExtension = type == .mp4 ? "mp4" : "mov"
            let url = folder.appending(path: id.uuidString).appendingPathExtension(fileExtension)
            let temporaryURL = folder.appending(path: "\(id.uuidString).partial").appendingPathExtension(fileExtension)
            try? FileManager.default.removeItem(at: temporaryURL)
            var retainedOutput = false
            defer {
                if !retainedOutput { try? FileManager.default.removeItem(at: temporaryURL) }
            }
            session.outputURL = temporaryURL; session.outputFileType = type; session.shouldOptimizeForNetworkUse = true
            session.videoComposition = videoComposition
            progress(0)
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let cancellation = ExportCancellation(session)
            await withTaskCancellationHandler {
                await session.export()
            } onCancel: {
                cancellation.cancel()
            }
            progressTask.cancel()
            try Task.checkCancellation()
            if session.status == .completed {
                if FileManager.default.fileExists(atPath: url.path()) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: url)
                }
                retainedOutput = true
                return url
            }
            lastError = session.error
        }
        throw lastError ?? RenderError.cannotExport
    }

    private static func canPassthrough(_ asset: AVAsset) async throws -> Bool {
        var videoFormats = Set<String>()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        var sourceURLs = Set<URL>()
        for track in videoTracks {
            for description in try await track.load(.formatDescriptions) {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                videoFormats.insert("\(CMFormatDescriptionGetMediaSubType(description))-\(dimensions.width)x\(dimensions.height)")
            }
            if let compositionTrack = track as? AVCompositionTrack {
                for segment in compositionTrack.segments {
                    if let url = segment.sourceURL { sourceURLs.insert(url) }
                    if CMTimeCompare(segment.timeMapping.source.duration, segment.timeMapping.target.duration) != 0 {
                        return false
                    }
                }
            }
        }
        let videoTransforms = try await withThrowingTaskGroup(of: String?.self) { group in
            for url in sourceURLs {
                group.addTask { try await transformKey(url: url) }
            }
            var values = Set<String>()
            for try await value in group { if let value { values.insert(value) } }
            return values
        }
        var audioFormats = Set<FourCharCode>()
        for track in try await asset.loadTracks(withMediaType: .audio) {
            for description in try await track.load(.formatDescriptions) {
                audioFormats.insert(CMFormatDescriptionGetMediaSubType(description))
            }
        }
        return videoFormats.count == 1 && videoTransforms.count <= 1 && audioFormats.count <= 1
    }

    static func makeCropComposition(asset: AVAsset, aspectRatio: String) async throws -> AVMutableVideoComposition? {
        let ratio: CGFloat
        switch aspectRatio {
        case "landscape": ratio = 16 / 9
        case "square": ratio = 1
        case "portrait": ratio = 9 / 16
        default: return nil
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        async let loadedSize = track.load(.naturalSize)
        async let loadedTransform = track.load(.preferredTransform)
        async let loadedFrameRate = track.load(.nominalFrameRate)
        async let loadedDuration = asset.load(.duration)
        let (naturalSize, transform, frameRate, duration) = try await (loadedSize, loadedTransform, loadedFrameRate, loadedDuration)
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        guard displayRect.width > 0, displayRect.height > 0 else { return nil }
        let displaySize = displayRect.size
        let cropSize: CGSize
        if displaySize.width / displaySize.height > ratio {
            cropSize = CGSize(width: displaySize.height * ratio, height: displaySize.height)
        } else {
            cropSize = CGSize(width: displaySize.width, height: displaySize.width / ratio)
        }
        let cropOrigin = CGPoint(x: (displaySize.width - cropSize.width) / 2, y: (displaySize.height - cropSize.height) / 2)
        let normalized = transform.concatenating(CGAffineTransform(
            translationX: -displayRect.minX - cropOrigin.x,
            y: -displayRect.minY - cropOrigin.y
        ))
        let output = AVMutableVideoComposition()
        output.renderSize = CGSize(width: max(2, floor(cropSize.width / 2) * 2), height: max(2, floor(cropSize.height / 2) * 2))
        output.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(60, frameRate.rounded()))))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(normalized, at: .zero)
        instruction.layerInstructions = [layer]
        output.instructions = [instruction]
        return output
    }

    private nonisolated static func transformKey(url: URL) async throws -> String? {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { return nil }
        let transform = try await track.load(.preferredTransform)
        return [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
            .map { String(format: "%.3f", $0) }.joined(separator: ",")
    }
}

private final class ExportCancellation: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

private enum RenderError: LocalizedError {
    case cannotCreateTracks, noMedia, cannotExport
    var errorDescription: String? {
        switch self {
        case .cannotCreateTracks: "The video timeline could not be created."
        case .noMedia: "None of the original videos are available on this device."
        case .cannotExport: "The summary could not be exported."
        }
    }
}

private func summaryTimecode(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}
