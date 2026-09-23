import AVFoundation
import AVKit
import SwiftData
import SwiftUI

struct ProjectDetailView: View {
    let project: Project
    let appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query private var events: [MatchEvent]
    @Query private var recordings: [Recording]
    @Query private var generatedVideos: [VideoComposition]
    @State private var showingCamera = false
    @State private var showingVideoImport = false
    @State private var isImportingVideo = false
    @State private var choosingMultiCam = false
    @State private var multiCamMode: MultiCamMode?
    @State private var stitching: Recording?
    @State private var editingProject = false
    @State private var editingVideo: Recording?
    @State private var combiningVideo: Recording?
    @State private var editingComposition: VideoComposition?
    @State private var viewingGeneratedVideo: VideoComposition?
    @State private var viewingRemoteVideo: Recording?
    @State private var deletionTarget: ProjectVideoItem?
    @State private var deletionError: String?
    @State private var searchText = ""
    @State private var selectedKinds: Set<String> = []

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
            let items = allItems
            let visible = filtered(items)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    summaryLine(total: items.count, shown: visible.count)
                    if let pending = pendingWideView { wideViewBanner(camera: pending) }
                    if !availableKinds.isEmpty { kindFilters }
                    if items.isEmpty {
                        emptyState.padding(.top, Theme.Space.sm)
                    } else if visible.isEmpty {
                        noResultsState.padding(.top, Theme.Space.sm)
                    } else {
                        videoSection(items: visible, layout: layout)
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.sm)
                .frame(maxWidth: layout.gridColumns > 1 ? .infinity : Theme.readableWidth + 200)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search videos, notes and events")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Record", systemImage: "video.fill") { showingCamera = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Multi-cam session", systemImage: "rectangle.3.group") { choosingMultiCam = true }
                        .accessibilityIdentifier("project-multicam")
                    importVideoButton
                    Button("Combine videos", systemImage: "rectangle.stack.badge.plus") { combiningVideo = recordings.first }
                        .disabled(recordings.isEmpty)
                    Divider()
                    Button("Edit project", systemImage: "pencil") { editingProject = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("project-more")
            }
        }
        .videoImporter(project: project, isPresented: $showingVideoImport, isImporting: $isImportingVideo) {
            searchText = ""; selectedKinds.removeAll()
        }
        .fullScreenCover(isPresented: $showingCamera) { CameraCaptureView(project: project, appState: appState) }
        .sheet(isPresented: $choosingMultiCam) { MultiCamSetupView(project: project) { multiCamMode = $0 } }
        .fullScreenCover(item: $multiCamMode) { mode in
            if mode == .eventRemote { CameraCaptureView(project: project, appState: appState, multiCamMode: mode) }
            else { MultiCamCaptureView(project: project, mode: mode, appState: appState) }
        }
        .sheet(item: $stitching) { MultiCamStitchView(camera: $0, recordings: recordings, project: project) }
        .fullScreenCover(item: $editingVideo) { RecordingEditorView(recording: $0) }
        .fullScreenCover(item: $combiningVideo) { RecordingEditorView(recording: $0, startsInClips: true) }
        .fullScreenCover(item: $editingComposition) { video in
            if let first = video.libraryClips?.first, let source = recordings.first(where: { $0.id == first.recordingID }) {
                RecordingEditorView(recording: source, composition: video)
            }
        }
        .sheet(item: $viewingGeneratedVideo) { CompositionPlayerView(composition: $0, allowsDeletion: true) }
        .sheet(item: $viewingRemoteVideo) { RemoteVideoPlayerView(recording: $0) }
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

    /// One secondary line replaces the old stat tiles: "3 videos · 8 events · vs Rovers · Today".
    /// While a search or filter is active it becomes the result count instead.
    private func summaryLine(total: Int, shown: Int) -> some View {
        let text = isFiltering
            ? "\(shown) of \(total) \(total == 1 ? "video" : "videos")"
            : "\(total) \(total == 1 ? "video" : "videos") · \(events.count) \(events.count == 1 ? "event" : "events") · \(project.subtitle)"
        return HStack(spacing: 6) {
            if project.needsSync {
                Circle().fill(.orange).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("video-result-count")
                .accessibilityLabel(project.needsSync ? "\(text), waiting to sync" : text)
            Spacer(minLength: 0)
        }
    }

    /// A multi-cam session whose two videos are both here but have not been joined yet. The wide
    /// view is a render, so it is offered rather than made automatically.
    private var pendingWideView: Recording? {
        let sessions = Dictionary(grouping: recordings.filter { $0.multiCamSessionID != nil }, by: { $0.multiCamSessionID! })
        for (_, group) in sessions {
            guard group.contains(where: { $0.multiCamRecordingRole == .primary }),
                  !group.contains(where: { $0.multiCamRecordingRole == .stitched }),
                  let camera = group.first(where: { $0.multiCamRecordingRole == .camera && hasLocalVideo($0) }) else { continue }
            return camera
        }
        return nil
    }

    /// Two cameras recorded the same session: offer the joined wide view up front, because the
    /// videos on their own look like two unrelated recordings.
    private func wideViewBanner(camera: Recording) -> some View {
        Button { stitching = camera } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "rectangle.split.2x1").font(.title2).foregroundStyle(Theme.brand).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Join these two cameras").font(.subheadline.weight(.semibold))
                    Text("This session recorded two angles. Make one wide video you can zoom around.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.md)
            .background(Theme.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project-wide-view-banner")
    }

    /// Quick filters for the event kinds this project actually contains; several kinds mean "any of these".
    private var kindFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.sm) {
                if !selectedKinds.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { selectedKinds.removeAll() }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .contentShape(.rect)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.brand)
                        .accessibilityIdentifier("filter-clear")
                }
                ForEach(availableKinds) { kind in
                    let selected = selectedKinds.contains(kind.rawValue)
                    Button {
                        if selected { selectedKinds.remove(kind.rawValue) } else { selectedKinds.insert(kind.rawValue) }
                    } label: {
                        Label(kind.rawValue, systemImage: kind.symbol)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .background(selected ? AnyShapeStyle(kind.tint.opacity(0.18)) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                            .foregroundStyle(selected ? kind.tint : Color.secondary)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filter-kind-\(kind.rawValue)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No videos yet", systemImage: "play.rectangle")
        } description: {
            Text("Record a match or import a video from your library. Tag moments, arrange clips and render your video whenever you’re ready.")
        } actions: {
            Button("Record video", systemImage: "video.fill") { showingCamera = true }
                .buttonStyle(.borderedProminent)
            importVideoButton
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.lg)
        .card()
    }

    private var importVideoButton: some View {
        Button("Import video", systemImage: "square.and.arrow.down") { showingVideoImport = true }
            .disabled(isImportingVideo)
            .accessibilityIdentifier("project-import-video")
    }

    private var noResultsState: some View {
        ContentUnavailableView {
            Label("No matching videos", systemImage: "magnifyingglass")
        } description: {
            Text(selectedKinds.isEmpty
                ? "No video title, note or event matches this search."
                : "No video matches this search and the selected event types.")
        } actions: {
            if !selectedKinds.isEmpty {
                Button("Clear filters") { selectedKinds.removeAll() }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.lg)
        .card()
    }

    // MARK: Search and filtering

    private var allItems: [ProjectVideoItem] {
        (recordings.map(ProjectVideoItem.source) + generatedVideos.map(ProjectVideoItem.generated))
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !selectedKinds.isEmpty
    }

    /// Event kinds present in this project, in the order `EventKind` declares them.
    private var availableKinds: [EventKind] {
        let present = Set(events.map(\.kind))
        return EventKind.allCases.filter { present.contains($0.rawValue) }
    }

    private func filtered(_ items: [ProjectVideoItem]) -> [ProjectVideoItem] {
        guard isFiltering else { return items }
        let matching = ProjectVideoFilter.matchingIDs(searchIndexes(items), query: searchText, kinds: selectedKinds)
        return items.filter { matching.contains($0.id) }
    }

    /// Builds the per-video search index once per filtered render, never per keystroke character.
    private func searchIndexes(_ items: [ProjectVideoItem]) -> [VideoSearchIndex] {
        var eventsByRecording: [UUID: [MatchEvent]] = [:]
        for event in events {
            guard let recordingID = event.recordingID else { continue }
            eventsByRecording[recordingID, default: []].append(event)
        }
        return items.map { item in
            let related: [MatchEvent]
            switch item {
            case .source(let video):
                related = eventsByRecording[video.id] ?? []
            case .generated(let video):
                related = (video.libraryClips ?? []).flatMap { clip in
                    (eventsByRecording[clip.recordingID] ?? []).filter {
                        $0.offsetSeconds >= clip.startSeconds && $0.offsetSeconds <= clip.endSeconds
                    }
                }
            }
            return VideoSearchIndex(
                id: item.id,
                title: title(for: item),
                subtitle: subtitle(for: item),
                eventKinds: related.map(\.kind),
                eventNotes: related.map(\.note)
            )
        }
    }

    private func title(for item: ProjectVideoItem) -> String {
        switch item {
        case .generated(let video): video.name
        case .source(let video): video.name.isEmpty ? friendlyDate(video.recordedAt) : video.name
        }
    }

    private func subtitle(for item: ProjectVideoItem) -> String {
        switch item {
        case .generated(let video): friendlyDate(video.createdAt)
        case .source(let video):
            switch video.multiCamRecordingRole {
            case .camera: "Second camera · \(video.multiCamDeviceName)"
            case .program: "Live cut · 720p"
            case .stitched: "Wide view from two cameras"
            case .primary: "Main camera"
            case nil:
                video.name.isEmpty
                    ? (video.endedReason == "imported" ? "Imported video" : "Recorded with Camelot")
                    : friendlyDate(video.recordedAt)
            }
        }
    }

    // MARK: Video sections

    private func videoSection(items: [ProjectVideoItem], layout: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // Big cards need height: on a short window (phone landscape) the compact rows show more videos.
            if layout.gridColumns > 1 && !layout.isShort {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.md), count: layout.gridColumns), spacing: Theme.Space.md) {
                    ForEach(items) { item in videoCell(item, style: .card) }
                }
            } else {
                LazyVStack(spacing: 0) {
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
                    title: title(for: item),
                    subtitle: subtitle(for: item),
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
                    title: title(for: item),
                    subtitle: subtitle(for: item),
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
            if case .source(let video) = item, video.multiCamRecordingRole == .camera, hasLocalVideo(video) {
                Button("Create wide view", systemImage: "rectangle.split.2x1") { stitching = video }
            }
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
            guard let clips = video.libraryClips, !clips.isEmpty else { return true }
            return !clips.allSatisfy { clip in recordings.contains { $0.id == clip.recordingID && hasLocalVideo($0) } }
        }
    }

    private func open(_ item: ProjectVideoItem) {
        switch item {
        case .generated(let video):
            if let clips = video.libraryClips, !clips.isEmpty,
               clips.allSatisfy({ clip in recordings.contains { $0.id == clip.recordingID && hasLocalVideo($0) } }) {
                editingComposition = video
            } else { viewingGeneratedVideo = video }
        case .source(let video):
            if hasLocalVideo(video) { editingVideo = video } else { viewingRemoteVideo = video }
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
        guard let clips = composition.libraryClips else { return false }
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
        guard let clips = video.libraryClips else { return (0, 0, 0, nil, 0) }
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

private struct RemoteVideoPlayerView: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var events: [MatchEvent]
    @State private var player: AVPlayer?
    @State private var isDownloading = false
    @State private var errorMessage: String?

    init(recording: Recording) {
        self.recording = recording
        let recordingID = recording.id
        _events = Query(filter: #Predicate<MatchEvent> {
            $0.recordingID == recordingID && !$0.pendingDeletion
        }, sort: \MatchEvent.offsetSeconds)
        _player = State(initialValue: recording.remoteMediaURL.map(AVPlayer.init(url:)))
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
                        .background(Color(.systemGroupedBackground))
                    }
                } else {
                    ContentUnavailableView {
                        Label("Video unavailable", systemImage: "icloud.slash")
                    } description: {
                        Text("There is no playable copy on this device or in the cloud.")
                    } actions: {
                        VideoDeletionButton(recording: recording) { dismiss() }
                    }
                }
            }
            .background(.black)
            .onDisappear { player?.pause() }
            .navigationTitle(recording.name.isEmpty ? "Video" : recording.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
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
