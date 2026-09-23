import AppKit
import AVKit
import Observation
import SwiftData
import SwiftUI

private struct EditorEditSnapshot {
    let clips: [CompositionClip]
    let selectedClipID: UUID
    let cropAspect: EditorCropAspect
    let deletedEventIDs: Set<UUID>
}

struct RecordingEditorView: View {
    let recording: Recording
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(AppWindows.self) private var windows
    @Environment(\.modelContext) private var modelContext
    @Query private var projectEvents: [MatchEvent]
    @Query private var projectRecordings: [Recording]
    @State private var playback: EditorPlayback
    @State private var editorTarget: EventEditorTarget?
    @State private var startSeconds: Double
    @State private var endSeconds: Double
    @State private var tool: EditorTool = .clips
    @State private var showingEventList = false
    @State private var showingQuickEvents = false
    @State private var quickEventCounts: [EventKind: Int] = [:]
    @State private var lastQuickEvent: EventKind?
    @State private var quickEventFeedbackToken = UUID()
    @State private var eventSearch = ""
    @State private var eventKind: String?
    @State private var showingDetails = false
    @State private var deletedVideo = false
    @State private var preparingSequence = true
    @State private var sequenceError: String?
    @State private var sequencePosition = 0.0
    @State private var sequenceRetry = 0
    @State private var savedComposition: VideoComposition?
    @State private var videoName: String
    @State private var outputComposition: VideoComposition?
    @State private var clips: [CompositionClip]
    @State private var selectedClipID: UUID
    @State private var showingClipPicker = false
    @State private var timelineZoom: CGFloat = 1
    @State private var cropAspect: EditorCropAspect = .original
    @State private var previewAspectLabel = "…"
    @State private var undoStack: [EditorEditSnapshot] = []
    @State private var redoStack: [EditorEditSnapshot] = []
    // Defer deletion until closing so background sync cannot destroy undoable events.
    @State private var deletedEventIDs = Set<UUID>()
    @State private var insertClipsAtStart = false
    @State private var selectedEventID: UUID?
    @State private var timelineFeedback = EditorTimelineFeedback()
    @State private var notice: String?
    @State private var noticeToken = UUID()
    @State private var preferredWorkspaceHeight = 320.0
    @State private var preferredSidebarWidth = 390.0
    @State private var analysisSession = AnalysisSession()
    @State private var analysisWorkspace: AnalysisWorkspaceRequest?
    @State private var selectedAnnotationID: TimelineEventID?

    init(recording: Recording, startsInClips: Bool = false, initialClips: [CompositionClip]? = nil, composition: VideoComposition? = nil, onClose: (() -> Void)? = nil) {
        self.recording = recording
        self.onClose = onClose
        let projectID = recording.projectID
        _projectEvents = Query(filter: #Predicate<MatchEvent> { $0.projectID == projectID && !$0.pendingDeletion }, sort: \MatchEvent.offsetSeconds)
        _projectRecordings = Query(filter: #Predicate<Recording> { $0.projectID == projectID && !$0.pendingDeletion }, sort: \Recording.segmentIndex)
        let player = AVPlayer(url: recording.fileURL)
        _playback = State(initialValue: EditorPlayback(player: player, duration: recording.duration))
        let clip = CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: max(0.1, recording.duration))
        let initial = (composition?.decodedClips ?? initialClips).flatMap { $0.isEmpty ? nil : $0 } ?? [clip]
        _savedComposition = State(initialValue: composition)
        _videoName = State(initialValue: composition?.name ?? recording.name)
        _cropAspect = State(initialValue: EditorCropAspect(rawValue: composition?.aspectRatio ?? "original") ?? .original)
        _clips = State(initialValue: initial)
        _selectedClipID = State(initialValue: initial[0].id)
        _startSeconds = State(initialValue: initial[0].startSeconds)
        _endSeconds = State(initialValue: initial[0].endSeconds)
    }

    var body: some View {
        NavigationStack {
            AdaptiveLayout { layout in
                ZStack {
                    Color.editorPanel.ignoresSafeArea()
                    // Desktop layout mirrors an editor: program monitor on top,
                    // a full-width workspace/timeline panel underneath.
                    let sizes = EditorPanelSizes(height: layout.size.height, workspace: preferredWorkspaceHeight, minimumWorkspace: minimumWorkspaceHeight)
                    VStack(spacing: 0) {
                        videoCanvas.frame(height: sizes.preview).clipped()
                        EditorPanelDivider(title: "Workspace", value: sizes.workspace, limits: min(minimumWorkspaceHeight, layout.size.height * 0.45)...max(220, layout.size.height - 180)) { preferredWorkspaceHeight = $0 }
                        editorWorkspace(height: sizes.workspace).frame(height: sizes.workspace).clipped()
                    }
                }
            }
            .overlay(alignment: .top) {
                if let notice {
                    Label(notice, systemImage: notice.hasPrefix("Could not") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).padding(12)
                        .background(Theme.signal, in: .rect(cornerRadius: 12)).foregroundStyle(.black)
                        .padding(.top, 8).allowsHitTesting(false)
                }
            }
            .task(id: noticeToken) {
                guard notice != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { notice = nil }
            }
            .navigationTitle(displayTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { closeEditor() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(.rect) }.accessibilityLabel("Back to project")
                }
                ToolbarItem(placement: .principal) {
                    Text(displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .accessibilityIdentifier("editor-video-title")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { playback.pause(); showingDetails = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Video settings").disabled(tool == .trim)
                    saveMenu.disabled(tool == .trim)
                }

            }
            .sheet(item: $editorTarget) { target in EventEditorSheet(recording: activeRecording, target: target, deleteEvent: deleteEvent) }
            .sheet(item: $outputComposition) { CompositionPlayerView(composition: $0) }
            .sheet(isPresented: $showingDetails, onDismiss: { if deletedVideo { close() } }) {
                EditorVideoSettingsSheet(title: displayTitle, aspect: cropAspect,
                    deletionMessage: savedComposition == nil
                        ? "This removes the source video, its events and any saved edits that use it from every synced device. This cannot be undone."
                        : "This removes this video edit and its rendered file from every synced device. Source videos are kept.",
                    save: { title, aspect in try updateVideoTitle(title); setCropAspect(aspect) },
                    delete: {
                        playback.pause()
                        if let savedComposition { try RecordingLibrary.deleteVideo(composition: savedComposition, context: modelContext) }
                        else { try RecordingLibrary.deleteVideo(recording: recording, context: modelContext) }
                        deletedVideo = true
                    })
            }
            .sheet(isPresented: $showingClipPicker) {
                ClipPickerSheet(
                    recordings: projectRecordings,
                    events: visibleProjectEvents,
                    title: "Add a video",
                    choose: chooseSource
                )
            }
            .onDisappear { playback.pause() }
            .task { analysisSession.load(recordingIDs: projectRecordings.map(\.id)) }
            .task(id: sequenceTaskKey) { await prepareSequence() }
            .onChange(of: playback.currentSeconds) {
                if tool == .clips, !preparingSequence {
                    sequencePosition = playback.currentSeconds
                    if selectedEventID == nil, let segment = EditorSequenceSegment.containing(playback.currentSeconds, in: sequenceSegments), segment.id != selectedClipID,
                       let clip = clips.first(where: { $0.id == segment.id }) { selectClipWithoutSeeking(clip) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .background(Color.editorPanel.ignoresSafeArea())
    }

    private var undoAction: (() -> Void)? {
        guard tool == .clips, !undoStack.isEmpty else { return nil }
        return { undoEdit() }
    }
    private var redoAction: (() -> Void)? {
        guard tool == .clips, !redoStack.isEmpty else { return nil }
        return { redoEdit() }
    }
    private var addVideoAction: (() -> Void)? {
        guard tool == .clips else { return nil }
        return { showClipPicker() }
    }

    private var timelineFitAction: (() -> Void)? {
        if tool == .trim { return { fitRange(start: startSeconds, end: endSeconds) } }
        if let event = selectedOccurrence { return { focusEvent(event) } }
        return nil
    }

    private func timeline(height: CGFloat) -> some View {
        EditorTimeline(
            videoURL: activeRecording.fileURL,
            clips: tool == .trim ? [] : sequenceClips,
            selectedClipID: selectedClipID,
            selectClip: { id in if let clip = clips.first(where: { $0.id == id }) { selectClipWithoutSeeking(clip) } },
            reorderClip: reorderClip,
            playback: playback, feedback: timelineFeedback,
            undo: undoAction,
            redo: redoAction,
            addVideo: addVideoAction, addEvent: tool == .clips ? { addEventAtPlayhead() } : nil,
            showsEvents: eventPaletteVisible, addClipAtStart: { showClipPicker(atStart: true) },
            zoom: $timelineZoom, trimStart: $startSeconds, trimEnd: $endSeconds,
            events: tool == .trim ? [] : sequenceEvents.map(\.snapshot) + annotationTimelineEvents,
            selectedEventID: selectedAnnotationID ?? selectedOccurrence?.id,
            showsTrim: tool == .trim, height: height,
            fit: timelineFitAction, fitLabel: tool == .trim ? "Fit clip" : "Fit selected event",
            previewSeek: playback.previewSeek, commitSeek: playback.commitSeek,
            beginTrimEdit: {},
            selectEvent: { id in
                if let id, annotationTimelineEvents.contains(where: { $0.id == id }) {
                    selectedAnnotationID = id; selectedEventID = nil
                    if let clip = clips.first(where: { $0.id == id.clipID }) { selectClipWithoutSeeking(clip) }
                    return
                }
                selectedAnnotationID = nil
                if let id, let clip = clips.first(where: { $0.id == id.clipID }) {
                    selectClipWithoutSeeking(clip); selectedEventID = id.eventID
                } else { selectedEventID = nil }
            },
            updateEventWindow: { id, preRoll, postRoll in
                if updateAnnotationWindow(id, preRoll: preRoll, postRoll: postRoll) { return }
                guard let event = projectEvents.first(where: { $0.id == id.eventID }),
                      let clip = clips.first(where: { $0.id == id.clipID }) else { return }
                let rate = max(0.25, min(4, clip.rate))
                updateEventWindow(event, preRoll: preRoll * rate, postRoll: postRoll * rate)
                showNotice("Event window saved")
            }
        )
        .id(tool == .trim ? "source-\(activeRecording.id)" : "assembled-timeline")
    }

    private var videoCanvas: some View {
        EditorPlayerSurface(player: playback.player, fillsFrame: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 52).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                EditorPreviewControls(playback: playback,
                    isPreparing: tool == .clips && preparingSequence,
                    isEnabled: tool == .trim || (!preparingSequence && sequenceError == nil && playback.errorMessage == nil),
                    play: toggleEditorPlayback)
                    .padding(.horizontal, 8).padding(.bottom, 2)
            }
            .overlay {
                if let error = playback.errorMessage ?? sequenceError {
                    VStack(spacing: 8) {
                        Text("Preview unavailable").font(.headline)
                        Text(error).font(.caption).lineLimit(3).multilineTextAlignment(.center)
                        Button("Reload preview") { sequenceRetry += 1 }
                            .buttonStyle(EditorActionStyle())
                    }.padding(16).background(.black.opacity(0.8), in: .rect(cornerRadius: 12)).padding()
                }
            }

    }

    private var saveMenu: some View {
        Menu {
            Button("Save video", systemImage: "checkmark") { if saveVideo() != nil { showNotice("Video saved") } }
            Button("Render video · \(timecode(outputDuration))", systemImage: "square.and.arrow.up") {
                if let video = saveVideo() { playback.pause(); outputComposition = video }
            }
            if let selectedClip {
                Button("Save selected clip · \(timecode(clipDuration(selectedClip)))", systemImage: "scissors") { saveSelectedClip(selectedClip) }
            }
            Button("Save selected event", systemImage: "flag") {
                if let event = activeEvents.first(where: { $0.id == selectedEventID }) { createEventVideo([event], name: event.kind) }
            }.disabled(selectedEventID == nil)
        } label: { Image(systemName: "square.and.arrow.up") }
        .accessibilityLabel("Save or render video")
    }

    private var minimumWorkspaceHeight: Double {
        (tool == .trim && !showingEventList ? 278 : 206) + (eventPaletteVisible ? 58 : 0)
    }

    private func editorWorkspace(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if tool != .trim {
                Picker("Workspace", selection: Binding(get: { showingEventList }, set: { switchWorkspace($0) })) {
                    Text("Timeline").tag(false)
                    Text("Events (\(sequenceEvents.count))").tag(true).accessibilityIdentifier("editor-events-tab")
                }.pickerStyle(.segmented).accessibilityIdentifier("editor-workspace-switch")
                    .padding(.horizontal, 10).frame(height: 44)
            }
            if eventPaletteVisible {
                EventTagStrip(counts: quickEventCounts, lastTag: lastQuickEvent, isEnabled: !preparingSequence || tool == .trim,
                    accessibilityPrefix: "editor", mark: addQuickEvent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if showingEventList {
                eventsWorkspace(vertical: true).frame(maxHeight: .infinity)
            } else if tool == .clips {
                timeline(height: max(110, height - 44 - (eventPaletteVisible ? 58 : 0) - (selectedOccurrence == nil ? sequenceActionsHeight : 44)))
                    .allowsHitTesting(!preparingSequence && sequenceError == nil)
                if let occurrence = selectedOccurrence {
                    selectedEventActions(occurrence).frame(height: 44)
                } else if selectedAnnotationID != nil { annotationActions.frame(height: 44) }
                else { sequenceActions.frame(height: sequenceActionsHeight) }
            } else {
                HStack {
                    Button("Cancel", action: cancelClipTrim).accessibilityIdentifier("cancel-clip-trim")
                    Spacer()
                    Text("Trim clip").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Save", action: saveClipTrim).accessibilityIdentifier("save-clip-trim")
                        .buttonStyle(EditorActionStyle(prominent: true))
                }.buttonStyle(EditorActionStyle()).padding(.horizontal, 10).frame(height: 44)
                timeline(height: max(110, height - 132))
                HStack(spacing: 4) {
                    clipBoundary("In", value: startSeconds, leading: true)
                    clipBoundary("Out", value: endSeconds, leading: false)
                }.padding(.horizontal, 8).frame(height: 88)
            }
        }.background(Color.editorPanel)
    }

    private var displayTitle: String {
        let name = videoName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled video" : name
    }

    private var eventPaletteVisible: Bool { showingQuickEvents && !showingEventList && tool != .trim && selectedOccurrence == nil }
    private var sequenceActionsHeight: CGFloat { preparingSequence || sequenceError != nil || playback.errorMessage != nil ? 68 : 44 }

    private var sequenceActions: some View {
        VStack(spacing: 0) {
            if preparingSequence || sequenceError != nil || playback.errorMessage != nil {
                HStack(spacing: 6) {
                    if preparingSequence { ProgressView().controlSize(.mini); Text("Preparing preview…") }
                    else {
                        Text("Preview unavailable").foregroundStyle(.orange)
                        Button("Retry") { sequenceRetry += 1 }
                    }
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 24)
            }
            bottomActions.frame(height: 44)
        }
    }

    private var bottomActions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Button { openAnalysis(.video) } label: { Label("Analyse", systemImage: "scope") }
                    .accessibilityIdentifier("open-video-analysis")
                Button { openAnalysis(.freezeFrame) } label: { Label("Freeze & analyse", systemImage: "pause.rectangle") }
                    .accessibilityIdentifier("open-freeze-analysis")
                Divider().frame(height: 24).overlay(.white.opacity(0.12))
                Button { beginClipTrim() } label: { Label("Trim", systemImage: "scissors") }
                    .disabled(selectedClip?.freezeDuration != nil)
                    .accessibilityLabel("Trim selected clip")
                Button { splitSelectedClip(); showNotice("Clip split") } label: { Label("Split", systemImage: "rectangle.split.2x1") }
                    .disabled(!canSplitSelectedClip || preparingSequence).accessibilityLabel("Split selected clip")
                if let selectedClip {
                    if selectedClip.freezeDuration == nil { clipSpeedMenu(selectedClip) }
                    clipCropMenu
                    Button { removeClip(selectedClip); showNotice("Clip removed") } label: { Label("Delete", systemImage: "trash") }
                        .disabled(clips.count == 1).accessibilityLabel("Delete selected clip")
                }
            }.buttonStyle(EditorActionStyle()).padding(.horizontal, 14)
        }
        .scrollIndicators(.hidden)
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 12)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 12)
            }
        }
        .accessibilityIdentifier("editor-actions-scroll")
    }

    private func switchWorkspace(_ list: Bool) {
        if tool == .trim { cancelClipTrim() }
        showingEventList = list
    }

    private func selectedEventActions(_ occurrence: EditorSequenceEvent) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(occurrence.kind) · \(occurrence.clipLabel)").font(.system(size: 13, weight: .semibold)).foregroundStyle(occurrence.event.tint)
                EditorRangeLabel(feedback: timelineFeedback, eventID: occurrence.id, start: occurrence.snapshot.start, end: occurrence.snapshot.end)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { playback.pause(); editorTarget = .existing(occurrence.event) } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Edit selected event")
            Button { deleteEvent(occurrence.event) } label: { Image(systemName: "trash") }
                .accessibilityLabel("Delete selected event")
        }.buttonStyle(EditorActionStyle()).padding(.horizontal, 10)
    }

    private func returnToSequence() {
        playback.pause(); selectedEventID = nil; showingEventList = false; tool = .clips
        timelineZoom = 1; preparingSequence = true
    }

    private func beginClipTrim() {
        guard let clip = selectedClip else { return }
        sequencePosition = tool == .clips ? playback.currentSeconds : sequencePosition
        startSeconds = clip.startSeconds; endSeconds = clip.endSeconds
        tool = .trim; showingEventList = false; selectedEventID = nil
        playback.load(url: activeRecording.fileURL, duration: activeRecording.duration, rate: clip.rate)
        fitRange(start: clip.startSeconds, end: clip.endSeconds)
    }

    // MARK: Tool workspace

    private func clipSpeedMenu(_ clip: CompositionClip) -> some View {
        Menu {
            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                Button { setSelectedClipRate(rate); showNotice("Speed set to \(rate.formatted())×") } label: {
                    if clip.rate == rate { Label("\(rate.formatted())×", systemImage: "checkmark") }
                    else { Text("\(rate.formatted())×") }
                }
            }
        } label: { Label("\(clip.rate.formatted())×", systemImage: "speedometer") }.accessibilityLabel("Clip speed")
    }

    private var clipCropMenu: some View {
        Menu {
            ForEach(EditorCropAspect.allCases) { aspect in
                Button { setCropAspect(aspect); showNotice(aspect.title) } label: {
                    if cropAspect == aspect { Label(aspect.title, systemImage: "checkmark") }
                    else { Text(aspect.title) }
                }
            }
        } label: { Label(cropAspect == .original ? previewAspectLabel : cropAspect.shortTitle, systemImage: "aspectratio") }
        .accessibilityLabel("Video aspect ratio")
        .accessibilityValue(cropAspect == .original ? previewAspectLabel : cropAspect.shortTitle)
    }

    private var sequenceEvents: [EditorSequenceEvent] {
        let byRecording = Dictionary(grouping: visibleProjectEvents, by: \.recordingID)
        let occurrences = sequenceSegments.enumerated().flatMap { index, segment -> [EditorSequenceEvent] in
            guard let clip = clips.first(where: { $0.id == segment.id }) else { return [] }
            return (byRecording[clip.recordingID] ?? []).compactMap { event in
                guard let snapshot = segment.eventSnapshot(TimelineEventSnapshot(event)) else { return nil }
                return EditorSequenceEvent(event: event, clipNumbers: (index + 1)...(index + 1), snapshot: snapshot)
            }
        }
        return EditorSequenceEvent.joiningContinuousWindows(occurrences)
    }

    private var selectedOccurrence: EditorSequenceEvent? {
        guard let selectedEventID else { return nil }
        return sequenceEvents.first { $0.id.eventID == selectedEventID && $0.id.clipID == selectedClipID }
    }

    private func eventsWorkspace(vertical: Bool) -> some View {
        EditorEventBrowser(
            events: sequenceEvents, duration: outputDuration, feedback: timelineFeedback,
            selectedID: Binding(get: { selectedOccurrence?.id }, set: { id in selectedEventID = id?.eventID }),
            search: $eventSearch, kind: $eventKind,
            select: { occurrence in
                if selectedOccurrence?.id == occurrence.id { selectedEventID = nil }
                else { selectOccurrence(occurrence); playback.commitSeek(occurrence.offsetSeconds) }
            },
            edit: { selectOccurrence($0); playback.pause(); editorTarget = .existing($0.event) },
            delete: { deleteEvent($0.event) }
        )
    }

    private func selectOccurrence(_ occurrence: EditorSequenceEvent) {
        guard let clip = clips.first(where: { $0.id == occurrence.id.clipID }) else { return }
        selectClipWithoutSeeking(clip); selectedEventID = occurrence.id.eventID
    }

    private func addEventAtPlayhead() {
        if selectedEventID != nil {
            selectedEventID = nil; showingQuickEvents = true
            return
        }
        showingQuickEvents.toggle()
        // Make room for the palette without covering the timeline's event lanes.
        preferredWorkspaceHeight = max(230, preferredWorkspaceHeight + (showingQuickEvents ? 58 : -58))
    }

    private func addQuickEvent(_ kind: EventKind) {
        let playhead = playback.isPlaying ? playback.player.currentTime().seconds : playback.currentSeconds
        guard playhead.isFinite else { return }
        let source: Recording
        let seconds: Double
        if tool == .clips {
            guard let segment = EditorSequenceSegment.containing(playhead, in: sequenceSegments),
                  let clip = clips.first(where: { $0.id == segment.id }),
                  let recording = projectRecordings.first(where: { $0.id == clip.recordingID }) else { return }
            source = recording; seconds = segment.sourceTime(at: playhead)
        } else { source = activeRecording; seconds = playhead }
        let event = MatchEvent(projectID: source.projectID, recordingID: source.id, kind: kind.rawValue)
        event.offsetSeconds = max(0, min(source.duration, seconds))
        event.preRollSeconds = min(kind.defaultPreRoll, event.offsetSeconds)
        event.postRollSeconds = min(kind.defaultPostRoll, max(0, source.duration - event.offsetSeconds))
        modelContext.insert(event)
        do { try modelContext.save() }
        catch { notice = "The event is pending and will be saved with the next edit." }
        quickEventCounts[kind, default: 0] += 1
        lastQuickEvent = kind
        let token = UUID(); quickEventFeedbackToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            if quickEventFeedbackToken == token { lastQuickEvent = nil }
        }
    }

    private func updateEventWindow(_ event: MatchEvent, preRoll: Double, postRoll: Double) {
        let source = projectRecordings.first { $0.id == event.recordingID }
        let beforeLimit = event.contextRecordingIDs == "[]" ? event.offsetSeconds : max(120, event.preRollSeconds)
        event.preRollSeconds = max(0, min(beforeLimit, preRoll))
        event.postRollSeconds = max(0, min((source?.duration ?? activeRecording.duration) - event.offsetSeconds, postRoll))
        event.needsSync = true; event.mutationID = UUID()
        try? modelContext.save()
    }

    private func focusEvent(_ occurrence: EditorSequenceEvent) {
        selectOccurrence(occurrence); showingEventList = false
        fitRange(start: occurrence.snapshot.start, end: occurrence.snapshot.end)
    }

    private func fitRange(start: Double, end: Double) {
        timelineFeedback.visibleSeconds = nil
        timelineZoom = max(1, CGFloat(playback.duration / max(2, (end - start) * 2.0)))
        playback.commitSeek((start + end) / 2)
    }

    private func deleteEvent(_ event: MatchEvent) {
        playback.pause()
        if selectedEventID == event.id { selectedEventID = nil }
        guard !deletedEventIDs.contains(event.id) else { return }
        recordEditHistory()
        deletedEventIDs.insert(event.id)
        showNotice("Event deleted · Undo to restore")
    }

    private func clipBoundary(_ title: String, value: Double, leading: Bool) -> some View {
        VStack(spacing: 2) {
            Button { playback.commitSeek(value) } label: {
                HStack {
                    Text(title).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(timelineTimecode(timelineFeedback.draft.flatMap { $0.eventID == nil ? (leading ? $0.start : $0.end) : nil } ?? value, includesTenths: true)).monospacedDigit()
                        .accessibilityIdentifier(leading ? "clip-trim-in" : "clip-trim-out")
                }.font(.system(size: 13, weight: .medium)).frame(minHeight: 34).contentShape(.rect)
            }.accessibilityLabel("Jump to clip \(leading ? "start" : "end")")
            HStack(spacing: 0) {
                Button { nudgeClipBoundary(leading: leading, delta: -0.1) } label: { Image(systemName: "minus").frame(minWidth: 44, maxWidth: .infinity, minHeight: 48).contentShape(.rect) }
                    .accessibilityLabel("Move clip \(leading ? "start" : "end") earlier")
                Button {
                    if leading { setTrimStartToPlayhead() } else { setTrimEndToPlayhead() }
                } label: {
                    Text("Set").font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 48).contentShape(.rect)
                }
                    .accessibilityLabel(leading ? "Set In here" : "Set Out here")
                Button { nudgeClipBoundary(leading: leading, delta: 0.1) } label: { Image(systemName: "plus").frame(minWidth: 44, maxWidth: .infinity, minHeight: 48).contentShape(.rect) }
                    .accessibilityLabel("Move clip \(leading ? "start" : "end") later")
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 4).background(.white.opacity(0.06), in: .rect(cornerRadius: 8))
    }

    private func nudgeClipBoundary(leading: Bool, delta: Double) {
        let value = (leading ? startSeconds : endSeconds) + delta
        let range = TimelineGeometry.trim(value, start: startSeconds, end: endSeconds, duration: playback.duration, leading: leading)
        guard range.0 != startSeconds || range.1 != endSeconds else { return }
        startSeconds = range.0; endSeconds = range.1
        playback.commitSeek(leading ? startSeconds : endSeconds)
    }

    private func updateVideoTitle(_ value: String) throws {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let savedComposition {
            savedComposition.name = name; savedComposition.needsSync = true; savedComposition.mutationID = UUID()
        } else {
            recording.name = name; recording.needsSync = true; recording.mutationID = UUID()
        }
        do { try modelContext.save(); videoName = name }
        catch { modelContext.rollback(); throw error }
    }

    private var activeRecording: Recording {
        projectRecordings.first(where: { $0.id == selectedClip?.recordingID }) ?? recording
    }

    private var visibleProjectEvents: [MatchEvent] { projectEvents.filter { !deletedEventIDs.contains($0.id) } }

    private var activeEvents: [MatchEvent] {
        visibleProjectEvents.filter { $0.recordingID == activeRecording.id }
    }

    private var selectedClip: CompositionClip? { clips.first { $0.id == selectedClipID } }
    private var canSplitSelectedClip: Bool {
        guard let selectedClip else { return false }
        return selectedClip.freezeDuration == nil && selectedSourceTime > selectedClip.startSeconds + 0.1
            && selectedSourceTime < selectedClip.endSeconds - 0.1
    }
    private var outputDuration: Double { clips.reduce(0) { $0 + clipDuration($1) } }

    private func clipDuration(_ clip: CompositionClip) -> Double {
        clip.playbackDuration
    }

    private var sequenceSegments: [EditorSequenceSegment] {
        var cursor = 0.0
        return clips.map { clip in
            let segment = EditorSequenceSegment(id: clip.id, sourceStart: clip.startSeconds, sourceEnd: clip.endSeconds, rate: clip.rate, start: cursor, freezeDuration: clip.freezeDuration)
            cursor = segment.end; return segment
        }
    }
    private var sequenceClips: [EditorSequenceClip] {
        sequenceSegments.enumerated().compactMap { index, segment in
            guard let clip = clips.first(where: { $0.id == segment.id }),
                  let source = projectRecordings.first(where: { $0.id == clip.recordingID }) else { return nil }
            return EditorSequenceClip(segment: segment, url: source.fileURL, number: index + 1)
        }
    }
    /// The recording and its time currently shown by the player, across both tools.
    private var currentSource: (recordingID: UUID, seconds: Double)? {
        guard tool == .clips else { return (recording.id, playback.currentSeconds) }
        guard !preparingSequence, let segment = EditorSequenceSegment.containing(playback.currentSeconds, in: sequenceSegments),
              let clip = clips.first(where: { $0.id == segment.id }) else { return nil }
        return (clip.recordingID, segment.sourceTime(at: playback.currentSeconds))
    }
    /// Window the Analyse button works on: the trim selection, or the clip under the playhead.
    private var analysisRange: (ClosedRange<Double>, UUID)? {
        guard tool == .clips else { return (min(startSeconds, endSeconds)...max(startSeconds, endSeconds), recording.id) }
        guard let source = currentSource, let clip = clips.first(where: { $0.recordingID == source.recordingID && $0.startSeconds <= source.seconds + 0.01 && $0.endSeconds >= source.seconds - 0.01 })
            ?? clips.first(where: { $0.id == selectedClipID }) else { return nil }
        return (clip.startSeconds...max(clip.startSeconds + 0.1, clip.endSeconds), clip.recordingID)
    }
    private func analyzeCurrentRange() {
        guard let (range, id) = analysisRange, let source = projectRecordings.first(where: { $0.id == id }) else { return }
        playback.pause()
        analysisSession.analyze(recording: source, range: range)
    }
    private var analysisSource: (recording: Recording, seconds: Double, range: ClosedRange<Double>)? {
        guard let currentSource,
              let source = projectRecordings.first(where: { $0.id == currentSource.recordingID }),
              let (range, _) = analysisRange else { return nil }
        return (source, currentSource.seconds, range)
    }
    private func openAnalysis(_ mode: AnalysisWorkspaceMode) {
        guard let source = analysisSource,
              let segment = EditorSequenceSegment.containing(playback.currentSeconds, in: sequenceSegments),
              let current = clips.first(where: { $0.id == segment.id }) else { return }
        playback.pause()
        if mode == .freezeFrame, current.freezeDuration == nil {
            let seconds = min(source.seconds, max(current.startSeconds, current.endSeconds - 1 / 60))
            var frozen = CompositionClip(recordingID: current.recordingID, startSeconds: seconds, endSeconds: min(source.recording.duration, seconds + 1 / 60))
            frozen.freezeDuration = 5
            frozen.groundCalibration = current.groundCalibration?.frozen(at: seconds)
            let request = AnalysisWorkspaceRequest(mode: mode, clip: frozen, recording: source.recording, seconds: seconds, insertsFreeze: true, parentClipID: current.id)
            analysisWorkspace = request
            openAnalysis(request)
        } else {
            let request = AnalysisWorkspaceRequest(mode: current.freezeDuration == nil ? .video : .freezeFrame, clip: current, recording: source.recording, seconds: source.seconds)
            analysisWorkspace = request
            openAnalysis(request)
        }
    }

    /// Present the analysis workspace as its own desktop window.
    private func openAnalysis(_ request: AnalysisWorkspaceRequest) {
        windows.analysis = AnalysisWindowLaunch(request: request, session: analysisSession,
            save: { edited in try saveAnalysis(edited, request: request) })
        openWindow(id: AppWindowID.analysis)
    }

    private func saveAnalysis(_ edited: CompositionClip, request: AnalysisWorkspaceRequest) throws {
        let previous = clips
        recordEditHistory()
        if request.insertsFreeze {
            guard let index = clips.firstIndex(where: { $0.id == request.parentClipID }) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let original = clips[index]
            var replacement: [CompositionClip] = []
            if request.seconds > original.startSeconds + 0.01 {
                var before = original; before.id = UUID(); before.endSeconds = request.seconds
                replacement.append(before)
            }
            replacement.append(edited)
            if request.seconds < original.endSeconds - 0.01 {
                var after = original; after.id = UUID(); after.startSeconds = request.seconds
                replacement.append(after)
            }
            clips.replaceSubrange(index...index, with: replacement)
        } else if let index = clips.firstIndex(where: { $0.id == edited.id }) { clips[index] = edited }
        selectedClipID = edited.id; selectedAnnotationID = nil
        guard saveVideo() != nil else { clips = previous; throw CocoaError(.fileWriteUnknown) }
        showNotice(request.insertsFreeze ? "Freeze frame added to timeline" : "Analysis layers saved to timeline")
    }

    private var annotationTimelineEvents: [TimelineEventSnapshot] {
        sequenceSegments.flatMap { segment -> [TimelineEventSnapshot] in
            guard let clip = clips.first(where: { $0.id == segment.id }) else { return [] }
            return clip.annotations.compactMap { mark in
                // Show the authored range, including portions that may need retracking.
                let start = max(clip.startSeconds, mark.start), end = min(clip.annotationEnd, mark.end)
                guard end > start else { return nil }
                let midpoint = (start + end) / 2
                return TimelineEventSnapshot(id: TimelineEventID(eventID: mark.id, clipID: clip.id), offset: segment.start + (midpoint - clip.startSeconds) / clip.annotationRate, preRoll: (midpoint - start) / clip.annotationRate, postRoll: (end - midpoint) / clip.annotationRate, kind: "✎ \(mark.title)", colorHex: "BDEB35", lowerBound: segment.start, upperBound: segment.end, isDrawing: true, isLocked: mark.isLocked == true)
            }
        }
    }

    private func updateAnnotationWindow(_ id: TimelineEventID, preRoll: Double, postRoll: Double) -> Bool {
        guard let clipIndex = clips.firstIndex(where: { $0.id == id.clipID }),
              let index = clips[clipIndex].annotations.firstIndex(where: { $0.id == id.eventID }),
              let snapshot = annotationTimelineEvents.first(where: { $0.id == id }),
              let segment = sequenceSegments.first(where: { $0.id == id.clipID }) else { return false }
        let clip = clips[clipIndex]
        guard clip.annotations[index].isLocked != true else { return true }
        recordEditHistory()
        clips[clipIndex].annotations[index].start = max(clip.startSeconds, clip.startSeconds + (max(snapshot.lowerBound, snapshot.offset - preRoll) - segment.start) * clip.annotationRate)
        clips[clipIndex].annotations[index].end = min(clip.annotationEnd, clip.startSeconds + (min(snapshot.upperBound, snapshot.offset + postRoll) - segment.start) * clip.annotationRate)
        return true
    }

    private var annotationActions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button("Edit layer", systemImage: "pencil") {
                    guard let id = selectedAnnotationID, let clip = clips.first(where: { $0.id == id.clipID }),
                          let recording = projectRecordings.first(where: { $0.id == clip.recordingID }),
                          let mark = clip.annotations.first(where: { $0.id == id.eventID }) else { return }
                    playback.pause()
                    let request = AnalysisWorkspaceRequest(mode: clip.freezeDuration == nil ? .video : .freezeFrame, clip: clip, recording: recording, seconds: clip.freezeDuration == nil ? max(clip.startSeconds, mark.start) : clip.startSeconds, selectedAnnotation: mark.id)
                    analysisWorkspace = request
                    openAnalysis(request)
                }.accessibilityIdentifier("edit-analysis-layer")
                Button("Place here", systemImage: "arrow.down.to.line") {
                    guard let id = selectedAnnotationID, let clipIndex = clips.firstIndex(where: { $0.id == id.clipID }),
                          let index = clips[clipIndex].annotations.firstIndex(where: { $0.id == id.eventID }),
                          let segment = sequenceSegments.first(where: { $0.id == id.clipID }) else { return }
                    let clip = clips[clipIndex], mark = clip.annotations[index]
                    guard mark.isLocked != true else { return }
                    recordEditHistory()
                    let newStart = clip.startSeconds + (playback.currentSeconds - segment.start) * clip.annotationRate
                    clips[clipIndex].annotations[index] = mark.applying(.move(newStart - mark.start), within: clip.startSeconds...clip.annotationEnd)
                }
                Button("Delete layer", systemImage: "trash", role: .destructive) {
                    guard let id = selectedAnnotationID, let index = clips.firstIndex(where: { $0.id == id.clipID }),
                          clips[index].annotations.first(where: { $0.id == id.eventID })?.isLocked != true else { return }
                    recordEditHistory(); clips[index].annotations.removeAll { $0.id == id.eventID }; selectedAnnotationID = nil
                }
                Button("Done") { selectedAnnotationID = nil }
            }.buttonStyle(EditorActionStyle()).padding(.horizontal, 10)
        }.scrollIndicators(.hidden)
    }
    private var selectedSourceTime: Double {
        tool == .clips ? sequenceSegments.first(where: { $0.id == selectedClipID })?.sourceTime(at: playback.currentSeconds) ?? startSeconds : playback.currentSeconds
    }
    private var sequenceTaskKey: EditorSequenceRequest {
        EditorSequenceRequest(clips: clips, aspectRatio: cropAspect.rawValue, isActive: tool == .clips, retry: sequenceRetry)
    }

    private func prepareSequence() async {
        let request = sequenceTaskKey
        guard request.isActive else { return }
        playback.pause(); preparingSequence = true; sequenceError = nil
        do {
            guard clips.allSatisfy({ clip in projectRecordings.contains { $0.id == clip.recordingID && FileManager.default.fileExists(atPath: $0.fileURL.path()) } }) else { throw CocoaError(.fileReadNoSuchFile) }
            let asset = try await CompositionRenderer.makeAsset(clips: clips, recordings: projectRecordings)
            let videoComposition = try await EditorSequencePreview.makeVideoComposition(asset: asset, clips: clips, recordings: projectRecordings, aspectRatio: cropAspect.rawValue)
            try Task.checkCancellation()
            guard request == sequenceTaskKey else { return }
            previewAspectLabel = videoAspectRatioLabel(videoComposition.renderSize)
            let item = AVPlayerItem(asset: asset); item.videoComposition = videoComposition
            playback.load(item: item, duration: outputDuration)
            playback.commitSeek(min(outputDuration, max(0, sequencePosition)))
            preparingSequence = false
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            sequenceError = error.localizedDescription; preparingSequence = false
        }
    }

    private func selectClipWithoutSeeking(_ clip: CompositionClip) {
        selectedEventID = nil; selectedClipID = clip.id
        startSeconds = clip.startSeconds; endSeconds = clip.endSeconds
    }
    private func selectClip(_ clip: CompositionClip) {
        selectClipWithoutSeeking(clip)
        if tool == .clips {
            let seconds = sequenceSegments.first { $0.id == clip.id }?.start ?? 0
            sequencePosition = seconds; playback.commitSeek(seconds)
        } else {
            playback.load(url: activeRecording.fileURL, duration: activeRecording.duration, rate: clip.rate)
            playback.commitSeek(clip.startSeconds)
        }
    }

    private func toggleEditorPlayback() {
        if playback.isPlaying { playback.pause(); return }
        if tool == .clips {
            guard !preparingSequence, sequenceError == nil else { return }
            if let occurrence = selectedOccurrence {
                let range = occurrence.snapshot
                let start = playback.currentSeconds >= range.start && playback.currentSeconds < range.end - 0.05 ? playback.currentSeconds : range.start
                playback.playRange(from: start, to: range.end)
            } else {
                playback.playRange(from: playback.currentSeconds >= outputDuration - 0.05 ? 0 : playback.currentSeconds, to: outputDuration)
            }
            return
        }
        let range = (startSeconds, endSeconds)
        let start = playback.currentSeconds >= range.0 && playback.currentSeconds < range.1 - 0.05 ? playback.currentSeconds : range.0
        playback.playRange(from: start, to: range.1)
    }

    private func showNotice(_ message: String) {
        notice = message; noticeToken = UUID()
    }

    @discardableResult
    private func saveVideo() -> VideoComposition? {
        guard !clips.isEmpty else { return nil }
        let name = videoName.trimmingCharacters(in: .whitespacesAndNewlines)
        let video = savedComposition ?? VideoComposition(projectID: recording.projectID,
            name: name.isEmpty ? "Video edit" : name, kind: "multi-clip", clips: clips, aspectRatio: cropAspect.rawValue)
        do {
            if savedComposition == nil { modelContext.insert(video) }
            try video.saveEdit(clips: clips, aspectRatio: cropAspect.rawValue,
                name: name.isEmpty ? "Video edit" : name, context: modelContext)
            savedComposition = video
            return video
        } catch { showNotice("Could not save video"); return nil }
    }

    private func closeEditor() {
        if tool == .trim { cancelClipTrim(); return }
        let original = [CompositionClip(id: clips.first?.id ?? UUID(), recordingID: recording.id,
            startSeconds: 0, endSeconds: max(0.1, recording.duration))]
        let hasEdits = savedComposition != nil || clips != original || cropAspect != .original
        if hasEdits, saveVideo() == nil { return }
        if !hasEdits { saveVideoName() }
        do {
            for event in projectEvents where deletedEventIDs.contains(event.id) {
                event.pendingDeletion = true; event.needsSync = true; event.mutationID = UUID()
            }
            try modelContext.save()
        } catch { modelContext.rollback(); showNotice("Could not save event deletions"); return }
        close()
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func reorderClip(_ id: UUID, _ destination: Int) {
        guard let source = clips.firstIndex(where: { $0.id == id }), source != destination else { return }
        recordEditHistory(); playback.pause()
        let moved = clips.remove(at: source)
        clips.insert(moved, at: min(clips.count, max(0, destination)))
        selectClipWithoutSeeking(moved)
        sequencePosition = sequenceSegments.first(where: { $0.id == id })?.start ?? 0
        showNotice("Clip moved")
    }

    private func saveSelectedClip(_ clip: CompositionClip) {
        let composition = VideoComposition(projectID: recording.projectID, name: "Clip \((clips.firstIndex { $0.id == clip.id } ?? 0) + 1)", kind: "trim", clips: [clip], aspectRatio: cropAspect.rawValue)
        modelContext.insert(composition)
        do { try modelContext.save(); playback.pause(); outputComposition = composition }
        catch { showNotice("Could not save clip") }
    }

    private func saveClipTrim() {
        guard let index = clips.firstIndex(where: { $0.id == selectedClipID }) else { return }
        let sourceTime = playback.currentSeconds
        if clips[index].startSeconds != startSeconds || clips[index].endSeconds != endSeconds {
            recordEditHistory()
            clips[index].startSeconds = startSeconds
            clips[index].endSeconds = endSeconds
        }
        sequencePosition = sequenceSegments.first(where: { $0.id == selectedClipID })?.outputTime(at: sourceTime) ?? 0
        returnToSequence()
    }

    private func cancelClipTrim() {
        if let clip = selectedClip { startSeconds = clip.startSeconds; endSeconds = clip.endSeconds }
        returnToSequence()
    }

    private func addRecording(_ recording: Recording) {
        recordEditHistory()
        let clip = CompositionClip(recordingID: recording.id, startSeconds: 0, endSeconds: max(0.1, recording.duration))
        clips.insert(clip, at: insertClipsAtStart ? 0 : clips.count); showingClipPicker = false
        if tool == .trim { tool = .clips; preparingSequence = true }
        selectClip(clip)
    }

    private func showClipPicker(atStart: Bool = false) {
        insertClipsAtStart = atStart
        playback.pause(); showingClipPicker = true
    }

    private func chooseSource(_ choice: ClipSourceChoice) {
        switch choice {
        case .full(let source): addRecording(source)
        case .trim(let source):
            addRecording(source); beginClipTrim()
        case .event(let event):
            let additions = clipsForEvents([event])
            guard let first = additions.first else { showNotice("Could not add event"); return }
            recordEditHistory()
            clips.insert(contentsOf: additions, at: insertClipsAtStart ? 0 : clips.count)
            showingClipPicker = false
            if tool == .trim { tool = .clips; preparingSequence = true }
            selectClip(first)
            showNotice("Event added to edit")
        }
    }

    private func removeClip(_ clip: CompositionClip) {
        guard clips.count > 1, let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        recordEditHistory()
        clips.remove(at: index)
        if selectedClipID == clip.id { selectClip(clips[min(index, clips.count - 1)]) }
    }

    private func splitSelectedClip() {
        guard let index = clips.firstIndex(where: { $0.id == selectedClipID }) else { return }
        let source = clips[index]
        let split = selectedSourceTime
        guard split > source.startSeconds + 0.1, split < source.endSeconds - 0.1 else { return }
        recordEditHistory()
        var leading = source; leading.id = UUID(); leading.endSeconds = split
        var trailing = source; trailing.id = UUID(); trailing.startSeconds = split
        clips.replaceSubrange(index...index, with: [leading, trailing])
        selectedClipID = trailing.id
        startSeconds = trailing.startSeconds
        endSeconds = trailing.endSeconds
        if tool != .clips { playback.commitSeek(split) }
    }

    private func setSelectedClipRate(_ rate: Double) {
        guard let index = clips.firstIndex(where: { $0.id == selectedClipID }) else { return }
        let clamped = max(0.25, min(4, rate))
        guard abs(clips[index].rate - clamped) > 0.001 else { return }
        recordEditHistory()
        clips[index].rate = clamped
        if tool != .clips {
            playback.playbackRate = Float(clamped)
            if playback.isPlaying { playback.player.rate = Float(clamped) }
        }
    }

    private func setCropAspect(_ aspect: EditorCropAspect) {
        guard cropAspect != aspect else { return }
        recordEditHistory()
        cropAspect = aspect
    }

    private func setTrimStartToPlayhead() {
        let value = min(playback.currentSeconds, endSeconds - 0.1)
        guard abs(value - startSeconds) > 0.001 else { return }
        startSeconds = value
    }

    private func setTrimEndToPlayhead() {
        let value = max(playback.currentSeconds, startSeconds + 0.1)
        guard abs(value - endSeconds) > 0.001 else { return }
        endSeconds = value
    }

    private func saveVideoName() {
        if let savedComposition {
            let name = videoName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != savedComposition.name else { return }
            savedComposition.name = name; savedComposition.needsSync = true; savedComposition.mutationID = UUID()
        } else {
            let name = videoName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard recording.name != name else { return }
            recording.name = name; recording.needsSync = true; recording.mutationID = UUID()
        }
        try? modelContext.save()
    }

    private func recordEditHistory() {
        undoStack.append(EditorEditSnapshot(clips: clips, selectedClipID: selectedClipID, cropAspect: cropAspect, deletedEventIDs: deletedEventIDs))
        if undoStack.count > 20 { undoStack.removeFirst(undoStack.count - 20) }
        redoStack.removeAll(keepingCapacity: true)
    }

    private func undoEdit() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(EditorEditSnapshot(clips: clips, selectedClipID: selectedClipID, cropAspect: cropAspect, deletedEventIDs: deletedEventIDs))
        restore(snapshot)
    }

    private func redoEdit() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(EditorEditSnapshot(clips: clips, selectedClipID: selectedClipID, cropAspect: cropAspect, deletedEventIDs: deletedEventIDs))
        restore(snapshot)
    }

    private func restore(_ snapshot: EditorEditSnapshot) {
        let clipChanged = clips != snapshot.clips || cropAspect != snapshot.cropAspect || selectedClipID != snapshot.selectedClipID
        clips = snapshot.clips; cropAspect = snapshot.cropAspect
        deletedEventIDs = snapshot.deletedEventIDs; selectedEventID = nil
        if clipChanged {
            let clip = clips.first(where: { $0.id == snapshot.selectedClipID }) ?? clips[0]
            selectClip(clip)
        }
    }

    private func clipsForEvents(_ events: [MatchEvent]) -> [CompositionClip] {
        let durations = Dictionary(uniqueKeysWithValues: projectRecordings.map { ($0.id, $0.duration) })
        let eventClips = events.flatMap { event -> [CompositionClip] in
            guard let recordingID = event.recordingID, let duration = durations[recordingID] else { return [] }
            let contextIDs = event.contextRecordingIDs.data(using: .utf8).flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? []
            let context = contextIDs.compactMap { id -> CompositionClip? in
                guard let contextDuration = durations[id] else { return nil }
                return CompositionClip(recordingID: id, startSeconds: max(0, contextDuration - event.preRollSeconds), endSeconds: contextDuration)
            }
            let start = context.isEmpty ? max(0, event.offsetSeconds - event.preRollSeconds) : 0
            return context + [CompositionClip(recordingID: recordingID, startSeconds: start, endSeconds: min(duration, event.offsetSeconds + event.postRollSeconds))]
        }
        return mergeOverlapping(eventClips)
    }

    private func createEventVideo(_ events: [MatchEvent], name: String) {
        let mergedClips = clipsForEvents(events)
        guard !mergedClips.isEmpty else { return }
        let video = VideoComposition(projectID: recording.projectID, name: name, kind: "event-summary", clips: mergedClips, aspectRatio: cropAspect.rawValue)
        modelContext.insert(video)
        do { try modelContext.save(); playback.pause(); outputComposition = video }
        catch { showNotice("Could not save event video") }
    }

    private func mergeOverlapping(_ source: [CompositionClip]) -> [CompositionClip] {
        var result: [CompositionClip] = []
        for clip in source {
            if let last = result.last, last.recordingID == clip.recordingID, clip.startSeconds <= last.endSeconds {
                result[result.count - 1].endSeconds = max(last.endSeconds, clip.endSeconds)
            } else {
                result.append(clip)
            }
        }
        return result
    }
}

private struct EditorVideoSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var aspect: EditorCropAspect
    @State private var confirmingDeletion = false
    @State private var errorMessage: String?
    let deletionMessage: String
    let save: (String, EditorCropAspect) throws -> Void
    let delete: () throws -> Void

    init(title: String, aspect: EditorCropAspect, deletionMessage: String, save: @escaping (String, EditorCropAspect) throws -> Void, delete: @escaping () throws -> Void) {
        _title = State(initialValue: title)
        _aspect = State(initialValue: aspect)
        self.deletionMessage = deletionMessage; self.save = save; self.delete = delete
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Video title").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        TextField("Video title", text: $title)
                            .font(.body).submitLabel(.done)
                            .padding(.horizontal, 14).frame(minHeight: 48)
                            .background(Theme.inkPanel, in: .rect(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.inkStroke))
                            .accessibilityIdentifier("video-settings-title")
                            .onSubmit { saveSettings() }
                    }
                    HStack {
                        Text("Aspect ratio").font(.subheadline.weight(.medium))
                        Spacer(minLength: 8)
                        Picker("Aspect ratio", selection: $aspect) {
                            ForEach(EditorCropAspect.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu).labelsHidden()
                            .accessibilityIdentifier("video-settings-aspect")
                    }.padding(.horizontal, 14).frame(minHeight: 48)
                        .background(Theme.inkPanel, in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.inkStroke))
                    Button(role: .destructive) { confirmingDeletion = true } label: {
                        Label("Delete video", systemImage: "trash")
                            .font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(.horizontal, 14)
                            .background(Color.red.opacity(0.09), in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).foregroundStyle(.red)
                    if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.orange) }
                }.padding(20)
            }
            .background(Theme.ink.ignoresSafeArea())
            .navigationTitle("Video settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close video settings")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: saveSettings).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Delete this video?", isPresented: $confirmingDeletion) {
                Button("Delete video", role: .destructive) {
                    do { try delete(); dismiss() } catch { errorMessage = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text(deletionMessage) }
        }
        .preferredColorScheme(.dark).tint(.white)
        .presentationDetents([.height(390), .large]).presentationDragIndicator(.visible)
        .frame(width: 460, height: 520)
        .formStyle(.grouped)
    }

    private func saveSettings() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try save(title, aspect); dismiss() } catch { errorMessage = error.localizedDescription }
    }
}

private struct EditorPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let fillsFrame: Bool
    func makeNSView(context: Context) -> EditorPlayerView {
        let view = EditorPlayerView()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ view: EditorPlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
    }
}

private final class EditorPlayerView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private enum EditorTool: String { case clips, trim }

private enum EditorCropAspect: String, CaseIterable, Identifiable {
    case original, landscape, square, portrait
    var id: Self { self }
    var title: String {
        switch self { case .original: "Original"; case .landscape: "Landscape 16:9"; case .square: "Square 1:1"; case .portrait: "Portrait 9:16" }
    }
    var shortTitle: String {
        switch self { case .original: "Original"; case .landscape: "16:9"; case .square: "1:1"; case .portrait: "9:16" }
    }
    var ratio: CGFloat? {
        switch self { case .original: nil; case .landscape: 16 / 9; case .square: 1; case .portrait: 9 / 16 }
    }
}

private enum ClipSourceChoice {
    case full(Recording)
    case trim(Recording)
    case event(MatchEvent)
}

private struct ClipPickerSheet: View {
    let recordings: [Recording]
    let events: [MatchEvent]
    let title: String
    let choose: (ClipSourceChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(recordings) { recording in
                NavigationLink {
                    ClipSourcePicker(recording: recording, events: events.filter { $0.recordingID == recording.id }, choose: choose)
                } label: {
                    HStack(spacing: 12) {
                        VideoThumbnailView(url: recording.fileURL, seconds: min(1, recording.duration / 2), icon: "play.fill", tint: Theme.signal)
                            .frame(width: 72, height: 46)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recording.name.isEmpty ? recording.recordedAt.formatted(date: .abbreviated, time: .shortened) : recording.name)
                            Text(timecode(recording.duration)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityIdentifier("clip-source-\(recording.id)")
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}

private struct ClipSourcePicker: View {
    let recording: Recording
    let events: [MatchEvent]
    let choose: (ClipSourceChoice) -> Void
    @State private var search = ""
    private var filtered: [MatchEvent] {
        events.filter { search.isEmpty || $0.kind.localizedStandardContains(search) || $0.note.localizedStandardContains(search) }
    }
    var body: some View {
        List {
            Section {
                Button { choose(.full(recording)) } label: {
                    Label("Full video · \(timecode(recording.duration))", systemImage: "film")
                }
                Button { choose(.trim(recording)) } label: { Label("Choose a clip range", systemImage: "scissors") }
            }
            if !events.isEmpty {
                Section("Events · \(filtered.count)") {
                    ForEach(filtered) { event in
                        Button { choose(.event(event)) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: EventKind.symbol(for: event.kind)).foregroundStyle(event.tint).frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.kind).font(.subheadline.weight(.medium))
                                    if !event.note.isEmpty { Text(event.note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    Text("\(timelineTimecode(max(0, event.offsetSeconds - event.preRollSeconds), includesTenths: true)) – \(timelineTimecode(min(recording.duration, event.offsetSeconds + event.postRollSeconds), includesTenths: true))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus")
                            }.padding(.vertical, 3)
                        }.foregroundStyle(.primary)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search events")
        .frame(minWidth: 480, minHeight: 520)
    }
}

@MainActor @Observable
final class EditorPlayback {
    let player: AVPlayer
    var currentSeconds: Double = 0
    var duration: Double
    var isPlaying = false
    var playbackRate: Float = 1
    private var observer: Any?
    private var boundaryObserver: Any?
    private var lastPreviewAt = 0.0
    private var lastPreviewSeconds = -1.0
    private var seekGeneration = 0
    private var isSeeking = false
    private var pendingSeek: (seconds: Double, tolerance: Double)?
    private var resumeAfterSeek = false
    var errorMessage: String?
    @ObservationIgnored private var transportObserver: NSKeyValueObservation?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    init(player: AVPlayer, duration: Double, observationFrameRate: Double = 15) {
        self.player = player; self.duration = duration
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / max(15, min(60, observationFrameRate)), preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = time.seconds
                if !self.isSeeking, value.isFinite, abs(value - self.currentSeconds) > 0.01 { self.currentSeconds = value }
                guard !self.isSeeking else { return }
                let playing = self.player.timeControlStatus == .playing
                if playing != self.isPlaying { self.isPlaying = playing }
            }
        }
            // The periodic time observer may stop before delivering the final paused state.
        // Observe transport changes as well, including AVPlayer stopping at the asset end.
        transportObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.isSeeking else { return }
                if self.player.timeControlStatus == .playing { self.isPlaying = true }
                else if self.player.timeControlStatus == .paused, !self.resumeAfterSeek {
                    self.isPlaying = false
                    let seconds = self.player.currentTime().seconds
                    if seconds.isFinite { self.currentSeconds = min(self.duration, max(0, seconds)) }
                }
            }
        }
    }

    func load(url: URL, duration: Double, rate: Double = 1) {
        load(item: AVPlayerItem(url: url), duration: duration, rate: rate)
    }
    func load(item: AVPlayerItem, duration: Double, rate: Double = 1) {
        seekGeneration += 1; isSeeking = false; pendingSeek = nil; errorMessage = nil
        statusObserver = nil
        pause(); player.replaceCurrentItem(with: item); self.duration = duration
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.errorMessage = item.error?.localizedDescription ?? "Preview could not be decoded."
                    self.isSeeking = false; self.pendingSeek = nil; self.pause()
                }
            }
        }
        playbackRate = Float(max(0.25, min(4, rate))); currentSeconds = 0
    }
    func toggle() { if isPlaying { pause() } else { player.playImmediately(atRate: playbackRate); isPlaying = true } }
    func pause() { resumeAfterSeek = false; player.pause(); isPlaying = false; clearBoundaryObserver() }
    func play(from seconds: Double) { commitSeek(seconds); resumeAfterSeek = true; isPlaying = true }
    func playRange(from start: Double, to end: Double) {
        commitSeek(start)
        guard end > start else { return }
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.pause() }
        }
        resumeAfterSeek = true; isPlaying = true
    }
    func previewSeek(_ seconds: Double) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastPreviewAt >= 1.0 / 24.0, abs(seconds - lastPreviewSeconds) >= 0.03 else { return }
        lastPreviewAt = now; lastPreviewSeconds = seconds; pause(); currentSeconds = max(0, min(duration, seconds))
        seek(to: seconds, tolerance: 0.08)
    }
    func commitSeek(_ seconds: Double) {
        pause(); currentSeconds = max(0, min(duration, seconds)); lastPreviewSeconds = seconds
        seek(to: seconds, tolerance: 0)
    }
    private func seek(to seconds: Double, tolerance: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        // The end boundary has no image. Keep the final frame visible when scrubbing to Out.
        let frameDuration = player.currentItem?.videoComposition?.frameDuration.seconds ?? (1.0 / 60)
        let target = max(0, min(max(0, duration - frameDuration), seconds))
        pendingSeek = (target, tolerance)
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard !isSeeking, let request = pendingSeek else { return }
        pendingSeek = nil; isSeeking = true
        let generation = seekGeneration
        let tolerance = CMTime(seconds: request.tolerance, preferredTimescale: 600)
        // Allow one decoder seek to finish, then chase the newest requested position.
        // Cancelling every in-flight seek can starve AVPlayer during a fast scrub.
        player.seek(to: CMTime(seconds: request.seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeeking = false
                if self.pendingSeek != nil { self.performPendingSeek() }
                else if self.resumeAfterSeek {
                    self.resumeAfterSeek = false
                    self.player.playImmediately(atRate: self.playbackRate); self.isPlaying = true
                }
            }
        }
    }
    func stop() { pause(); if let observer { player.removeTimeObserver(observer); self.observer = nil } }
    private func clearBoundaryObserver() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver); self.boundaryObserver = nil }
    }
}

private extension Color {
    static let editorBackground = Theme.ink
    static let editorPanel = Theme.inkPanel
    static let editorTimeline = Theme.inkTimeline
    static let editorAccent = Theme.signal
}

private enum EventEditorTarget: Identifiable {
    case new(Double)
    case existing(MatchEvent)
    var id: String {
        switch self { case .new(let seconds): "new-\(seconds)"; case .existing(let event): event.id.uuidString }
    }
    var title: String { switch self { case .new: "Add event"; case .existing: "Edit event" } }
}

private struct EventEditorSheet: View {
    let recording: Recording
    let target: EventEditorTarget
    let deleteEvent: (MatchEvent) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var kind: EventKind
    @State private var colorHex = ""
    @State private var saveError: String?
    @State private var note: String
    @State private var offset: Double
    @State private var preRoll: Double
    @State private var postRoll: Double
    @State private var showingDelete = false

    init(recording: Recording, target: EventEditorTarget, deleteEvent: @escaping (MatchEvent) -> Void) {
        self.recording = recording; self.target = target; self.deleteEvent = deleteEvent
        switch target {
        case .new(let seconds):
            _kind = State(initialValue: .goal); _note = State(initialValue: ""); _offset = State(initialValue: seconds)
            _preRoll = State(initialValue: min(max(0, seconds), EventKind.goal.defaultPreRoll))
            _postRoll = State(initialValue: min(max(0, recording.duration - seconds), EventKind.goal.defaultPostRoll))
        case .existing(let event):
            _colorHex = State(initialValue: event.colorHex)
            _kind = State(initialValue: EventKind(rawValue: event.kind) ?? .note)
            _note = State(initialValue: event.note); _offset = State(initialValue: event.offsetSeconds)
            _preRoll = State(initialValue: event.contextRecordingIDs == "[]" ? min(event.offsetSeconds, event.preRollSeconds) : event.preRollSeconds)
            _postRoll = State(initialValue: min(max(0, recording.duration - event.offsetSeconds), event.postRollSeconds))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    Picker("Type", selection: $kind) {
                        ForEach(EventKind.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                    TextField("Note (optional)", text: $note, axis: .vertical)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                        ForEach(EventColor.allCases) { color in
                            Button { colorHex = color.rawValue } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(EventColor.tint(hex: color.rawValue, kind: kind.rawValue))
                                        .frame(width: 18, height: 18)
                                        .overlay {
                                            if colorHex == color.rawValue { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) }
                                        }
                                    Text(color.title).font(.caption)
                                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                            }.buttonStyle(.plain).accessibilityLabel("\(color.title) event color")
                                .accessibilityAddTraits(colorHex == color.rawValue ? .isSelected : [])
                        }
                    }
                }
                Section("Position") {
                    HStack {
                        Button { offset = max(0, offset - 1) } label: { Image(systemName: "minus") }
                            .buttonStyle(.bordered).accessibilityLabel("Move event one second earlier")
                        Spacer()
                        Text(timecode(offset)).font(.title3.bold().monospacedDigit())
                        Spacer()
                        Button { offset = min(recording.duration, offset + 1) } label: { Image(systemName: "plus") }
                            .buttonStyle(.bordered).accessibilityLabel("Move event one second later")
                    }
                    Slider(value: $offset, in: 0...max(0.1, recording.duration))
                }
                Section {
                    Stepper(value: $preRoll, in: 0...max(0, maximumPreRoll), step: 0.5) {
                        LabeledContent("Before event", value: "\(preRoll.formatted())s")
                    }
                    Stepper(value: $postRoll, in: 0...max(0, recording.duration - offset), step: 0.5) {
                        LabeledContent("After event", value: "\(postRoll.formatted())s")
                    }
                } footer: {
                    Text("Drag the edges of the event bar on the timeline to change the window.")
                }
                if case .existing = target {
                    Section { Button("Delete event", systemImage: "trash", role: .destructive) { showingDelete = true } }
                }
            }
            .navigationTitle(target.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).bold() }
            }
            .onChange(of: kind) { oldKind, newKind in
                if preRoll == min(maximumPreRoll, oldKind.defaultPreRoll) && postRoll == min(recording.duration - offset, oldKind.defaultPostRoll) {
                    preRoll = min(maximumPreRoll, newKind.defaultPreRoll)
                    postRoll = min(max(0, recording.duration - offset), newKind.defaultPostRoll)
                }
            }
            .onChange(of: offset) {
                preRoll = min(maximumPreRoll, preRoll)
                postRoll = min(max(0, recording.duration - offset), postRoll)
            }
            .confirmationDialog("Delete this event?", isPresented: $showingDelete) {
                Button("Delete event", role: .destructive, action: delete)
            }
            .alert("Could not save event", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(saveError ?? "") }
        }.preferredColorScheme(.dark).tint(.white).presentationDetents([.medium, .large])
            .frame(width: 480, height: 600)
            .formStyle(.grouped)
    }

    private var maximumPreRoll: Double {
        if case .existing(let event) = target, event.contextRecordingIDs != "[]" {
            return max(120, event.preRollSeconds)
        }
        return offset
    }

    private func save() {
        offset = max(0, min(recording.duration, offset))
        preRoll = max(0, min(maximumPreRoll, preRoll))
        postRoll = max(0, min(recording.duration - offset, postRoll))
        switch target {
        case .new:
            let event = MatchEvent(projectID: recording.projectID, recordingID: recording.id, kind: kind.rawValue, note: note, occurredAt: recording.recordedAt.addingTimeInterval(offset))
            event.offsetSeconds = offset
            event.preRollSeconds = preRoll; event.postRollSeconds = postRoll; event.colorHex = colorHex
            modelContext.insert(event)
        case .existing(let event):
            event.kind = kind.rawValue; event.note = note; event.offsetSeconds = offset
            event.occurredAt = recording.recordedAt.addingTimeInterval(offset)
            event.preRollSeconds = preRoll; event.postRollSeconds = postRoll; event.colorHex = colorHex
            event.needsSync = true; event.mutationID = UUID()
        }
        do { try modelContext.save(); dismiss() }
        catch { modelContext.rollback(); saveError = error.localizedDescription }
    }

    private func delete() {
        if case .existing(let event) = target {
            deleteEvent(event)
        }
        dismiss()
    }
}


func timecode(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}
