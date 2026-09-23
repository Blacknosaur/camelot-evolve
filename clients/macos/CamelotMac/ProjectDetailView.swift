import AppKit
import AVFoundation
import AVKit
import SwiftData
import SwiftUI

struct ProjectDetailView: View {
    let project: Project
    let appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(AppWindows.self) private var windows
    @Query private var events: [MatchEvent]
    @Query private var recordings: [Recording]
    @Query private var generatedVideos: [VideoComposition]
    @State private var editingProject = false
    @State private var deletionTarget: ProjectVideoItem?
    @State private var deletionError: String?

    init(project: Project, appState: AppState) {
        self.project = project
        self.appState = appState
        let id = project.id
        _events = Query(filter: #Predicate<MatchEvent> { $0.projectID == id && !$0.pendingDeletion })
        _recordings = Query(filter: #Predicate<Recording> { $0.projectID == id && !$0.pendingDeletion }, sort: \Recording.createdAt, order: .reverse)
        _generatedVideos = Query(filter: #Predicate<VideoComposition> { $0.projectID == id && !$0.pendingDeletion }, sort: \VideoComposition.createdAt, order: .reverse)
    }

    var body: some View {
        AdaptiveLayout { layout in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    header(layout: layout)
                    if recordings.isEmpty && generatedVideos.isEmpty {
                        emptyState
                    } else {
                        videoSection(title: "Videos", items: (recordings.map(ProjectVideoItem.source) + generatedVideos.map(ProjectVideoItem.generated)).sorted { $0.createdAt > $1.createdAt }, layout: layout)
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: layout.gridColumns > 1 ? .infinity : Theme.readableWidth + 200)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Record", systemImage: "record.circle") { openCamera() }
                    .help("Record a new video")
            }
            ToolbarItem {
                VideoImportButton(project: project)
            }
            ToolbarItem {
                Menu {
                    Button("Combine videos", systemImage: "rectangle.stack.badge.plus") { combineFirst() }
                        .disabled(recordings.isEmpty)
                    Divider()
                    Button("Edit project", systemImage: "pencil") { editingProject = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $editingProject) { ProjectFormView(project: project) }
        .confirmationDialog(
            "Delete this video?",
            isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }),
            titleVisibility: .visible,
            presenting: deletionTarget
        ) { item in
            Button("Delete permanently", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        } message: { item in
            Text(deletionMessage(for: item))
        }
        .alert("Could not delete video", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "The video remains available.")
        }
    }

    // MARK: Header

    private func header(layout: LayoutMetrics) -> some View {
        let summary = ProjectSummary(videos: recordings, generatedVideos: generatedVideos, events: events)
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Label(project.subtitle, systemImage: project.opponent.isEmpty ? "calendar" : "sportscourt")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if project.needsSync {
                    StatusPill(text: "Waiting to sync", tint: .orange, symbol: "arrow.up.circle")
                }
            }
            OrientationStack(isLandscape: layout.isLandscape && layout.size.width >= 640, spacing: Theme.Space.md, alignment: .top) {
                HStack(spacing: Theme.Space.sm) {
                    StatTile(value: "\(summary.videoCount + summary.highlightCount)", title: "Videos", symbol: "play.rectangle.fill", tint: Theme.brand)
                    StatTile(value: "\(summary.eventCount)", title: "Events", symbol: "flag.fill", tint: .green)
                }
                .frame(maxWidth: 420)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Window presentation

    private func openCamera() {
        windows.cameraProject = project
        openWindow(id: AppWindowID.camera)
    }

    private func combineFirst() {
        guard let recording = recordings.first else { return }
        windows.openEditor(recording: recording, startsInClips: true)
        openWindow(id: AppWindowID.editor)
    }

    private func openEditor(_ recording: Recording, composition: VideoComposition? = nil) {
        windows.openEditor(recording: recording, composition: composition)
        openWindow(id: AppWindowID.editor)
    }

    private func openComposition(_ video: VideoComposition) {
        windows.composition = video
        openWindow(id: AppWindowID.composition)
    }

    private func openRemote(_ recording: Recording) {
        windows.remoteRecording = recording
        openWindow(id: AppWindowID.remote)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No videos yet", systemImage: "play.rectangle")
        } description: {
            Text("Record a match or import a video from your library. Tag moments, arrange clips and render your video whenever you’re ready.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .card()
    }

    // MARK: Video sections

    private func videoSection(title: String, items: [ProjectVideoItem], layout: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionTitle(title) {
                Text("\(items.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if layout.gridColumns > 1 {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.md), count: layout.gridColumns), spacing: Theme.Space.md) {
                    ForEach(items) { item in videoCell(item, style: .card) }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        videoCell(item, style: .row)
                        if index < items.count - 1 { Divider().padding(.leading, 112) }
                    }
                }
                .card()
            }
        }
    }

    private func videoCell(_ item: ProjectVideoItem, style: VideoLibraryCell.Style) -> some View {
        HStack(spacing: 0) {
        Button { open(item) } label: {
            switch item {
            case .generated(let video):
                let stats = compositionStats(video)
                VideoLibraryCell(
                    style: style,
                    title: video.name,
                    subtitle: friendlyDate(video.createdAt),
                    duration: stats.duration,
                    eventCount: stats.eventCount,
                    thumbnailURL: stats.thumbnailURL,
                    thumbnailSeconds: stats.thumbnailSeconds,
                    icon: "play.fill",
                    tint: Theme.brand,
                    status: compositionStatus(video, clipCount: stats.clipCount)
                )
            case .source(let video):
                VideoLibraryCell(
                    style: style,
                    title: video.name.isEmpty ? friendlyDate(video.recordedAt) : video.name,
                    subtitle: video.name.isEmpty ? (video.endedReason == "imported" ? "Imported video" : "Recorded with Camelot") : friendlyDate(video.recordedAt),
                    duration: video.duration,
                    eventCount: eventCount(for: video),
                    thumbnailURL: hasLocalVideo(video) ? video.fileURL : video.remoteMediaURL,
                    thumbnailSeconds: min(1, video.duration / 2),
                    icon: "play.fill",
                    tint: Theme.brand,
                    status: videoStatus(video)
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.id)
        .contextMenu {
            Button("Open", systemImage: "play.fill") { open(item) }
            Button("Delete", systemImage: "trash", role: .destructive) { deletionTarget = item }
        }
        if isUnavailable(item) {
            Button(role: .destructive) { deletionTarget = item } label: {
                Image(systemName: "trash").frame(width: 44, height: 44).contentShape(.rect)
            }.buttonStyle(.plain).foregroundStyle(.red).padding(.trailing, 8)
                .accessibilityLabel("Delete unavailable video")
                .accessibilityIdentifier("delete-\(item.id)")
        }
        }
    }

    private func isUnavailable(_ item: ProjectVideoItem) -> Bool {
        switch item {
        case .source(let video): return !hasLocalVideo(video) && video.remoteMediaURL == nil
        case .generated(let video):
            guard CompositionRenderer.existingExportURL(id: video.id) == nil, video.remoteMediaURL == nil else { return false }
            guard let clips = video.decodedClips, !clips.isEmpty else { return true }
            return !clips.allSatisfy { clip in recordings.contains { $0.id == clip.recordingID && hasLocalVideo($0) } }
        }
    }

    private func open(_ item: ProjectVideoItem) {
        switch item {
        case .generated(let video):
            if let clips = video.decodedClips, !clips.isEmpty,
               clips.allSatisfy({ clip in recordings.contains { $0.id == clip.recordingID && hasLocalVideo($0) } }),
               let first = clips.first, let source = recordings.first(where: { $0.id == first.recordingID }) {
                openEditor(source, composition: video)
            } else { openComposition(video) }
        case .source(let video):
            if hasLocalVideo(video) { openEditor(video) } else { openRemote(video) }
        }
    }

    // MARK: Deletion

    private func deletionMessage(for item: ProjectVideoItem) -> String {
        switch item {
        case .generated:
            return "The video edit and its rendered file will be removed from every synced device. Original videos are not affected."
        case .source(let recording):
            let dependentCount = generatedVideos.lazy.filter { compositionUses($0, recordingID: recording.id) }.count
            let suffix = dependentCount == 0 ? "" : " \(dependentCount) video edit\(dependentCount == 1 ? "" : "s") that use this video will also be removed."
            return "The original video and its events will be removed from every synced device.\(suffix) This cannot be undone."
        }
    }

    private func delete(_ item: ProjectVideoItem) {
        deletionTarget = nil
        do {
            switch item {
            case .generated(let composition): try RecordingLibrary.deleteVideo(composition: composition, context: modelContext)
            case .source(let recording): try RecordingLibrary.deleteVideo(recording: recording, context: modelContext)
            }
            Task { await appState.sync(modelContext: modelContext) }
        } catch { deletionError = error.localizedDescription }
    }

    private func compositionUses(_ composition: VideoComposition, recordingID: UUID) -> Bool {
        guard let data = composition.clipManifest.data(using: .utf8),
              let clips = try? JSONDecoder().decode([CompositionClip].self, from: data) else { return false }
        return clips.contains { $0.recordingID == recordingID }
    }

    // MARK: Status helpers

    private func eventCount(for video: Recording) -> Int {
        events.lazy.filter { $0.recordingID == video.id }.count
    }

    private func hasLocalVideo(_ video: Recording) -> Bool {
        guard !video.localPath.isEmpty,
              let values = try? video.fileURL.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true
    }

    private func videoStatus(_ video: Recording) -> VideoStatus {
        switch video.uploadState {
        case "uploaded": VideoStatus(text: "Synced", tint: .green, symbol: "checkmark.icloud")
        case "uploading": VideoStatus(text: uploadProgressLabel(video, prefix: "Uploading"), tint: Theme.brand, symbol: "icloud.and.arrow.up")
        case "paused": VideoStatus(text: uploadProgressLabel(video, prefix: "Paused"), tint: .orange, symbol: "pause.circle")
        case "missing": VideoStatus(text: "Unavailable", tint: .red, symbol: "exclamationmark.triangle")
        case "remote": VideoStatus(text: "In the cloud", tint: .secondary, symbol: "icloud")
        default: VideoStatus(text: "On device", tint: .secondary, symbol: "iphone")
        }
    }

    private func uploadProgressLabel(_ video: Recording, prefix: String) -> String {
        guard video.uploadedBytes > 0,
              let size = try? video.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return prefix }
        let percent = min(100, Int((Double(video.uploadedBytes) / Double(size) * 100).rounded()))
        return "\(prefix) \(percent)%"
    }

    private func compositionStatus(_ video: VideoComposition, clipCount: Int) -> VideoStatus {
        let clips = clipCount == 1 ? "1 clip" : "\(clipCount) clips"
        switch video.uploadState {
        case "uploaded": return VideoStatus(text: "Shared · \(clips)", tint: .green, symbol: "link")
        case "uploading":
            guard let url = CompositionRenderer.existingExportURL(id: video.id),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 else { return VideoStatus(text: "Uploading", tint: Theme.brand, symbol: "icloud.and.arrow.up") }
            let percent = min(100, Int((Double(video.uploadedBytes) / Double(size) * 100).rounded()))
            return VideoStatus(text: "Uploading \(percent)%", tint: Theme.brand, symbol: "icloud.and.arrow.up")
        case "paused": return VideoStatus(text: "Waiting · \(clips)", tint: .orange, symbol: "pause.circle")
        default:
            return CompositionRenderer.existingExportURL(id: video.id) == nil
                ? VideoStatus(text: "Ready to render · \(clips)", tint: .secondary, symbol: "film")
                : VideoStatus(text: "Rendered · \(clips)", tint: .secondary, symbol: "iphone")
        }
    }

    private func compositionStats(_ video: VideoComposition) -> (duration: Double, eventCount: Int, clipCount: Int, thumbnailURL: URL?, thumbnailSeconds: Double) {
        guard let data = video.clipManifest.data(using: .utf8),
              let clips = try? JSONDecoder().decode([CompositionClip].self, from: data) else { return (0, 0, 0, nil, 0) }
        let duration = clips.reduce(0) {
            $0 + $1.playbackDuration
        }
        let includedEvents = events.lazy.filter { event in
            guard let recordingID = event.recordingID else { return false }
            return clips.contains { $0.recordingID == recordingID && event.offsetSeconds >= $0.startSeconds && event.offsetSeconds <= $0.endSeconds }
        }.count
        if let exported = CompositionRenderer.existingExportURL(id: video.id) {
            return (duration, includedEvents, clips.count, exported, min(0.5, max(0, duration / 2)))
        }
        if let remote = video.remoteMediaURL {
            return (duration, includedEvents, clips.count, remote, min(0.5, max(0, duration / 2)))
        }
        let available = recordings.filter { FileManager.default.fileExists(atPath: $0.fileURL.path()) }
        let first = clips.first(where: { clip in available.contains { $0.id == clip.recordingID } })
        let source = first.flatMap { clip in available.first(where: { $0.id == clip.recordingID }) }
        let thumbnailSeconds = min(max(0, (first?.startSeconds ?? 0) + 0.25), max(0, (source?.duration ?? 0) - 0.1))
        return (duration, includedEvents, clips.count, source?.fileURL, thumbnailSeconds)
    }
}

// MARK: - Cells

private struct VideoStatus {
    let text: String
    let tint: Color
    let symbol: String
}

private struct VideoLibraryCell: View {
    enum Style { case row, card }

    let style: Style
    let title: String
    let subtitle: String
    let duration: Double
    let eventCount: Int
    let thumbnailURL: URL?
    let thumbnailSeconds: Double
    let icon: String
    let tint: Color
    let status: VideoStatus

    var body: some View {
        Group {
            switch style {
            case .row: row
            case .card: card
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(compactDuration(duration)), \(eventCount) events, \(status.text)")
        .accessibilityAddTraits(.isButton)
    }

    private var row: some View {
        HStack(spacing: Theme.Space.md) {
            thumbnail.frame(width: 96, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: Theme.Space.md) {
                    MetaLabel(compactDuration(duration), symbol: "clock")
                    MetaLabel("\(eventCount)", symbol: "flag.fill")
                    StatusPill(text: status.text, tint: status.tint, symbol: status.symbol)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.md)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    Text(compactDuration(duration))
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: .capsule)
                        .padding(Theme.Space.sm)
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: Theme.Space.md) {
                    MetaLabel("\(eventCount) events", symbol: "flag.fill")
                    Spacer(minLength: 0)
                    StatusPill(text: status.text, tint: status.tint, symbol: status.symbol)
                }
            }
            .padding(Theme.Space.md)
        }
        .card()
    }

    private var thumbnail: some View {
        VideoThumbnailView(url: thumbnailURL, seconds: thumbnailSeconds, icon: icon, tint: tint)
    }
}

// MARK: - Remote playback

struct RemoteVideoPlayerView: View {
    let recording: Recording
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var events: [MatchEvent]
    @State private var player: AVPlayer?
    @State private var isDownloading = false
    @State private var errorMessage: String?

    init(recording: Recording, onClose: (() -> Void)? = nil) {
        self.recording = recording
        self.onClose = onClose
        let recordingID = recording.id
        _events = Query(filter: #Predicate<MatchEvent> {
            $0.recordingID == recordingID && !$0.pendingDeletion
        }, sort: \MatchEvent.offsetSeconds)
        _player = State(initialValue: recording.remoteMediaURL.map(AVPlayer.init(url:)))
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        NavigationStack {
            AdaptiveLayout { layout in
                if recording.remoteMediaURL != nil {
                    OrientationStack(isLandscape: layout.isLandscape, spacing: 0, alignment: .top) {
                        VideoPlayer(player: player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black)
                        VStack(spacing: 0) {
                            if !events.isEmpty { eventChips }
                            downloadPanel
                        }
                        .frame(maxWidth: layout.isLandscape ? 320 : .infinity)
                        .frame(maxHeight: layout.isLandscape ? .infinity : nil)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                } else {
                    ContentUnavailableView {
                        Label("Video unavailable", systemImage: "icloud.slash")
                    } description: {
                        Text("There is no playable copy on this device or in the cloud.")
                    } actions: {
                        VideoDeletionButton(recording: recording) { close() }
                    }
                }
            }
            .background(.black)
            .onDisappear { player?.pause() }
            .navigationTitle(recording.name.isEmpty ? "Video" : recording.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { close() } }
                if let value = recording.shareURL, let url = URL(string: value) {
                    ToolbarItem(placement: .confirmationAction) { ShareLink(item: url) }
                }
            }
            .alert("Download failed", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "Unknown error") }
        }
    }

    private var eventChips: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Theme.Space.sm) {
                ForEach(events) { event in
                    Button {
                        player?.seek(to: CMTime(seconds: event.offsetSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                        player?.play()
                    } label: {
                        Label("\(event.kind) · \(compactDuration(event.offsetSeconds))", systemImage: EventKind.symbol(for: event.kind))
                            .font(.caption.bold())
                            .padding(.horizontal, 12).frame(minHeight: 40)
                            .background(event.tint.opacity(0.14), in: .capsule)
                            .foregroundStyle(event.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
        }
        .scrollIndicators(.hidden)
    }

    private var downloadPanel: some View {
        VStack(spacing: Theme.Space.md) {
            if isDownloading {
                ProgressView("Downloading for offline use…")
            } else if recording.localPath.isEmpty {
                Button {
                    Task { await download() }
                } label: {
                    Label("Download to device", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.primary)
                Text("Downloading lets you edit, trim and combine clips from this video.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Label("Available offline", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.lg)
    }

    @MainActor private func download() async {
        guard let source = recording.remoteMediaURL else { return }
        isDownloading = true
        defer { isDownloading = false }
        do {
            let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
            try RecordingLibrary.prepareMediaDirectory(folder)
            let partial = folder.appending(path: "\(recording.id.uuidString).download")
            let downloaded = try await ResumableMediaDownload.download(from: source, partialURL: partial)
            let fileExtension = downloaded.mimeType == "video/mp4" ? "mp4" : "mov"
            let destination = folder.appending(path: recording.id.uuidString).appendingPathExtension(fileExtension)
            let asset = AVURLAsset(url: partial)
            async let loadedDuration = asset.load(.duration)
            async let loadedTracks = asset.loadTracks(withMediaType: .video)
            let (duration, tracks) = try await (loadedDuration, loadedTracks)
            guard duration.seconds.isFinite, duration.seconds > 0.05, !tracks.isEmpty else {
                try? FileManager.default.removeItem(at: partial)
                throw RemoteDownloadError.invalidMedia
            }
            if FileManager.default.fileExists(atPath: destination.path()) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: destination)
            }
            recording.localPath = destination.lastPathComponent
            recording.duration = duration.seconds
            recording.uploadState = "uploaded"
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum ResumableMediaDownload {
    struct Result: Sendable {
        let mimeType: String?
    }

    static func download(from source: URL, partialURL: URL) async throws -> Result {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let existingBytes = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var request = URLRequest(url: source)
            if existingBytes > 0 { request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range") }
            let (temporary, response) = try await URLSession.shared.download(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw RemoteDownloadError.invalidResponse }
            if http.statusCode == 416, existingBytes > 0, attempt == 0 {
                try? FileManager.default.removeItem(at: partialURL)
                continue
            }
            guard http.statusCode == 200 || http.statusCode == 206 else { throw RemoteDownloadError.invalidResponse }
            if http.statusCode == 206, existingBytes > 0 {
                try await append(contentsOf: temporary, to: partialURL)
            } else {
                try? FileManager.default.removeItem(at: partialURL)
                try FileManager.default.moveItem(at: temporary, to: partialURL)
            }
            return Result(mimeType: response.mimeType)
        }
        throw RemoteDownloadError.invalidResponse
    }

    private static func append(contentsOf source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
                try? FileManager.default.removeItem(at: source)
            }
            try output.seekToEnd()
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
        }.value
    }
}

private enum RemoteDownloadError: LocalizedError {
    case invalidResponse, invalidMedia
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server did not return the video."
        case .invalidMedia: "The downloaded file is not a playable video."
        }
    }
}

private enum ProjectVideoItem: Identifiable {
    case source(Recording)
    case generated(VideoComposition)

    var createdAt: Date {
        switch self { case .source(let video): video.createdAt; case .generated(let video): video.createdAt }
    }

    var id: String {
        switch self {
        case .source(let video): "source-\(video.id.uuidString)"
        case .generated(let video): "generated-\(video.id.uuidString)"
        }
    }
}

/// The same confirmed deletion is available even when a video cannot open in the editor.
struct VideoDeletionButton: View {
    var recording: Recording? = nil
    var composition: VideoComposition? = nil
    let didDelete: () -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        Button(role: .destructive) { confirming = true } label: {
            Label("Delete video", systemImage: "trash").frame(minHeight: 44).contentShape(.rect)
        }.tint(.red)
        .alert("Delete this video?", isPresented: $confirming) {
            Button("Delete permanently", role: .destructive) {
                do {
                    try RecordingLibrary.deleteVideo(recording: recording, composition: composition, context: modelContext)
                    didDelete()
                } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(recording == nil
                ? "This removes this video edit and its rendered file from every synced device. Source videos are kept. This cannot be undone."
                : "This removes the video, its events and any saved edits that use it from every synced device. This cannot be undone.")
        }
        .alert("Could not delete video", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
