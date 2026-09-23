import AVKit
import SwiftUI

enum AnalysisWorkspaceMode: String, Identifiable {
    case video, freezeFrame
    var id: String { rawValue }
    var title: String { self == .video ? "Analysis" : "Freeze-frame analysis" }
}

struct AnalysisWorkspaceRequest: Identifiable {
    let id = UUID()
    var mode: AnalysisWorkspaceMode
    var clip: CompositionClip
    var recording: Recording
    var seconds: Double
    var selectedAnnotation: UUID? = nil
    var insertsFreeze = false
    var parentClipID: UUID? = nil
}

struct AnalysisWorkspaceView: View {
    let request: AnalysisWorkspaceRequest
    let session: AnalysisSession
    let save: (CompositionClip) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var playback: EditorPlayback
    @State private var clip: CompositionClip
    @State private var selectedID: UUID?
    @State private var tool: AnalysisDrawingTool = .select
    @State private var color = Color(red: 0.86, green: 1, blue: 0.15)
    @State private var width = 0.006
    @State private var draft: AnalysisAnnotation?
    @State private var dragOriginal: AnalysisAnnotation?
    @State private var undo: [CompositionClip] = []
    @State private var redo: [CompositionClip] = []
    @State private var displayAspect: CGFloat = 16 / 9
    @State private var still: UIImage?
    @State private var error: String?
    @State private var selectedKeyframe: UUID?
    @State private var showsPlayers = true
    @State private var initialised = false
    @State private var freezeTime = 0.0
    @State private var selectedPlayer: PlayerMotionSample?
    @State private var selectedPlayerTrackID: UUID?
    @State private var showPlayerTracks = false
    @State private var playerPickerLayerID: UUID?
    @State private var showPlayerEffects = false
    @State private var pickingPlayerTrack = false
    @State private var showToolPicker = false
    @State private var showPlayerTracking = false
    @State private var correctingTrackID: UUID?
    /// With `correctingTrackID`: the pick places the player by hand at this
    /// frame instead of running tracking again.
    @State private var placingPlayer = false
    @State private var trackingTask: Task<Void, Never>?
    @State private var trackingID: UUID?
    @State private var trackingJob: UUID?
    /// Optional visual output; player identity always uses the same tracker.
    @State private var includeBodyMasks = false
    @State private var reviewingFrames = false
    @State private var reviewUndoTimes: [Double] = []
    @State private var referenceView: PlayerIdentityView?
    @State private var pickedDirection: PlayerTrackingDirection = .forward
    @State private var pickedWholeClip = false
    @State private var replacementRequest: PlayerTrackingReplacementRequest?
    @State private var queuedReplacementRequest: PlayerTrackingReplacementRequest?
    @State private var pickedReplacementRange: ClosedRange<Double>?
    @State private var reviewBox: CGRect?
    /// "Which one is he?" after a player has been lost.
    @State private var reacquiring: AnalysisTrackingLibrary.Player?
    @State private var reacquisitionCandidates: [PlayerReacquisitionCandidate] = []
    @State private var reacquisitionSearching = false
    @State private var reacquisitionProgress = 0.0
    @State private var reacquisitionFrom = 0.0
    @State private var reacquisitionTask: Task<Void, Never>?
    @State private var trackingProgress = 0.0
    /// Live state of an incremental player pass: which way it is walking, the
    /// frame it started from and the frame it has reached.
    @State private var trackingDirection: PlayerTrackingDirection?
    @State private var trackingOrigin: Double?
    @State private var trackingPhase: PlayerTrackingPhase = .following
    @State private var trackingTime: Double?
    @State private var trackingStoredAt = 0.0
    @State private var correctingPlayer = false
    @State private var showProperties = false
    @State private var canvasZoom: CGFloat = 1
    @State private var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    @State private var constructionPoints: [CGPoint] = []
    @State private var constructionPlayers: [PlayerMotionSample] = []
    @State private var areaUsesPlayers = false
    @State private var dragVertex: Int?
    @State private var constructionID = UUID()
    @State private var correctingAnchor: Int?
    @State private var selectedVertex: Int?
    @State private var dragFrame: CGRect?
    @State private var canvasNavigation: FieldPlacementViewport?
    @State private var canvasTouch: (start: CGPoint, current: CGPoint, frame: CGRect, time: Double, ready: Bool)?
    @State private var canvasDragging = false
    @State private var confirmsDelete = false
    @State private var editingTextSize = false
    @State private var groundRequest: GroundCalibrationRequest?
    @State private var fieldPreviewEnabled = false
    @State private var workspaceHeight = 320.0
    @State private var sidebarWidth = 390.0
    @State private var timelineZoom: CGFloat = 1
    @State private var sourceFrameRate = 30.0

    init(request: AnalysisWorkspaceRequest, session: AnalysisSession, save: @escaping (CompositionClip) throws -> Void) {
        self.request = request; self.session = session; self.save = save
        var prepared = request.clip
        prepared.importAnnotationTracks()
        _clip = State(initialValue: prepared)
        _selectedID = State(initialValue: request.selectedAnnotation)
        _freezeTime = State(initialValue: request.clip.startSeconds)
        _playback = State(initialValue: EditorPlayback(player: AVPlayer(url: request.recording.fileURL), duration: request.recording.duration, observationFrameRate: 60))
    }

    private var time: Double { clip.freezeDuration == nil ? playback.currentSeconds : freezeTime }
    private var selected: AnalysisAnnotation? { clip.annotations.first { $0.id == selectedID } }
    private var analysis: RecordingAnalysis? { session.analysis(for: request.recording.id) }
    private var detectionTime: Double { clip.freezeDuration == nil ? time : clip.startSeconds }
    private var detections: [AnalysisDetection] {
        guard let frame = analysis?.frame(at: detectionTime),
              !reviewingFrames || abs(frame.time - detectionTime) < 0.5 / sourceFrameRate else { return [] }
        return frame.detections
    }
    private var frameReview: PlayerFrameReview {
        .init(range: clip.startSeconds...clip.endSeconds, frameRate: sourceFrameRate)
    }
    private var pickingConnection: Bool { tool == .connection || tool == .zone && areaUsesPlayers }
    private var playerEffectLayers: [AnalysisAnnotation] {
        clip.annotations.filter { mark in
            [.player, .spotlight, .text, .trajectory, .loupe].contains(mark.tool) && mark.isActiveInEditor(at: time) &&
            (selectedPlayerTrackID != nil ? mark.playerMotion?.trackID == selectedPlayerTrackID :
                selected?.playerEffectGroupID != nil ? mark.playerEffectGroupID == selected?.playerEffectGroupID : mark.id == selectedID)
        }
    }
    private var selectedPlayerName: String {
        clip.trackingLibrary?.players.first(where: { $0.id == selectedPlayerTrackID })?.name ?? "Player"
    }
    private var connectionAnchors: [AnalysisConnectionAnchor] { selected?.connectionAnchors(at: time, library: clip.trackingLibrary) ?? [] }
    private var correctingConnectionAnchor: AnalysisConnectionAnchor? { connectionAnchors.first { $0.id == correctingAnchor } }
    private var canvasAccessibilityValue: String {
        var value = String(format: "%.2g×, centre %.3f, %.3f", Double(canvasZoom), Double(zoomCenter.x), Double(zoomCenter.y))
        if let selected, selected.fieldLines == true {
            value += ", field corners: " + selected.points(at: time).map { String(format: "%.2f,%.2f", Double($0.x), Double($0.y)) }.joined(separator: "; ")
        }
        return value
    }
    private var canvasHint: String {
        if pickingPlayerTrack {
            if let referenceView { return "Select \(selectedPlayerName) · \(referenceView.title) reference" }
            if reviewingFrames, playback.isSeeking { return "Loading next frame…" }
            if reviewingFrames { return "Tap the player’s centre or draw the full body · advances one frame" }
            if placingPlayer, correctingTrackID != nil { return "Tap or draw around \(selectedPlayerName) to place it at this frame" }
            return correctingTrackID == nil ? "Tap or draw around a new player to track" : "Tap or draw around the same player to continue its track"
        }
        if tool == .connection || tool == .zone && areaUsesPlayers { return "Tap players in order, then Finish" }
        if tool == .zone { return "Tap polygon corners, then Finish" }
        if tool == .zoom { return "Tap where to zoom · trim its layer to set the duration" }
        if tool == .loupe { return "Tap a player to follow, or tap anywhere for a static loupe" }
        if correctingPlayer {
            return correctingConnectionAnchor.map { "Reselect \($0.title) · orange endpoint" } ?? "Tap or draw around the same player"
        }
        if tool == .select, let selected {
            if selected.tool == .zoom { return "Drag the focus · Preview effect to see the zoom" }
            return selected.motionMode == .keyframes ? "Scrub, then drag a handle to set a keyframe" : ""
        }
        if tool == .select { return "" }
        if tool == .player || tool == .spotlight { return "Tap a player or draw around one" }
        return tool == .text ? "Tap to place text" : ""
    }

    var body: some View {
        NavigationStack {
            AdaptiveLayout { layout in
                if layout.isLandscape {
                    let sidebar = min(max(300, sidebarWidth), max(300, layout.size.width - 240))
                    HStack(spacing: 0) {
                        analysisPreview.frame(maxWidth: .infinity, maxHeight: .infinity)
                        EditorPanelDivider(title: "Workspace", vertical: true, value: sidebar,
                            limits: 300...max(300, layout.size.width - 240)) { sidebarWidth = $0 }
                        analysisWorkspace.frame(width: sidebar)
                    }
                } else {
                    let sizes = EditorPanelSizes(height: layout.size.height, workspace: workspaceHeight, minimumWorkspace: 260)
                    VStack(spacing: 0) {
                        analysisPreview.frame(height: sizes.preview).clipped()
                        EditorPanelDivider(title: "Workspace", value: sizes.workspace,
                            limits: min(260, layout.size.height * 0.45)...max(260, layout.size.height - 180)) { workspaceHeight = $0 }
                        analysisWorkspace.frame(height: sizes.workspace).clipped()
                    }
                }
            }
            .background(Theme.inkPanel)
            .navigationTitle(request.mode == .video ? "Analyse" : "Freeze frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(.rect) }
                        .accessibilityLabel("Cancel analysis").accessibilityIdentifier("cancel-analysis-workspace")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    transport
                    Button("Tools", systemImage: tool.symbol) { playback.pause(); showToolPicker = true }
                        .disabled(trackingID != nil).accessibilityValue(tool.title)
                        .accessibilityIdentifier("analysis-tools")
                    Button("Drawing style", systemImage: "slider.horizontal.3") { showProperties = true }
                        .accessibilityIdentifier("analysis-drawing-style")
                    Button("Save", systemImage: "checkmark") {
                        do { try save(clip); dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(trackingID != nil).accessibilityIdentifier("save-analysis-workspace")
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("Analysis", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .sheet(isPresented: $showProperties) {
            AnalysisInspectorSheet(title: selected?.title ?? "Drawing style", hasLayer: selected != nil,
                                   style: { inspectorStyle.disabled(trackingID != nil) },
                                   timing: { inspectorTiming.disabled(trackingID != nil) },
                                   layer: { inspectorLayer.disabled(trackingID != nil) })
                .id(selectedID)
        }
        .sheet(isPresented: $showPlayerTracks, onDismiss: { playerPickerLayerID = nil }) {
            AnalysisPlayerTracksSheet(players: clip.trackingLibrary?.players ?? [], clipStart: clip.startSeconds, clipEnd: clip.endSeconds, time: time,
                                      select: chooseSavedPlayer, add: {
                                          if playerPickerLayerID != nil { pickLayerPlayer() } else { pickPlayerTrack() }
                                      },
                                      rename: renamePlayerTrack,
                                      assignTeam: assignPlayerTeam, link: linkPlayerTrack,
                                      canLink: { clip.trackingLibrary?.canLinkPlayer($0, to: $1) == true },
                                      remove: removePlayerTrack, canRemove: { clip.canRemovePlayerTrack($0) },
                                      selectedID: selected?.playerMotion?.trackID ?? selectedPlayerTrackID,
                                      choosingForLayer: playerPickerLayerID != nil)
        }
        .sheet(item: $reacquiring) { player in
            AnalysisPlayerReacquisitionSheet(
                playerName: player.name, searchedFrom: reacquisitionFrom, clipStart: clip.startSeconds,
                isSearching: reacquisitionSearching, progress: reacquisitionProgress,
                candidates: reacquisitionCandidates,
                confirm: { candidate in confirmReacquisition(player.id, candidate: candidate) },
                preview: { candidate in seek(candidate.time) },
                cancel: { reacquisitionTask?.cancel(); reacquisitionTask = nil })
        }
        .sheet(isPresented: $showPlayerTracking, onDismiss: {
            if let queued = queuedReplacementRequest {
                queuedReplacementRequest = nil; replacementRequest = queued
            }
        }) {
            if let player = activePlayer {
                AnalysisPlayerTrackingSheet(player: player, clipRange: clip.startSeconds...clip.endSeconds, time: time,
                                            isBusy: trackingID != nil, layer: selected?.playerMotion != nil ? selected : nil,
                                            includeBodyMasks: $includeBodyMasks,
                                            trackWholeClip: { trackPlayerBackward(player.id, thenForward: true) },
                                            trackToEnd: { trackPlayerToEnd(player.id) },
                                            trackBackToStart: { trackPlayerBackward(player.id, thenForward: false) },
                                            fillGap: { fillPlayerGap(player.id) },
                                            addReference: { view in beginPlacing(player.id); referenceView = view },
                                            setNumber: { setPlayerNumber(player.id, number: $0) },
                                            seek: { seek($0) },
                                            bridge: { value in if selectedID != nil { checkpoint(); setGapBridging(value) } },
                                            smoothing: { value in if selectedID != nil { checkpoint(); setTrackingSmoothing(value) } },
                                            rename: { renamePlayerTrack(player.id, name: $0) },
                                            remove: clip.canRemovePlayerTrack(player.id) ? { removePlayerTrack(player.id) } : nil)
            }
        }
        .sheet(item: $replacementRequest) { request in
            AnalysisPlayerTrackingReplacementSheet(request: request, clipRange: clip.startSeconds...clip.endSeconds,
                                                   frameRate: sourceFrameRate) { range, seedTime in
                seek(seedTime)
                pickPlayerTrack(correcting: request.id, direction: seedTime - range.lowerBound > 0.05 ? .backward : .forward)
                pickedReplacementRange = range
            }
        }
        .sheet(isPresented: $showToolPicker) {
            AnalysisToolPickerSheet(tool: tool, fieldPreview: fieldPreviewEnabled, hasField: clip.groundCalibration != nil,
                                    choose: chooseTool, measure: openMeasurements, field: toggleFieldPreview)
        }
        .sheet(isPresented: $showPlayerEffects) {
            AnalysisPlayerEffectsSheet(name: selectedPlayerName, existing: playerEffectLayers, allowsTrajectory: clip.freezeDuration == nil, measurementStatus: measurementStatus, apply: applyPlayerEffects)
        }
        .fullScreenCover(item: $groundRequest) { request in
            GroundCalibrationSheet(url: self.request.recording.fileURL, request: request, apply: applyGroundCalibration)
        }
        .preferredColorScheme(.dark).tint(.white)
        .task { await prepare() }
        .onDisappear {
            // A full-screen placement editor temporarily covers this workspace.
            // Keep the time observer so playback/scrubbing still updates on return.
            if groundRequest != nil { playback.pause() }
            else { playback.stop(); session.cancel(); trackingTask?.cancel() }
        }
        .onChange(of: session.errorMessage) { if let message = session.errorMessage { error = message } }
        .onChange(of: pickingPlayerTrack) {
            if !pickingPlayerTrack, reviewingFrames { endFrameReview() }
        }
        .onChange(of: selectedID) {
            selectedVertex = nil
            correctingAnchor = nil
            if selected?.keyframes.contains(where: { $0.id == selectedKeyframe }) != true { selectedKeyframe = nil }
            correctingPlayer = false
        }
        .task(id: detectionTime) {
            guard initialised, !playback.isPlaying, trackingID == nil, selectedID == nil || correctingPlayer || tool == .connection || tool == .zone && areaUsesPlayers else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if reviewingFrames ? detections.isEmpty : analysis?.frame(at: detectionTime) == nil { detect(motion: false) }
        }
        .onChange(of: time) {
            if let box = selected?.playerMotion?.box(at: time) { selectedPlayer = .init(time: time, box: box) }
            else if selected?.playerMotion == nil, let box = selected?.playerEffectBox { selectedPlayer = .init(time: time, box: box) }
            else if selectedID == nil, let id = selectedPlayerTrackID,
                    let box = clip.trackingLibrary?.players.first(where: { $0.id == id })?.motion.box(at: time) {
                selectedPlayer = .init(time: time, box: box)
            }
            else if let player = selectedPlayer, abs(player.time - time) > 0.05 { selectedPlayer = nil }
        }
    }

    private var analysisPreview: some View {
        canvas.background(.black)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 52).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                EditorPreviewControls(playback: playback, isPreparing: !initialised,
                    isEnabled: initialised && clip.freezeDuration == nil && trackingID == nil && constructionPoints.isEmpty,
                    play: togglePlayback, currentTime: time - clip.startSeconds,
                    totalTime: clip.annotationEnd - clip.startSeconds,
                    timeIdentifier: "analysis-current-time", playIdentifier: "analysis-play-pause",
                    previousFrame: { seek(time - 1 / sourceFrameRate) }, nextFrame: { seek(time + 1 / sourceFrameRate) })
                    .padding(.horizontal, 8).padding(.bottom, 2)
            }
    }

    private func togglePlayback() {
        if reviewingFrames { endFrameReview() }
        if playback.isPlaying { playback.pause() }
        else { playback.playRange(from: time >= clip.endSeconds - 0.04 ? clip.startSeconds : time, to: clip.endSeconds) }
    }

    /// One bottom row: the running pass, the picked player, the selected layer's
    /// controls, or the current tool. Drawing tools open from the toolbar.
    private var analysisWorkspace: some View {
        VStack(spacing: 0) {
            if correctingPlayer, let anchor = correctingConnectionAnchor {
                AnalysisConnectionCorrectionCard(anchor: anchor, url: request.recording.fileURL, clipStart: clip.startSeconds, showLastSeen: { seek($0) }).id(anchor.id)
            }
            constructionControls
            if selected?.linkedPlayers != nil, !correctingPlayer {
                AnalysisConnectionSelectionStrip(anchors: connectionAnchors, selected: correctingAnchor) { anchor in
                    correctingAnchor = anchor; correctingPlayer = true; tool = .select
                    playback.pause(); detect(motion: false)
                }.disabled(trackingID != nil || selected?.isLocked == true)
            }
            layerTimeline
            if trackingID != nil || pickingPlayerTrack { playerActions }
            else if correctingPlayer, selected?.linkedPlayers == nil, selected != nil { layerControls }
            else if let player = activePlayer { playerBar(player) }
            else if selectedPlayer != nil, selectedID == nil { newPlayerBar }
            else if selected != nil { layerControls }
        }.background(Theme.inkPanel)
    }

    /// The player the bottom bar is about: the selected drawing's player, or
    /// the saved player picked on the video or from the list.
    private var activePlayer: AnalysisTrackingLibrary.Player? {
        let id = selected.map { $0.playerMotion?.trackID } ?? selectedPlayerTrackID
        guard selected == nil || selected?.playerMotion != nil, let id else { return nil }
        return clip.trackingLibrary?.players.first { $0.id == id }
    }

    /// One bar for a player, whatever was tapped: name, effects, tracking.
    private func playerBar(_ player: AnalysisTrackingLibrary.Player) -> some View {
        HStack(spacing: 8) {
            Button {
                playerPickerLayerID = selected?.playerMotion != nil ? selected?.id : nil
                playback.pause(); showPlayerTracks = true
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(player.kitColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.white.opacity(0.2))
                        .frame(width: 14, height: 14).overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                    Text(player.number.map { "\(player.name) · #\($0)" } ?? player.name).lineLimit(1)
                }.font(.caption.bold())
            }.buttonStyle(.plain).frame(minHeight: 44).accessibilityIdentifier("analysis-active-player-track")
            Spacer(minLength: 0)
            Button("Effects", systemImage: "sparkles") { openPlayerEffects(for: player) }
                .buttonStyle(EditorActionStyle()).accessibilityIdentifier("analysis-player-effects")
            Button("Tracking", systemImage: player.motion.missingIntervals(in: clip.startSeconds...clip.endSeconds).isEmpty ? "figure.run" : "figure.run.circle")
                { playback.pause(); showPlayerTracking = true }
                .buttonStyle(EditorActionStyle(prominent: player.motion.isMissing(at: time))).accessibilityIdentifier("analysis-player-tracking")
            if selected != nil { layerMenu }
        }.padding(.horizontal, 10).frame(height: 52).background(Theme.inkPanel).disabled(trackingID != nil)
    }

    /// A detected body that is not a saved player yet.
    private var newPlayerBar: some View {
        HStack(spacing: 8) {
            Label("New player", systemImage: "person.crop.circle.badge.plus").font(.caption.bold()).lineLimit(1)
            Spacer(minLength: 0)
            Button("Effects", systemImage: "sparkles") { showPlayerEffects = true }
                .buttonStyle(EditorActionStyle()).accessibilityIdentifier("analysis-player-effects")
            Button("Track", systemImage: "figure.run") { if let seed = selectedPlayer?.box { trackIndependentPlayer(seed: seed) } }
                .buttonStyle(EditorActionStyle(prominent: true)).accessibilityIdentifier("analysis-track-selected-player")
        }.padding(.horizontal, 10).frame(height: 52).background(Theme.inkPanel).disabled(trackingID != nil || clip.freezeDuration != nil)
    }

    private func openPlayerEffects(for player: AnalysisTrackingLibrary.Player) {
        let motion = player.motion
        let range = selected.map { $0.start...$0.end } ?? clip.startSeconds...clip.endSeconds
        let effectTime: Double
        if motion.box(at: time) != nil, range.contains(time) { effectTime = time }
        else if let nearest = motion.samples.filter({ range.contains($0.time) && motion.box(at: $0.time) != nil })
                    .min(by: { abs($0.time - time) < abs($1.time - time) }) { effectTime = nearest.time }
        else { error = "This player has no tracking inside this layer's time range."; return }
        selectedPlayerTrackID = player.id
        selectedPlayer = .init(time: effectTime, box: motion.box(at: effectTime) ?? .zero)
        if effectTime != time { seek(effectTime) }
        showPlayerEffects = true
    }

    /// Layer housekeeping shared by the player bar and the drawing bar.
    private var layerMenu: some View {
        Menu {
            if let selected {
                Button("Layer style", systemImage: "slider.horizontal.3") { showProperties = true }
                if selected.playerMotion != nil {
                    Button("Follow another player", systemImage: "person.2") { playerPickerLayerID = selected.id; showPlayerTracks = true }
                    Button("Stop following · keep position", systemImage: "pause") { setMotionMode(.still) }
                }
                if clip.freezeDuration == nil {
                    Button("Preview effect", systemImage: "play.rectangle") { playback.playRange(from: selected.start, to: selected.end) }
                }
                Button("Duplicate", systemImage: "plus.square.on.square", action: duplicate)
                if clip.freezeDuration == nil, selected.playerMotion == nil {
                    Button("Follow clip camera", systemImage: "video.badge.waveform") { beginCameraTracking() }
                        .disabled(selected.isLocked == true)
                }
                Button(selected.isLocked == true ? "Unlock layer" : "Lock layer", systemImage: "lock") { toggleLayerLocked(selected.id) }
                Button("Delete layer", systemImage: "trash", role: .destructive) {
                    checkpoint(); clip.annotations.removeAll { $0.id == selected.id }; selectedID = nil
                }.disabled(selected.isLocked == true)
            }
        } label: {
            Label("Layer actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly).modifier(AnalysisControlSurface())
        }.buttonStyle(.plain).accessibilityIdentifier("analysis-layer-options")
    }

    private var historyUndo: (() -> Void)? { undo.isEmpty ? nil : { undoEdit() } }
    private var historyRedo: (() -> Void)? { redo.isEmpty ? nil : { redoEdit() } }

    private var layerTimeline: some View {
        AnalysisLayerTimeline(annotations: clip.annotations, bounds: clip.startSeconds...clip.annotationEnd, time: time,
                    selectedID: selectedID, selectedKeyframe: selectedKeyframe,
                    select: selectTimelineLayer, seek: { seek($0) }, previewSeek: previewSeek,
                    beginEdit: { playback.pause(); checkpoint() }, edit: editTimelineLayer,
                    selectKeyframe: selectTimelineKeyframe, toggleHidden: toggleLayerHidden,
                    toggleLocked: toggleLayerLocked, reorder: reorderLayer,
                    videoURL: nil, freezeTime: clip.freezeDuration == nil ? nil : clip.startSeconds,
                    undo: historyUndo, redo: historyRedo, zoom: $timelineZoom)
                    .frame(maxHeight: .infinity).disabled(trackingID != nil)
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let fitted = AVMakeRect(aspectRatio: CGSize(width: displayAspect, height: 1), insideRect: CGRect(origin: .zero, size: geometry.size))
            let editsZoom = !playback.isPlaying && (tool == .zoom || selected?.tool == .zoom)
            let zoom = editsZoom ? CGAffineTransform.identity : AnnotationViewport.transform(marks: clip.annotations, time: time, frame: fitted, bounds: fitted)
            let inspection = AnnotationViewport.inspectionTransform(fitted: fitted, zoom: canvasZoom, center: zoomCenter)
            let frame = dragFrame ?? fitted.applying(zoom).applying(inspection)
            canvasContent(frame: frame, bounds: fitted).clipShape(Path(fitted)).contentShape(Path(fitted))
            .overlay(alignment: .top) { inspectionControls }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("analysis-workspace-canvas")
            .accessibilityValue(canvasAccessibilityValue)
    }

    private func canvasContent(frame: CGRect, bounds: CGRect) -> some View {
        let marks = clip.annotations.filter { $0.id != draft?.id } + (draft.map { [$0] } ?? []) + constructionPreview
        let usesLoupe = marks.contains { $0.tool == .loupe }
        return ZStack(alignment: .topLeading) {
            Color(white: 0.10)
            Group {
                if clip.freezeDuration != nil {
                    if let still { Image(uiImage: still).resizable().scaledToFit() }
                    else { ProgressView("Loading frame…") }
                } else { AnalysisPlayerSurface(player: playback.player) }
            }.frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
            if usesLoupe {
                AnalysisLoupePreview(marks: marks, time: time, player: clip.freezeDuration == nil ? playback.player : nil,
                                     still: still, frame: frame, bounds: bounds, ground: clip.groundCalibration)
                    .allowsHitTesting(false)
            }
            AnnotationDrawingSurface(marks: marks, ground: clip.groundCalibration, time: time, frame: frame, selectedID: playback.isPlaying ? nil : selectedID, detections: showsPlayers && !playback.isPlaying && (selectedID == nil || correctingPlayer || tool == .connection || tool == .zone && areaUsesPlayers) && (tool == .player || tool == .spotlight || tool == .select || tool == .connection || tool == .zone && areaUsesPlayers) ? detections : [], selectedPlayer: playback.isPlaying ? nil : selectedPlayer?.box, constructionPoints: constructionPoints, renderMarks: !usesLoupe)
                .allowsHitTesting(false)
                .overlay {
                    ConnectionAnchorSurface(anchors: playback.isPlaying || selected?.isHidden == true ? [] : connectionAnchors,
                                            correcting: correctingPlayer ? correctingAnchor : nil, frame: frame).allowsHitTesting(false)
                }
            if fieldPreviewEnabled {
                AnalysisFieldPreview(calibration: clip.groundCalibration, time: time, frame: frame, bounds: bounds)
                    .allowsHitTesting(false)
            }
            if showsPlayers, (tool == .select && (selectedID == nil || correctingPlayer) || pickingConnection), !playback.isPlaying, trackingID == nil {
                ForEach(Array(detections.enumerated()), id: \.offset) { index, detection in
                    Button {
                        if pickingConnection { appendConstructionPlayer(detection.rect) }
                        else { selectPlayer(detection.rect) }
                    } label: { Color.clear.contentShape(.rect) }
                        .buttonStyle(.plain)
                        .frame(width: max(18, detection.rect.width * frame.width), height: max(22, detection.rect.height * frame.height))
                        .position(x: frame.minX + detection.rect.midX * frame.width, y: frame.minY + detection.rect.midY * frame.height)
                        .accessibilityLabel("Player \(index + 1)")
                        .accessibilityHint("Select to add a ring, spotlight or following label")
                        .accessibilityIdentifier("analysis-detected-player-\(index)")
                }
            }
            FieldPlacementTouchSurface(label: "Analysis preview", hint: "One finger draws or selects. Two fingers pan and pinch to zoom.", identifier: "analysis-preview-touch-surface") {
                handleCanvasTouch($0, frame: frame, fitted: bounds)
            }
        }
    }

    private var inspectionControls: some View {
        HStack(alignment: .top) {
            if !canvasHint.isEmpty {
                Text(canvasHint)
                    .font(.caption).padding(8).background(.black.opacity(0.65), in: .capsule).allowsHitTesting(false)
            }
            Spacer(minLength: 4)
            if let player = activePlayer { selectedPlayerChip(player) }
            if abs(canvasZoom - 1) > 0.01 || hypot(zoomCenter.x - 0.5, zoomCenter.y - 0.5) > 0.01 {
                Button("Fit preview", systemImage: "arrow.down.right.and.arrow.up.left") {
                    canvasZoom = 1; zoomCenter = CGPoint(x: 0.5, y: 0.5)
                }.labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle())
                    .accessibilityIdentifier("analysis-inspect-fit")
            }
        }.padding(8)
    }

    /// Top-right badge on the video: who is selected, and whether a tracking pass is running.
    private func selectedPlayerChip(_ player: AnalysisTrackingLibrary.Player) -> some View {
        let tracking = trackingID != nil
        return Button {
            playback.pause(); showPlayerTracking = true
        } label: {
            HStack(spacing: 6) {
                Circle().fill(player.kitColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.white.opacity(0.2))
                    .frame(width: 10, height: 10).overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                Text(player.number.map { "\(player.name) · #\($0)" } ?? player.name).lineLimit(1)
                if tracking {
                    Image(systemName: "figure.run").symbolEffect(.pulse)
                    Text("\(Int(trackingProgress * 100))%").monospacedDigit()
                }
            }
            .font(.caption.bold()).foregroundStyle(tracking ? Theme.ink : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tracking ? Theme.signal : Color.black.opacity(0.65), in: .capsule)
        }.buttonStyle(.plain).disabled(tracking)
            .accessibilityIdentifier("analysis-selected-player-chip")
            .accessibilityLabel(tracking ? "Tracking \(player.name)" : "Selected player \(player.name)")
    }

    private func toggleFieldPreview() {
        if clip.groundCalibration == nil { fieldPreviewEnabled = true; openMeasurements() }
        else {
            fieldPreviewEnabled.toggle()
            if fieldPreviewEnabled, clip.groundCalibration?.fixedCamera == false { ensureSharedCameraTracking() }
        }
    }

    @ViewBuilder private var playerActions: some View {
        if trackingID != nil {
            HStack(spacing: 8) {
                ProgressView(value: trackingProgress).frame(width: 60)
                if let direction = trackingDirection {
                    Image(systemName: direction == .forward ? "arrow.right" : "arrow.left")
                        .font(.caption.bold()).foregroundStyle(Theme.signal)
                        .accessibilityLabel(direction == .forward ? "Tracking forward" : "Tracking backward")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(trackingRangeLabel).font(.caption.monospacedDigit())
                    if trackingDirection != nil {
                        Text(trackingPhase.label).font(.caption2)
                            .foregroundStyle(trackingPhase == .following ? Color.secondary : Color.orange)
                            .accessibilityIdentifier("analysis-tracking-phase")
                    }
                }.lineLimit(1)
                Spacer(minLength: 4)
                // Stop, not Cancel: everything tracked so far is kept.
                Button("Stop") { trackingTask?.cancel() }
                    .buttonStyle(AnalysisControlStyle()).accessibilityIdentifier("analysis-stop-tracking")
            }.padding(.horizontal, 10).frame(height: 44).background(Theme.inkPanel)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("analysis-tracking-status")
        } else if reviewingFrames {
            frameReviewControls
        } else if pickingPlayerTrack {
            HStack {
                Text(placingPlayer && correctingTrackID != nil ? "Place player here" : correctingTrackID == nil ? "New player track" : "Correct player track").font(.caption.bold())
                Spacer()
                Button("Cancel pick") { pickingPlayerTrack = false; correctingTrackID = nil; placingPlayer = false; pickedReplacementRange = nil }
                    .buttonStyle(AnalysisControlStyle())
            }.padding(.horizontal, 12).padding(.vertical, 4).background(Theme.inkPanel)
        }
    }

    private var frameReviewControls: some View {
        AnalysisPlayerFrameReviewControls(name: selectedPlayerName, time: time - clip.startSeconds,
            canGoBack: frameReview.previous(before: time) != nil, canGoNext: frameReview.next(after: time) != nil,
            canUndo: !reviewUndoTimes.isEmpty && !undo.isEmpty,
            canTrack: reviewUndoTimes.last.map { $0 < clip.endSeconds - 0.05 } ?? false,
            isSeeking: playback.isSeeking,
            previous: { if let previous = frameReview.previous(before: time) { seek(previous) } },
            next: { if let next = frameReview.next(after: time) { seek(next) } },
            undo: undoEdit, track: continueReviewedPlayer, done: endFrameReview,
            redoTracking: { if let id = correctingTrackID { openTrackingReplacement(id, at: reviewUndoTimes.last ?? time) } })
    }

    private func openTrackingReplacement(_ id: UUID, at sourceTime: Double? = nil, wholeClip: Bool = false, afterDismiss: Bool = false) {
        guard trackingID == nil, let player = clip.trackingLibrary?.players.first(where: { $0.id == id }) else { return }
        playback.pause()
        let request = PlayerTrackingReplacementRequest(id: id, name: player.name, time: sourceTime ?? time, wholeClip: wholeClip)
        if afterDismiss { queuedReplacementRequest = request } else { replacementRequest = request }
    }

    private func continueReviewedPlayer() {
        guard let id = correctingTrackID, let start = reviewUndoTimes.last,
              let player = clip.trackingLibrary?.players.first(where: { $0.id == id }),
              let seed = player.motion.samples.first(where: { abs($0.time - start) < 1 / 600 })?.box else { return }
        var prior = player.motion; prior.identity = player.identity
        endFrameReview(); seek(start)
        runPlayerTracking(id: id, seed: seed, from: start, to: clip.endSeconds, direction: .forward,
                          prior: prior.preparingCorrection(at: start, direction: .forward), includeBodyMasks: includeBodyMasks, confirmedSeed: true)
    }

    private func endFrameReview() {
        reviewingFrames = false; pickingPlayerTrack = false; correctingTrackID = nil; placingPlayer = false
        reviewUndoTimes = []; reviewBox = nil
        pickedReplacementRange = nil
    }

    /// "Tracking 0:03.4 → 0:12.8 · 41%" so the tracked range is visible while it grows.
    private var trackingRangeLabel: String {
        guard trackingDirection != nil, let origin = trackingOrigin, let now = trackingTime else {
            return "Tracking · \(Int(trackingProgress * 100))%"
        }
        let from = timelineTimecode(min(origin, now) - clip.startSeconds, includesTenths: true)
        let to = timelineTimecode(max(origin, now) - clip.startSeconds, includesTenths: true)
        return "\(from) – \(to) · \(Int(trackingProgress * 100))%"
    }

    private var selectedTrackMotion: PlayerMotion? {
        clip.trackingLibrary?.players.first(where: { $0.id == selectedPlayerTrackID })?.motion
    }

    /// Step between the untracked sections of the selected player so each can
    /// be checked, placed by hand or resumed.
    @ViewBuilder private func gapNavigation(_ id: UUID) -> some View {
        let range = clip.startSeconds...clip.endSeconds
        let motion = clip.trackingLibrary?.players.first(where: { $0.id == id })?.motion
        let previous = motion?.previousMissing(before: time, in: range)
        let next = motion?.nextMissing(after: time, in: range)
        Button("Previous gap", systemImage: "arrow.left.to.line") { if let previous { seek(previous) } }
            .labelStyle(.iconOnly).disabled(previous == nil).accessibilityIdentifier("analysis-previous-gap")
        Button("Next gap", systemImage: "arrow.right.to.line") { if let next { seek(next) } }
            .labelStyle(.iconOnly).disabled(next == nil).accessibilityIdentifier("analysis-next-gap")
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Menu {
                if clip.freezeDuration == nil {
                    Button("Track new player", systemImage: "person.badge.plus") { pickPlayerTrack() }
                        .accessibilityIdentifier("analysis-track-new-player")
                    Button("Track all players", systemImage: "person.3.sequence") { trackAllPlayers() }
                        .accessibilityIdentifier("analysis-track-all-players")
                    Button("Manage player tracks", systemImage: "person.2") { playback.pause(); playerPickerLayerID = nil; showPlayerTracks = true }
                        .accessibilityIdentifier("analysis-manage-player-tracks")
                }
                Button("Measurements & ground", systemImage: "ruler", action: openMeasurements)
                if clip.groundCalibration != nil {
                    Button("New ground reference here", systemImage: "ruler.fill") {
                        playback.pause()
                        groundRequest = .init(sourceTime: clip.freezeDuration == nil ? time : clip.startSeconds,
                                              annotationTime: time, existing: nil, isStill: clip.freezeDuration != nil,
                                              sourceRange: clip.startSeconds...clip.endSeconds, cameraMotion: clip.trackingLibrary?.sharedCamera)
                    }
                }
                if clip.freezeDuration == nil {
                    Section("Clip camera · shared by all layers") {
                        Text(cameraCoverageStatus)
                        Button(clip.hasFullCameraTrack ? "Re-track entire clip" : "Track entire clip", systemImage: "video.badge.waveform") {
                            ensureSharedCameraTracking(force: clip.hasFullCameraTrack)
                        }.accessibilityIdentifier("analysis-track-clip-camera")
                        if selected != nil { Button("Follow clip camera", systemImage: "link") { beginCameraTracking() } }
                    }
                }
            } label: {
                Label("Clip tracks", systemImage: "figure.run.square.stack")
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(.rect)
            }.buttonStyle(.plain)
                .accessibilityIdentifier("analysis-clip-tracks")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("analysis-transport")
            .disabled(trackingID != nil || !constructionPoints.isEmpty)
    }

    @ViewBuilder private var layerControls: some View {
        if let selected, correctingPlayer, selected.linkedPlayers == nil {
            HStack {
                Text("Tap or draw around the player").font(.caption.bold())
                Spacer(minLength: 0)
                Button("Cancel pick") { correctingPlayer = false; tool = .select; session.cancel() }
                    .buttonStyle(AnalysisControlStyle()).accessibilityIdentifier("analysis-correct-tracking")
            }.padding(.horizontal, 12).frame(height: 44).background(Theme.inkPanel)
        } else if let selected {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    if selected.tool == .trajectory {
                        Label("Follows player track", systemImage: "figure.run")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                    Menu {
                        Button("Static", systemImage: "pause") { setMotionMode(.still) }
                        Button("Keyframes", systemImage: "diamond") { setMotionMode(.keyframes) }
                        if clip.freezeDuration == nil {
                            Button("Follow player", systemImage: "figure.run") { setMotionMode(.player) }
                            Button("Follow clip camera", systemImage: "video") { beginCameraTracking() }
                        }
                    } label: { Label(selected.motionMode.title, systemImage: "move.3d") }
                        .buttonStyle(EditorActionStyle()).disabled(selected.isLocked == true)
                        .accessibilityValue(selected.motionMode.title)
                        .accessibilityIdentifier("analysis-motion-mode")
                    Spacer(minLength: 0)
                    if selected.motionMode == .camera, clip.freezeDuration == nil {
                        Button("Re-track camera", systemImage: "scope") { ensureSharedCameraTracking(force: true) }
                            .labelStyle(.iconOnly).buttonStyle(AnalysisTransportStyle()).disabled(selected.isLocked == true)
                            .accessibilityIdentifier("analysis-correct-tracking")
                    }
                    Button("Style", systemImage: "slider.horizontal.3") { showProperties = true }
                        .buttonStyle(EditorActionStyle())
                    }
                    layerMenu
                }
                if selected.tool == .zone, selected.fieldLines != true, selected.linkedPlayers == nil {
                    HStack(spacing: 12) {
                        Text(selectedVertex.map { "Corner \($0 + 1)" } ?? "Tap a corner to edit").font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Add corner", systemImage: "plus") {
                            let index = selectedVertex ?? max(0, selected.points.count - 1)
                            updateSelected { $0.insertPolygonCorner(after: index) }; selectedVertex = index + 1
                        }.disabled(selected.points.count >= 12)
                        Button("Remove corner", systemImage: "minus") {
                            guard let index = selectedVertex else { return }
                            updateSelected { $0.removePolygonCorner(at: index) }; selectedVertex = nil
                        }.labelStyle(.iconOnly).disabled(selectedVertex == nil || selected.points.count <= 3)
                    }.buttonStyle(AnalysisControlStyle()).disabled(selected.isLocked == true)
                }
                if selected.motionMode == .keyframes {
                    HStack(spacing: 12) {
                        Button("Previous keyframe", systemImage: "backward.end") { stepKeyframe(-1) }.labelStyle(.iconOnly)
                        Button("Add keyframe", systemImage: "diamond") { addKeyframe() }.accessibilityIdentifier("analysis-add-keyframe")
                        Button("Next keyframe", systemImage: "forward.end") { stepKeyframe(1) }.labelStyle(.iconOnly)
                        Spacer(minLength: 0)
                        Button("Delete keyframe", systemImage: "diamond.slash") { deleteKeyframe() }.labelStyle(.iconOnly).disabled(selectedKeyframe == nil)
                    }.buttonStyle(AnalysisControlStyle()).disabled(selected.isLocked == true || time < selected.start || time > selected.end)
                }
            }.padding(.horizontal, 10).background(Theme.inkPanel).disabled(trackingID != nil)
        }
    }

    @ViewBuilder private var inspectorStyle: some View {
        inspectorEffect
        inspectorAppearance
        inspectorMeasurements
    }

    @ViewBuilder private var inspectorMeasurements: some View {
        if let selected, selected.tool == .text || [.line, .arrow, .connection, .zone].contains(selected.tool) {
            Section("Measurements") {
                if selected.tool == .text {
                    Toggle("Show player speed · km/h", isOn: Binding(get: { self.selected?.showsSpeed == true }, set: { value in updateSelected { $0.showsSpeed = value } }))
                        .disabled(clip.freezeDuration != nil || selected.playerMotion == nil)
                } else if selected.fieldLines != true {
                    Toggle("Show distances · m", isOn: Binding(get: { self.selected?.showsDistance == true }, set: { value in updateSelected { $0.showsDistance = value } }))
                        .accessibilityIdentifier("analysis-show-distance")
                }
                Text(measurementStatus ?? "Set a known ground reference in Measure. Values stay unavailable without calibration.").font(.caption).foregroundStyle(.secondary)
            }.disabled(selected.isLocked == true)
        }
    }

    @ViewBuilder private var inspectorAppearance: some View {
        if selected?.isLocked == true {
            Section { Label("Unlock this layer in Layer settings to edit.", systemImage: "lock").foregroundStyle(.secondary) }
        }
        if selected?.tool == .text {
            Section("Text") {
                TextField("Annotation text", text: Binding(get: { selected?.text ?? "" }, set: { value in updateSelected { $0.text = value } }), axis: .vertical)
                    .lineLimit(2...5).accessibilityIdentifier("analysis-text-input")
                AnalysisTextControls(style: Binding(get: { selected?.resolvedTextStyle ?? .init() }, set: { value in
                    updateSelected(recordUndo: !editingTextSize) { $0.textStyle = value }
                }), sizeEditingChanged: { editing in
                    if editing { checkpoint() }
                    editingTextSize = editing
                })
            }.disabled(selected?.isLocked == true)
        }
        if selected?.tool != .zoom && selected?.tool != .loupe {
            Section("Appearance") {
                ColorPicker("Colour", selection: Binding(get: {
                    selected.map { Color(red: $0.color.red, green: $0.color.green, blue: $0.color.blue) } ?? color
                }, set: { value in color = value; updateSelected { $0.color = annotationColor } }), supportsOpacity: false)
                if selected?.tool != .text { VStack(alignment: .leading, spacing: 8) {
                    Text("Line width")
                    Slider(value: Binding(get: { selected?.width ?? width }, set: { value in
                        width = value; updateSelected(recordUndo: false) { $0.width = value }
                    }), in: 0.002...0.04, onEditingChanged: { if $0 { checkpoint() } })
                        .accessibilityLabel("Line width")
                } }
            }.disabled(selected?.isLocked == true)
        }
    }

    @ViewBuilder private var inspectorEffect: some View {
        if let selected {
            if [.line, .arrow, .pen, .connection, .zone, .rectangle, .ellipse].contains(selected.tool), selected.fieldLines != true {
                Section("Line style") {
                    AnalysisLineControls(mark: selected, style: { value in updateSelected(recordUndo: false) { $0.lineStyle = value } }, beginEdit: checkpoint)
                }
            }
            Section(selected.tool == .zoom ? "Zoom" : "Effect") {
                if selected.tool == .zoom {
                    AnalysisZoomControls(mark: selected,
                        amount: { value in updateSelected(recordUndo: false) { $0.zoomScale = value } },
                        ramp: { value in updateSelected(recordUndo: false) { $0.zoomRamp = value } }, beginEdit: checkpoint)
                } else if selected.tool == .loupe {
                    AnalysisLoupeControls(style: Binding(get: { self.selected?.loupeStyle ?? .init() }, set: { value in
                        updateSelected(recordUndo: false) { $0.loupeStyle = value }
                    }), beginEdit: checkpoint).disabled(selected.isLocked == true)
                } else if selected.tool == .trajectory {
                    AnalysisTrajectoryControls(style: Binding(get: { self.selected?.trajectoryStyle ?? .init() }, set: { value in updateSelected { $0.trajectoryStyle = value } }))
                        .disabled(selected.isLocked == true)
                    Text(selected.trajectoryCameraMotion == nil ? "Image-space trail. Add a camera track and use it to compensate for camera movement." : "Camera-compensated trail within saved camera coverage.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let camera = clip.trackingLibrary?.camera(at: time), selected.trajectoryCameraMotion == nil {
                        Button("Use saved camera for trail") { updateSelected { $0.trajectoryCameraMotion = camera } }
                    }
                } else {
                    AnalysisEffectControls(mark: selected, effect: { value in updateSelected { $0.effect = value } },
                        fill: { value in updateSelected(recordUndo: false) { $0.areaFill = value } },
                        wallHeight: { value in updateSelected(recordUndo: false) { $0.wallHeight = value } },
                        wallOpacity: { value in updateSelected(recordUndo: false) { $0.wallOpacity = value } },
                        hasGround: clip.groundCalibration?.mode == .plane && clip.groundCalibration?.valid == true,
                        groundAvailable: clip.groundCalibration?.frozen(at: time) != nil,
                        grounding: setGrounding,
                        metricHeight: { value in updateSelected(recordUndo: false) { $0.wallHeightMeters = value } }, beginEdit: checkpoint)
                }
            }
            if selected.playerMotion != nil || selected.linkedPlayers != nil {
                Section("Tracking") {
                    AnalysisTrackingSmoothingControls(mark: selected, amount: setTrackingSmoothing, beginEdit: checkpoint)
                    AnalysisTrackingBridgeControls(mark: selected, amount: setGapBridging, beginEdit: checkpoint)
                }
            }
        } else {
            Section("Players") { detectionControls }
            freezeControls
        }
    }

    private func setGrounding(_ enabled: Bool) {
        updateSelected { $0.setGrounding(enabled, at: time, ground: clip.groundCalibration) }
    }

    @ViewBuilder private var inspectorTiming: some View {
        if let selected {
            Section {
                LabeledContent("Duration", value: "\((selected.end - selected.start).formatted(.number.precision(.fractionLength(1)))) s")
                Stepper("Start  \((selected.start - clip.startSeconds).formatted(.number.precision(.fractionLength(1)))) s",
                        value: Binding(get: { self.selected?.start ?? selected.start }, set: { value in changeTiming { $0.start = value } }),
                        in: clip.startSeconds...max(clip.startSeconds, selected.end - 1 / 30), step: 0.1)
                    .accessibilityIdentifier("analysis-layer-in")
                Stepper("End  \((selected.end - clip.startSeconds).formatted(.number.precision(.fractionLength(1)))) s",
                        value: Binding(get: { self.selected?.end ?? selected.end }, set: { value in changeTiming { $0.end = value } }),
                        in: min(clip.annotationEnd, selected.start + 1 / 30)...clip.annotationEnd, step: 0.1)
                    .accessibilityIdentifier("analysis-layer-out")
            } header: { Text("On the timeline") } footer: {
                Text("Times are relative to this clip. Drag either edge on the timeline for larger changes.")
                if let first = selected.motionStart, selected.start < first - 0.05 {
                    Text("Orange marks frames without tracking. Re-track from an earlier frame, or choose Static for a fixed drawing.")
                }
            }.disabled(selected.isLocked == true)
            Section {
                Button("Start at playhead", systemImage: "arrow.right.to.line") {
                    changeTiming { $0.start = max(clip.startSeconds, min(time, $0.end - 1 / 30)) }
                }
                Button("End at playhead", systemImage: "arrow.left.to.line") {
                    changeTiming { $0.end = min(clip.annotationEnd, max(time, $0.start + 1 / 30)) }
                }
                Button("Use whole clip", systemImage: "arrow.left.and.right") {
                    changeTiming { $0.start = clip.startSeconds; $0.end = clip.annotationEnd }
                }
            }.disabled(selected.isLocked == true)
            if selected.tool != .zoom {
                Section {
                    Toggle("Fade in and out", isOn: Binding(get: { self.selected?.fade ?? false }, set: { value in updateSelected { $0.fade = value } }))
                }.disabled(selected.isLocked == true)
            }
            freezeControls
        }
    }

    @ViewBuilder private var inspectorLayer: some View {
        if let selected {
            if let id = selected.playerMotion?.trackID,
               let track = clip.trackingLibrary?.players.first(where: { $0.id == id }) {
                Section("Shared tracking") {
                    TextField("Track name", text: Binding(get: {
                        clip.trackingLibrary?.players.first(where: { $0.id == id })?.name ?? track.name
                    }, set: { value in
                        guard let index = clip.trackingLibrary?.players.firstIndex(where: { $0.id == id }) else { return }
                        checkpoint(); clip.trackingLibrary?.players[index].name = value
                    })).accessibilityIdentifier("analysis-track-name")
                    Text("Ring, spotlight and label reuse this track. Correcting its motion updates all attached layers.").font(.caption).foregroundStyle(.secondary)
                }
            } else if selected.cameraMotion?.trackID != nil {
                Section("Shared tracking") {
                    Text("Saved camera track")
                    Text("Other drawings can use this camera track without processing the video again.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Name") {
                TextField(selected.tool.title, text: Binding(get: { self.selected?.layerName ?? "" }, set: { value in updateSelected { $0.layerName = value } }))
                    .accessibilityIdentifier("analysis-layer-name").disabled(selected.isLocked == true)
            }
            Section {
                Toggle("Visible", isOn: Binding(get: { self.selected?.isHidden != true }, set: { _ in toggleLayerHidden(selected.id) }))
                Toggle("Lock layer", isOn: Binding(get: { self.selected?.isLocked == true }, set: { _ in toggleLayerLocked(selected.id) }))
                Button("Duplicate layer", systemImage: "plus.square.on.square", action: duplicate)
            }
            Section {
                Button("Delete layer", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    .disabled(selected.isLocked == true)
            }.confirmationDialog("Delete this layer?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete layer", role: .destructive) {
                    checkpoint(); clip.annotations.removeAll { $0.id == selectedID }; showProperties = false; selectedID = nil
                }
            }
        }
    }

    @ViewBuilder private var freezeControls: some View {
        if clip.freezeDuration != nil {
            Section("Freeze frame") {
                Stepper("Hold: \((clip.freezeDuration ?? 5).formatted()) seconds", value: Binding(get: { clip.freezeDuration ?? 5 }, set: { value in
                    let oldEnd = clip.annotationEnd; clip.freezeDuration = value
                    for index in clip.annotations.indices where clip.annotations[index].end >= oldEnd - 0.01 { clip.annotations[index].end = clip.annotationEnd }
                    freezeTime = min(freezeTime, clip.annotationEnd)
                }), in: 1...30, step: 1)
            }
        }
    }

    private var detectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.isRunning {
                ProgressView(value: session.progress ?? 0)
                HStack { Text("Finding players…"); Spacer(); Button("Cancel") { session.cancel() } }.font(.caption)
            } else {
                HStack {
                    Button("Find players") { detect(motion: false) }
                }.font(.caption).buttonStyle(.bordered).accessibilityIdentifier("detect-analysis-players")
                Text(detections.isEmpty ? "Use Player to draw around someone if detection misses them." : "Tap a player, then open Player effects to combine a ring, spotlight and label.")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Show detected players", isOn: $showsPlayers).font(.caption)
            }
        }
    }

    private var annotationColor: AnnotationColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return .init(red: r, green: g, blue: b)
    }

    private var constructionPreview: [AnalysisAnnotation] {
        guard !constructionPoints.isEmpty else { return [] }
        var mark = AnalysisAnnotation(id: constructionID, tool: tool, points: constructionPoints, color: annotationColor, width: width, start: time, end: time + 1)
        mark.effect = .neon
        return [mark]
    }

    @ViewBuilder private var constructionControls: some View {
        if tool == .connection || tool == .zone {
            HStack(spacing: 12) {
                if tool == .zone {
                    Toggle("Players", isOn: $areaUsesPlayers).font(.caption).fixedSize()
                        .onChange(of: areaUsesPlayers) { constructionPoints = []; constructionPlayers = []; detect(motion: false) }
                }
                Text("\(constructionPoints.count) \(tool == .connection || areaUsesPlayers ? "player" : "corner")\(constructionPoints.count == 1 ? "" : "s")").font(.caption)
                    .accessibilityIdentifier("analysis-construction-count")
                Spacer(minLength: 0)
                Button("Remove last point", systemImage: "arrow.uturn.backward") {
                    if !constructionPoints.isEmpty { constructionPoints.removeLast() }
                    if !constructionPlayers.isEmpty { constructionPlayers.removeLast() }
                }.labelStyle(.iconOnly).disabled(constructionPoints.isEmpty)
                Button("Finish", action: finishConstruction).bold()
                    .disabled(constructionPoints.count < (tool == .zone ? 3 : 2))
                    .accessibilityIdentifier("analysis-finish-construction")
            }.padding(.horizontal, 12).frame(height: 40).background(Theme.inkPanel)
        }
    }

    private func finishConstruction() {
        var mark = AnalysisAnnotation(tool: tool, points: constructionPoints, color: annotationColor, width: width,
                                      start: clip.startSeconds, end: clip.annotationEnd)
        mark.effect = .neon
        let seeds = constructionPlayers
        constructionPoints = []; constructionPlayers = []; constructionID = UUID()
        selectedPlayer = nil
        insertMark(mark)
        if !seeds.isEmpty, clip.freezeDuration == nil { beginLinkedTracking(id: mark.id, seeds: seeds) }
    }
    private func appendConstructionPlayer(_ box: CGRect) {
        guard constructionPoints.count < 12, !constructionPlayers.contains(where: { PlayerTracker.overlap($0.box, box) > 0.7 }) else { return }
        constructionPlayers.append(.init(time: time, box: box))
        constructionPoints.append(.init(x: box.midX, y: box.maxY))
    }

    private func handleCanvasTouch(_ action: FieldPlacementTouchState.Action, frame: CGRect, fitted: CGRect) {
        switch action {
        case .beginCorner(let location):
            canvasTouch = (location, location, frame, time, !playback.isSeeking); canvasDragging = false
        case .moveCorner(let location):
            guard let touch = canvasTouch else { return }
            canvasTouch?.current = location
            if hypot(location.x - touch.start.x, location.y - touch.start.y) >= (pickingPlayerTrack ? PlayerFrameReview.selectionDragDistance : 3) { canvasDragging = true }
            if canvasDragging { changeCanvasDrawing(startLocation: touch.start, location: location, frame: touch.frame) }
        case .endCorner:
            if let touch = canvasTouch {
                if pickingPlayerTrack, (!touch.ready || abs(touch.time - time) > 0.5 / sourceFrameRate) {
                    canvasTouch = nil; canvasDragging = false; draft = nil; dragFrame = nil; return
                }
                if canvasDragging { endCanvasDrawing(startLocation: touch.start, location: touch.current, frame: touch.frame) }
                else { tapCanvas(touch.current, frame: touch.frame) }
            }
            canvasTouch = nil; canvasDragging = false
        case .cancelCorner:
            canvasTouch = nil; canvasDragging = false
            draft = nil; dragOriginal = nil; dragVertex = nil; dragFrame = nil
        case .beginNavigation:
            playback.pause()
            canvasNavigation = FieldPlacementViewport(zoom: canvasZoom, center: zoomCenter)
        case .navigate(let scale, let from, let to):
            guard let canvasNavigation else { return }
            let viewport = canvasNavigation.navigating(scale: scale, from: from, to: to, fitted: fitted)
            canvasZoom = viewport.zoom; zoomCenter = viewport.center
        case .endNavigation: canvasNavigation = nil
        }
    }

    private func changeCanvasDrawing(startLocation: CGPoint, location: CGPoint, frame: CGRect) {
        guard initialised, trackingID == nil, frame.contains(startLocation) || editsOffscreenField else { return }
        if dragFrame == nil { dragFrame = frame }
        playback.pause()
        let start = normalise(startLocation, frame: frame)
        let point = normalise(location, frame: frame)
        if tool == .connection || tool == .zone { return }
        if correctingPlayer || pickingPlayerTrack {
            guard !playback.isSeeking else { return }
            draft = AnalysisAnnotation(tool: .rectangle, points: [start, point], start: time, end: clip.annotationEnd)
            return
        }
        if tool == .select {
            if dragOriginal == nil {
                let handle = selected.flatMap { handleIndex($0, at: startLocation, frame: frame) }
                if handle == nil { selectedID = hit(start)?.id }
                dragOriginal = selected
                dragVertex = selected.flatMap { handleIndex($0, at: startLocation, frame: frame) }
                selectedVertex = dragVertex
            }
            if var preview = dragOriginal {
                preview.points = preview.reshaped(at: time, handle: dragVertex, delta: CGSize(width: point.x - start.x, height: point.y - start.y), ground: clip.groundCalibration)
                preview.keyframes = []; preview.playerMotion = nil; preview.linkedPlayers = nil; preview.cameraMotion = nil; draft = preview
            }
            return
        }
        if draft == nil {
            draft = AnalysisAnnotation(tool: tool, points: [start], color: annotationColor, width: width, text: tool == .text ? "Text" : "", start: min(time, clip.annotationEnd - 0.05), end: min(clip.annotationEnd, time + 4))
        }
        if tool == .pen { draft?.points.append(point) }
        else { draft?.points = tool == .zoom || tool == .loupe ? [point] : [start, point] }
    }

    private func endCanvasDrawing(startLocation: CGPoint, location: CGPoint, frame: CGRect) {
        defer { draft = nil; dragOriginal = nil; dragVertex = nil; dragFrame = nil }
        guard initialised, trackingID == nil, frame.contains(startLocation) || editsOffscreenField else { return }
        let start = normalise(startLocation, frame: frame)
        let end = normalise(location, frame: frame)
        if pickingPlayerTrack {
            guard !playback.isSeeking, draft != nil else { return }
            let seed = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard seed.width > 0.003, seed.height > 0.01 else {
                tapCanvas(startLocation, frame: frame); return
            }
            trackIndependentPlayer(seed: seed)
            return
        }
        if correctingPlayer, let id = selectedID {
            let seed = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard seed.width > 0.003, seed.height > 0.01 else { return }
            if selected?.linkedPlayers != nil { selectPlayer(seed); return }
            checkpoint(); correctingPlayer = false; selectedPlayer = .init(time: time, box: seed)
            beginTracking(id: id, seed: seed, from: time, confirmedSeed: true)
            return
        }
        if tool == .select, let original = dragOriginal {
            let dx = end.x - start.x, dy = end.y - start.y
            guard abs(dx) + abs(dy) > 0.002 else { return }
            updateSelected { mark in
                let moved = original.reshaped(at: time, handle: dragVertex, delta: CGSize(width: dx, height: dy), ground: clip.groundCalibration)
                mark.moveDrawing(to: moved, at: time)
            }
            return
        }
        guard tool != .select, var mark = draft else { return }
        if tool == .text { mark.points = [start] }
        if tool == .player || tool == .spotlight {
            if let player = detections.filter({ $0.rect.insetBy(dx: -0.015, dy: -0.015).contains(start) }).min(by: { $0.rect.width < $1.rect.width }) {
                mark.points = [player.rect.origin, CGPoint(x: player.rect.maxX, y: player.rect.maxY)]
            } else if hypot(end.x - start.x, end.y - start.y) < 0.015 {
                mark.points = [CGPoint(x: start.x - 0.022, y: start.y - 0.10), CGPoint(x: start.x + 0.022, y: start.y)]
            }
        }
        if tool == .player, let first = mark.points.first, let last = mark.points.last {
            selectPlayer(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
            return
        }
        insertMark(mark)
    }

    private var editsOffscreenField: Bool { tool == .select && selected?.fieldLines == true && !correctingPlayer && !pickingPlayerTrack }
    private func normalise(_ point: CGPoint, frame: CGRect) -> CGPoint {
        AnnotationViewport.sourcePoint(point, frame: frame, allowsOffscreen: editsOffscreenField)
    }
    private func handleIndex(_ mark: AnalysisAnnotation, at point: CGPoint, frame: CGRect) -> Int? {
        guard mark.isLocked != true, mark.isHidden != true, time >= mark.start, time <= mark.end, mark.hasMotion(at: time) else { return nil }
        return mark.editHandles(at: time, ground: clip.groundCalibration).enumerated().map { index, handle in
            (index, hypot(frame.minX + handle.x * frame.width - point.x, frame.minY + handle.y * frame.height - point.y))
        }.min { $0.1 < $1.1 }.flatMap { $0.1 <= 22 ? $0.0 : nil }
    }
    private func tapCanvas(_ location: CGPoint, frame: CGRect) {
        guard initialised, trackingID == nil, frame.contains(location) || editsOffscreenField else { return }
        playback.pause()
        let point = normalise(location, frame: frame)
        if pickingPlayerTrack {
            guard !playback.isSeeking else { return }
            if let box = player(at: point) { trackIndependentPlayer(seed: box) }
            else if reviewingFrames, let reference = reviewBox {
                // The user supplies the centre; a drag supplies a new body size.
                let box = CGRect(x: point.x - reference.width / 2, y: point.y - reference.height / 2,
                                 width: reference.width, height: reference.height)
                trackIndependentPlayer(seed: box)
            } else { error = "Draw a box around the full player when no detection is available." }
            return
        }
        if tool == .zone || tool == .connection {
            guard constructionPoints.count < 12 else { return }
            if tool == .connection || areaUsesPlayers {
                guard let box = player(at: point) else { error = "Tap a detected player. If the player is missing, use Find players at this frame first."; return }
                appendConstructionPlayer(box)
            } else { constructionPoints.append(point) }
            return
        }
        if tool == .select {
            if !correctingPlayer, let selected, let vertex = handleIndex(selected, at: location, frame: frame) {
                selectedVertex = vertex
            } else if !correctingPlayer, let mark = hit(point) {
                selectedID = mark.id
                selectedPlayer = (mark.playerMotion?.box(at: time) ?? (mark.playerMotion == nil ? mark.playerEffectBox : nil)).map { .init(time: time, box: $0) }
                selectedPlayerTrackID = mark.playerMotion?.trackID
            } else if let player = player(at: point) {
                selectPlayer(player)
            } else if !correctingPlayer { selectedID = nil; selectedPlayer = nil }
            return
        }
        guard [.text, .player, .spotlight, .pen, .zoom, .loupe].contains(tool) else { return }
        var mark = AnalysisAnnotation(tool: tool, points: [point], color: annotationColor, width: width, text: tool == .text ? "Text" : "", start: min(time, clip.annotationEnd - 0.05), end: min(clip.annotationEnd, time + 4))
        if tool == .loupe {
            selectedPlayer = player(at: point).map { .init(time: time, box: $0) }
        }
        if tool == .player || tool == .spotlight {
            if let player = detections.filter({ $0.rect.insetBy(dx: -0.015, dy: -0.015).contains(point) }).min(by: { $0.rect.width < $1.rect.width }) {
                mark.points = [player.rect.origin, CGPoint(x: player.rect.maxX, y: player.rect.maxY)]
            } else { mark.points = [CGPoint(x: point.x - 0.022, y: point.y - 0.10), CGPoint(x: point.x + 0.022, y: point.y)] }
        }
        if tool == .player, let first = mark.points.first, let last = mark.points.last {
            selectPlayer(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
            return
        }
        insertMark(mark)
    }
    private func hit(_ point: CGPoint) -> AnalysisAnnotation? {
        clip.annotations.reversed().first { mark in
            guard mark.isHidden != true, mark.isLocked != true, time >= mark.start, time <= mark.end,
                  mark.hasMotion(at: time) else { return false }
            let points = mark.shapeBoundary(at: time, ground: clip.groundCalibration)
            guard let first = points.first else { return false }
            if mark.tool == .text {
                let bounds = AnnotationTextLayout(mark: mark, frameWidth: 1000).bounds
                return CGRect(x: first.x + bounds.minX / 1000, y: first.y + bounds.minY * displayAspect / 1000,
                              width: bounds.width / 1000, height: bounds.height * displayAspect / 1000).insetBy(dx: -0.015, dy: -0.015).contains(point)
            }
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0)).insetBy(dx: -0.025, dy: -0.025).contains(point)
        }
    }
    private func select(_ mark: AnalysisAnnotation) {
        pickingPlayerTrack = false; correctingTrackID = nil
        constructionPoints = []; constructionPlayers = []
        selectedID = mark.id; tool = .select
        if time < mark.start || time >= mark.end { seek(min(clip.annotationEnd - 0.02, max(clip.startSeconds, mark.start))) }
        selectedPlayer = (mark.playerMotion?.box(at: time) ?? (mark.playerMotion == nil ? mark.playerEffectBox : nil)).map { .init(time: time, box: $0) }
        selectedPlayerTrackID = mark.playerMotion?.trackID
    }
    private func checkpoint() { undo.append(clip); if undo.count > 60 { undo.removeFirst() }; redo = [] }
    private func undoEdit() {
        guard let previous = undo.popLast() else { return }
        redo.append(clip); clip = previous; selectedID = nil
        if reviewingFrames {
            if let previousTime = reviewUndoTimes.popLast() {
                seek(previousTime)
                reviewBox = clip.trackingLibrary?.players.first(where: { $0.id == correctingTrackID })?.motion
                    .samples.min(by: { abs($0.time - previousTime) < abs($1.time - previousTime) })?.box
            } else { endFrameReview() }
        }
    }
    private func redoEdit() { guard let next = redo.popLast() else { return }; if reviewingFrames { endFrameReview() }; undo.append(clip); clip = next; selectedID = nil }
    private func updateSelected(recordUndo: Bool = true, _ change: (inout AnalysisAnnotation) -> Void) {
        guard let index = clip.annotations.firstIndex(where: { $0.id == selectedID }), clip.annotations[index].isLocked != true else { return }
        if recordUndo { checkpoint() }; change(&clip.annotations[index])
    }
    private func changeTiming(_ change: (inout AnalysisAnnotation) -> Void) {
        updateSelected(change)
        if let mark = selected, mark.linkedPlayers != nil || mark.cameraMotion != nil {
            if let mark = selected { editTimelineLayer(mark, finished: true) }
            return
        }
        guard let mark = selected, let motion = mark.playerMotion else { return }
        if motion.lostAt == nil, let last = motion.samples.last, mark.end > last.time + 0.12 {
            beginTracking(id: mark.id, seed: last.box, from: last.time)
        }
    }
    private func selectTimelineLayer(_ id: UUID, at seconds: Double?) {
        guard let mark = clip.annotations.first(where: { $0.id == id }) else { return }
        playback.pause(); selectedKeyframe = nil; correctingPlayer = false; select(mark)
        if let seconds { seek(seconds) }
    }
    private func editTimelineLayer(_ mark: AnalysisAnnotation, finished: Bool) {
        guard let index = clip.annotations.firstIndex(where: { $0.id == mark.id }) else { return }
        let previous = clip.annotations[index]
        clip.annotations[index] = mark
        if let keyframe = mark.keyframes.first(where: { $0.id == selectedKeyframe }),
           previous.keyframes.first(where: { $0.id == keyframe.id })?.time != keyframe.time { seek(keyframe.time) }
        if finished, let links = mark.linkedPlayers, links.allSatisfy({ $0.lostAt == nil }),
           links.contains(where: { ($0.samples.last?.time ?? mark.start) < mark.end - 0.12 }) {
            beginLinkedTracking(id: mark.id, seeds: links.compactMap(\.samples.last)); return
        }
        if finished, let camera = mark.cameraMotion, camera.lostAt == nil, (camera.samples.last?.time ?? mark.start) < mark.end - 0.15 {
            beginCameraTracking(fromCurrentFrame: false); return
        }
        guard finished, let motion = mark.playerMotion, motion.lostAt == nil,
              let last = motion.samples.last, mark.end > last.time + 0.12 else { return }
        beginTracking(id: mark.id, seed: last.box, from: last.time)
    }
    private func selectTimelineKeyframe(_ layer: UUID, _ frame: UUID, _ seconds: Double) {
        pickingPlayerTrack = false; correctingTrackID = nil
        constructionPoints = []; constructionPlayers = []
        playback.pause(); selectedID = layer; selectedKeyframe = frame; tool = .select; seek(seconds)
    }
    private func setMotionMode(_ mode: AnnotationMotionMode) {
        guard let mark = selected, mark.isLocked != true else { return }
        playback.pause(); tool = .select; selectedKeyframe = nil
        switch mode {
        case .still:
            correctingPlayer = false; updateSelected { $0.makeStatic(at: time) }; selectedPlayer = nil
        case .keyframes:
            correctingPlayer = false; updateSelected { $0.enableKeyframes(at: time) }; selectedPlayer = nil
        case .player:
            guard clip.freezeDuration == nil else { return }
            if mark.linkedPlayers != nil { correctingAnchor = correctingAnchor ?? 0; correctingPlayer = true; return }
            playerPickerLayerID = mark.id; showPlayerTracks = true
        case .camera:
            beginCameraTracking()
        }
    }
    private func addKeyframe() {
        guard let selected, time >= selected.start, time <= selected.end else { return }
        playback.pause()
        updateSelected { $0.setKeyframe(at: time, points: $0.points(at: time)) }
        selectedKeyframe = self.selected?.keyframes.first(where: { abs($0.time - time) < 1 / 60 })?.id
    }
    private func deleteKeyframe() {
        guard let id = selectedKeyframe else { return }
        updateSelected { mark in
            let position = mark.points(at: time)
            mark.keyframes.removeAll { $0.id == id }
            if mark.keyframes.isEmpty { mark.points = position }
        }
        selectedKeyframe = nil
    }
    private func stepKeyframe(_ direction: Int) {
        guard let selected else { return }
        let frame = direction < 0 ? selected.keyframes.last(where: { $0.time < time - 0.02 }) : selected.keyframes.first(where: { $0.time > time + 0.02 })
        if let frame { selectTimelineKeyframe(selected.id, frame.id, frame.time) }
    }
    private func toggleLayerHidden(_ id: UUID) {
        guard let index = clip.annotations.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(); clip.annotations[index].isHidden = clip.annotations[index].isHidden != true
    }
    private func toggleLayerLocked(_ id: UUID) {
        guard let index = clip.annotations.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(); clip.annotations[index].isLocked = clip.annotations[index].isLocked != true
    }
    private func reorderLayer(_ id: UUID, _ direction: Int) {
        guard let index = clip.annotations.firstIndex(where: { $0.id == id }), clip.annotations[index].isLocked != true else { return }
        let destination = min(clip.annotations.count - 1, max(0, index + direction))
        guard destination != index else { return }
        checkpoint(); clip.annotations.swapAt(index, destination)
    }
    private func duplicate() {
        guard var mark = selected else { return }; checkpoint(); mark.id = UUID()
        mark.points = mark.points.map { CGPoint(x: $0.x + 0.025, y: $0.y + 0.025) }
        mark.keyframes = mark.keyframes.map { .init(time: $0.time, points: $0.points.map { CGPoint(x: $0.x + 0.025, y: $0.y + 0.025) }) }
        clip.annotations.append(mark); selectedID = mark.id
    }
    private func seek(_ value: Double) {
        let bounded = min(clip.annotationEnd, max(clip.startSeconds, value))
        if clip.freezeDuration != nil { freezeTime = bounded } else { playback.commitSeek(bounded) }
    }
    private func previewSeek(_ value: Double) {
        let bounded = min(clip.annotationEnd, max(clip.startSeconds, value))
        if clip.freezeDuration != nil { freezeTime = bounded } else { playback.previewSeek(bounded) }
    }
    private func setTrackingSmoothing(_ value: Double) {
        updateSelected(recordUndo: false) { mark in
            mark.playerMotion?.smoothing = value
            if let links = mark.linkedPlayers {
                mark.linkedPlayers = links.map { var motion = $0; motion.smoothing = value; return motion }
            }
        }
    }
    private func detect(motion: Bool) {
        let start = max(clip.startSeconds, detectionTime - 0.05)
        let end = min(request.recording.duration, motion ? detectionTime + 6 : detectionTime + 0.1)
        if end > start { session.analyze(recording: request.recording, range: start...end) }
    }
    private func player(at point: CGPoint) -> CGRect? {
        PlayerSelection.box(at: point, among: detections.map(\.rect), aspectRatio: displayAspect)
    }
    private func selectPlayer(_ box: CGRect) {
        if pickingPlayerTrack { guard !playback.isSeeking else { return }; trackIndependentPlayer(seed: box); return }
        playback.pause(); selectedPlayer = .init(time: time, box: box)
        selectedPlayerTrackID = clip.trackingLibrary?.player(matching: box, at: time)?.id
        if tool == .player, !correctingPlayer {
            selectedID = nil; tool = .select; showPlayerEffects = true
            return
        }
        if correctingPlayer, let id = selectedID {
            if let mark = selected, let links = mark.linkedPlayers {
                let closest = correctingAnchor ?? links.enumerated().min { a, b in
                    let lhs = a.element.box(at: time) ?? a.element.samples.last?.box ?? .zero
                    let rhs = b.element.box(at: time) ?? b.element.samples.last?.box ?? .zero
                    return hypot(lhs.midX - box.midX, lhs.maxY - box.maxY) < hypot(rhs.midX - box.midX, rhs.maxY - box.maxY)
                }?.offset
                if let closest { correctingPlayer = false; correctingAnchor = nil; beginLinkedTracking(id: id, seeds: [.init(time: time, box: box)], replacing: closest) }
                return
            }
            checkpoint(); correctingPlayer = false
            if selected?.playerMotion == nil { attachOrTrack(id: id, seed: box) }
            else { beginTracking(id: id, seed: box, from: time, confirmedSeed: true) }
        } else if let mark = hit(CGPoint(x: box.midX, y: box.midY)) {
            selectedID = mark.id
        } else { selectedID = nil }
    }
    private func chooseTool(_ item: AnalysisDrawingTool) {
        playback.pause()
        endFrameReview()
        canvasNavigation = nil
        correctingPlayer = false
        constructionPoints = []; constructionPlayers = []
        if item == .zoom { selectedID = nil; selectedPlayer = nil; canvasZoom = 1; zoomCenter = CGPoint(x: 0.5, y: 0.5) }
        if item == .zone || item == .connection {
            selectedID = nil; selectedPlayer = nil; tool = item
            if analysis?.frame(at: detectionTime) == nil { detect(motion: false) }
            return
        }
        if item == .player, selectedPlayer != nil { showPlayerEffects = true; return }
        if item == .text || item == .player || item == .loupe { selectedID = nil; selectedPlayer = nil; selectedPlayerTrackID = nil }
        tool = item
    }

    private func applyPlayerEffects(_ options: AnalysisPlayerEffects) {
        guard let player = selectedPlayer, trackingID == nil else { return }
        let saved = reusablePlayer(box: player.box, at: time)
        if clip.freezeDuration == nil, saved == nil, !options.tools.isEmpty {
            trackIndependentPlayer(seed: player.box, effects: options)
        } else {
            checkpoint()
            selectedID = clip.applyPlayerEffects(options, replacing: Set(playerEffectLayers.map(\.id)),
                                                 box: player.box, motion: saved?.motion, at: time)
            selectedPlayerTrackID = saved?.id; tool = .select
        }
    }
    private func insertMark(_ mark: AnalysisAnnotation) {
        var mark = mark
        if mark.tool == .zoom { mark.zoomScale = 2; mark.zoomRamp = 0.35; selectedPlayer = nil }
        if mark.tool == .player, mark.effect == nil { mark.effect = .radar }
        if mark.tool == .loupe { mark.loupeStyle = mark.loupeStyle ?? .init() }
        checkpoint(); clip.annotations.append(mark); selectedID = mark.id; tool = .select
        if mark.tool == .text { showProperties = true }
        if mark.tool == .zoom { showProperties = true; return }
        if mark.tool == .loupe, selectedPlayer == nil { showProperties = true }
        guard clip.freezeDuration == nil, mark.playerMotion == nil else { return }
        if [.player, .spotlight].contains(mark.tool), let first = mark.points.first, let last = mark.points.last {
            let seed = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            selectedPlayer = .init(time: time, box: seed)
            attachOrTrack(id: mark.id, seed: seed)
        } else if let player = selectedPlayer { attachOrTrack(id: mark.id, seed: player.box) }
    }

    private func reusablePlayer(box: CGRect, at seconds: Double) -> AnalysisTrackingLibrary.Player? {
        if let id = selectedPlayerTrackID,
           let track = clip.trackingLibrary?.players.first(where: { $0.id == id }),
           let current = track.motion.box(at: seconds), PlayerTracker.overlap(current, box) > 0.5 { return track }
        return clip.trackingLibrary?.player(matching: box, at: seconds)
    }

    private func attachOrTrack(id: UUID, seed: CGRect) {
        if let saved = reusablePlayer(box: seed, at: time), let index = clip.annotations.firstIndex(where: { $0.id == id }) {
            clip.annotations[index].makeStatic(at: time)
            clip.annotations[index].playerMotion = saved.motion.bound(at: time, smoothing: clip.annotations[index].tool == .text ? 0.95 : nil)
            selectedPlayerTrackID = saved.id
        } else { beginTracking(id: id, seed: seed, from: time, confirmedSeed: true) }
    }

    private func selectSavedPlayer(_ player: AnalysisTrackingLibrary.Player) {
        let selectionTime = player.motion.box(at: time) != nil ? time : player.motion.samples.first?.time ?? time
        guard let box = player.motion.box(at: selectionTime) else { return }
        pickingPlayerTrack = false; correctingTrackID = nil; correctingPlayer = false
        canvasNavigation = nil; constructionPoints = []; constructionPlayers = []
        if selectionTime != time { seek(selectionTime) }
        playback.pause(); selectedID = nil; tool = .select
        selectedPlayer = .init(time: selectionTime, box: box); selectedPlayerTrackID = player.id
    }

    private func pickLayerPlayer() {
        playerPickerLayerID = nil
        guard let selected, selected.isLocked != true else { return }
        playback.pause(); tool = .select; correctingPlayer = true; showsPlayers = true
        if time < selected.start || time >= selected.end { seek(selected.start) }
        detect(motion: false)
    }

    private func chooseSavedPlayer(_ player: AnalysisTrackingLibrary.Player) {
        guard let id = playerPickerLayerID, let mark = clip.annotations.first(where: { $0.id == id }) else {
            selectSavedPlayer(player); return
        }
        let available = player.motion.samples.filter { $0.time >= mark.start && $0.time <= mark.end && player.motion.box(at: $0.time) != nil }
        guard let nearest = available.min(by: { abs($0.time-time) < abs($1.time-time) }) else {
            error = "This player has no tracking inside this layer’s time range."; return
        }
        let bindTime = player.motion.box(at: time) != nil && time >= mark.start && time <= mark.end ? time : nearest.time
        checkpoint()
        guard clip.followSavedPlayer(player, layerID: id, at: bindTime) else { return }
        selectedID = id; selectedPlayerTrackID = player.id
        selectedPlayer = .init(time: bindTime, box: player.motion.box(at: bindTime)!)
        correctingPlayer = false; pickingPlayerTrack = false; tool = .select; seek(bindTime)
    }

    private func renamePlayerTrack(_ id: UUID, name: String) {
        guard let index = clip.trackingLibrary?.players.firstIndex(where: { $0.id == id }),
              clip.trackingLibrary?.players[index].name != name else { return }
        checkpoint(); clip.trackingLibrary?.players[index].name = name
    }

    private func assignPlayerTeam(_ id: UUID, team: PlayerTrackingTeam) {
        guard let player = clip.trackingLibrary?.players.first(where: { $0.id == id }), player.assignedTeam != team else { return }
        checkpoint(); clip.assignPlayerTeam(team, to: id)
    }

    private func linkPlayerTrack(_ source: UUID, into target: UUID) {
        guard clip.trackingLibrary?.canLinkPlayer(source, to: target) == true else { return }
        checkpoint()
        guard clip.linkPlayerTrack(source, to: target) else { return }
        if selectedPlayerTrackID == source { selectedPlayerTrackID = target }
    }

    private func pickPlayerTrack(correcting id: UUID? = nil, direction: PlayerTrackingDirection = .forward, wholeClip: Bool = false) {
        guard clip.freezeDuration == nil, trackingID == nil else { return }
        playback.pause(); selectedID = nil; selectedPlayer = nil; selectedPlayerTrackID = nil
        tool = .select; correctingPlayer = false; constructionPoints = []; constructionPlayers = []
        canvasNavigation = nil; showsPlayers = true
        correctingTrackID = id; pickingPlayerTrack = true; placingPlayer = false; reviewingFrames = false
        pickedDirection = direction; pickedWholeClip = wholeClip; referenceView = nil
        pickedReplacementRange = nil
        detect(motion: false)
    }

    /// Fix an untracked frame by hand: the next pick becomes a placement in the
    /// saved track, with no tracking pass and no change to other players.
    private func beginPlacing(_ id: UUID, review: Bool = false) {
        guard clip.freezeDuration == nil, trackingID == nil else { return }
        playback.pause(); selectedID = nil; selectedPlayer = nil; selectedPlayerTrackID = id
        tool = .select; correctingPlayer = false; constructionPoints = []; constructionPlayers = []
        canvasNavigation = nil; showsPlayers = true
        correctingTrackID = id; pickingPlayerTrack = true; placingPlayer = true
        reviewingFrames = review; reviewUndoTimes = []; referenceView = nil
        pickedReplacementRange = nil
        if review { seek(max(clip.startSeconds, floor(time * sourceFrameRate + 0.0001) / sourceFrameRate)) }
        reviewBox = clip.trackingLibrary?.players.first(where: { $0.id == id })?.motion.samples
            .min(by: { abs($0.time - time) < abs($1.time - time) })?.box
        detect(motion: false)
    }

    private func placeSelectedPlayer(_ id: UUID, seed: CGRect) {
        guard !playback.isSeeking, seed.width > 0.003, seed.height > 0.01 else { return }
        checkpoint()
        guard clip.placePlayerSample(trackID: id, box: seed, at: time) else { return }
        selectedPlayerTrackID = id
        selectedPlayer = .init(time: time, box: seed)
        if reviewingFrames {
            reviewBox = seed; reviewUndoTimes.append(time)
            if reviewUndoTimes.count > 60 { reviewUndoTimes.removeFirst() }
            if let next = frameReview.next(after: time) { seek(next) }
        } else {
            pickingPlayerTrack = false; correctingTrackID = nil; placingPlayer = false
        }
    }

    private func removePlayerTrack(_ id: UUID) {
        guard clip.canRemovePlayerTrack(id) else { return }
        checkpoint()
        _ = clip.removePlayerTrack(id)
        if selectedPlayerTrackID == id { selectedPlayerTrackID = nil; selectedPlayer = nil }
    }

    private func setGapBridging(_ value: Double) {
        guard let id = selectedID else { return }
        clip.setGapBridging(value, layerID: id)
    }

    /// One shared pass follows everyone in the clip. Saved players are handed
    /// in as identity memory; bodies the pass discovers become new players.
    /// Offer the plausible bodies for this player after the point tracking gave
    /// up, so one tap puts the track back on him.
    ///
    /// The search only ranks; it never decides. Everything it can measure —
    /// kit colour, tone, appearance embeddings — describes the strip rather than
    /// the person, so against a team in one kit it can narrow the field and no
    /// more. The person watching settles it instantly.
    private func findPlayerAgain(_ id: UUID) {
        guard trackingID == nil, clip.freezeDuration == nil,
              let player = clip.trackingLibrary?.players.first(where: { $0.id == id }),
              let identity = player.identity, identity.isConfirmed else { return }
        let motion = player.motion
        // Start just after the last frame he was actually seen.
        let lastSeen = motion.lostAt ?? motion.samples.last?.time ?? clip.startSeconds
        let from = min(clip.endSeconds - 0.2, max(clip.startSeconds, lastSeen + 0.2))
        guard from < clip.endSeconds - 0.2 else { return }

        playback.pause()
        reacquisitionTask?.cancel()
        reacquisitionCandidates = []
        reacquisitionProgress = 0
        reacquisitionSearching = true
        reacquisitionFrom = from
        reacquiring = player
        let url = request.recording.fileURL, end = clip.endSeconds
        reacquisitionTask = Task { @MainActor in
            defer { reacquisitionSearching = false; reacquisitionTask = nil }
            do {
                let report: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in
                        if Int(reacquisitionProgress * 100) != Int(fraction * 100) { reacquisitionProgress = fraction }
                    }
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try await PlayerReacquisitionSearch.candidates(
                        url: url, from: from, to: end, memory: identity, progress: report)
                }
                let found = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard reacquiring?.id == id else { return }
                reacquisitionCandidates = found
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    /// The user picked a body. Resume tracking from that frame, splicing onto
    /// everything already confirmed before the gap.
    private func confirmReacquisition(_ id: UUID, candidate: PlayerReacquisitionCandidate) {
        reacquisitionTask?.cancel(); reacquisitionTask = nil
        reacquiring = nil
        guard let player = clip.trackingLibrary?.players.first(where: { $0.id == id }) else { return }
        var motion = player.motion
        motion.identity = player.identity
        // The user's choice is ground truth, exactly like a manual correction,
        // so the terminal loss is cleared rather than tracked around.
        motion.lostAt = nil
        checkpoint()
        seek(candidate.time)
        selectedPlayerTrackID = id
        selectedPlayer = .init(time: candidate.time, box: candidate.box)
        runPlayerTracking(id: id, seed: candidate.box, from: candidate.time, to: clip.endSeconds,
                          direction: .forward, prior: motion, includeBodyMasks: includeBodyMasks)
    }

    private func trackAllPlayers() {
        guard clip.freezeDuration == nil, trackingID == nil, clip.endSeconds - clip.startSeconds > 0.2 else { return }
        let start = clip.startSeconds, end = clip.endSeconds, url = request.recording.fileURL
        let priors = (clip.trackingLibrary?.players ?? []).map { PlayerRosterPrior(id: $0.id, motion: $0.motion, memory: $0.identity) }
        // Camera-relative memory needs the clip camera; run that pass first
        // when it is missing, so the roster never inherits a pan as motion.
        let existingCamera = clip.hasFullCameraTrack ? clip.trackingLibrary?.sharedCamera : nil
        let cameraRange = clip.cameraTrackingRange
        pickingPlayerTrack = false; correctingTrackID = nil; placingPlayer = false; correctingPlayer = false
        trackingTask?.cancel(); session.cancel(); playback.pause()
        selectedID = nil; selectedPlayer = nil; tool = .select
        let job = UUID()
        trackingID = job; trackingJob = job; trackingProgress = 0
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let report: @Sendable (Double) -> Void = { fraction in
                    Task { @MainActor in
                        if trackingJob == job, Int(trackingProgress * 100) != Int(fraction * 100) { trackingProgress = fraction }
                    }
                }
                let worker = Task.detached(priority: .userInitiated) { () -> (camera: AnnotationCameraMotion?, roster: PlayerRosterResult) in
                    let tracked: AnnotationCameraMotion? = existingCamera == nil
                        ? try await CameraMotionTracking.track(url: url, from: cameraRange.lowerBound, to: cameraRange.upperBound) { report($0 * 0.25) }
                        : nil
                    let camera = existingCamera ?? tracked
                    let scaled = tracked != nil
                    let roster = try await PlayerRosterTracking.track(url: url, from: start, to: end, priors: priors, camera: camera) {
                        report(scaled ? 0.25 + $0 * 0.75 : $0)
                    }
                    return (tracked, roster)
                }
                let outcome = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); guard trackingJob == job else { return }
                checkpoint()
                if let camera = outcome.camera { clip.storeSharedCameraTrack(camera) }
                let result = outcome.roster
                let merged = clip.mergeRoster(result)
                showsPlayers = true
                let lost = clip.trackingLibrary?.players.filter { $0.motion.lostAt != nil }.count ?? 0
                var summary = merged.tracked == 0 ? "No players could be followed in this clip." :
                    "Followed \(merged.tracked) motion \(merged.tracked == 1 ? "track" : "tracks") (\(merged.new) new), with up to \(result.peakVisible) people visible at once, in \(String(format: "%.1f", result.elapsed)) s. Tracks may be separate sections of the same player; assign teams and link them in Squad tracks."
                if lost > 0 { summary += " \(lost) \(lost == 1 ? "track needs" : "tracks need") correction; use the gap arrows on a selected player to review each section." }
                error = summary
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    /// Fold one published partial into the saved track. Forward splices through
    /// `continuing(with:from:)`, which replaces only the tracked range and keeps
    /// the saved past and future; backward joins through `prepending(_:seed:)`.
    private func folded(_ partial: PlayerMotion, into prior: PlayerMotion?, id: UUID,
                        from start: Double, direction: PlayerTrackingDirection,
                        fillOnlyRange: ClosedRange<Double>? = nil) -> PlayerMotion {
        var combined: PlayerMotion
        if let fillOnlyRange {
            combined = prior?.filling(with: partial, in: fillOnlyRange) ?? partial
        } else {
            switch direction {
            case .forward: combined = prior?.continuing(with: partial, from: start) ?? partial
            case .backward: combined = prior?.prepending(partial, seed: start) ?? partial
            }
        }
        combined.trackID = id
        return combined
    }

    /// One incremental player pass. Confirmed samples land in the clip while it
    /// runs and the playhead follows the tracked frame, so stopping keeps
    /// everything up to that point instead of throwing the pass away.
    ///
    /// Forward splices through `continuing(with:from:)`, which already replaces
    /// only the tracked range and preserves the saved past and future; backward
    /// joins through `prepending(_:seed:)`. Re-tracking a middle range is
    /// therefore just a pass the user stops.
    private func runPlayerTracking(id: UUID, seed: CGRect, from start: Double, to end: Double,
                                   direction: PlayerTrackingDirection,
                                   prior: PlayerMotion?,
                                   includeBodyMasks: Bool,
                                   confirmedSeed: Bool = false,
                                   effects: AnalysisPlayerEffects? = nil,
                                   then continuation: PlayerTrackingDirection? = nil,
                                   replacementRange: ClosedRange<Double>? = nil,
                                   fillOnlyRange: ClosedRange<Double>? = nil,
                                   recordUndo: Bool = true) {
        guard clip.freezeDuration == nil, abs(end - start) > 0.05 else { return }
        let url = request.recording.fileURL
        let job = UUID()
        endFrameReview(); pickedReplacementRange = nil
        session.cancel(); playback.pause()
        selectedPlayerTrackID = id
        selectedPlayer = .init(time: start, box: seed)
        trackingID = id; trackingJob = job; trackingProgress = 0
        trackingDirection = direction
        trackingOrigin = start
        trackingTime = start
        trackingPhase = .following
        if recordUndo { checkpoint() }
        if replacementRange != nil, let prior { clip.storePlayerTrack(prior) }

        trackingStoredAt = Date.timeIntervalSinceReferenceDate

        trackingTask = Task { @MainActor in
            defer {
                if trackingJob == job {
                    trackingID = nil; trackingTask = nil; trackingJob = nil
                    trackingDirection = nil; trackingOrigin = nil; trackingTime = nil
                }
            }
            do {
                let publish: @Sendable (PlayerTrackingCheckpoint) -> Void = { update in
                    Task { @MainActor in
                        guard trackingJob == job else { return }
                        trackingProgress = update.fraction
                        trackingTime = update.time
                        trackingPhase = update.phase
                        previewSeek(update.time)
                        guard let partial = update.motion, partial.samples.count > 1 else { return }
                        let combined = folded(partial, into: prior, id: id, from: start, direction: direction,
                                              fillOnlyRange: fillOnlyRange)
                        selectedPlayer = combined.box(at: update.time).map { .init(time: update.time, box: $0) }
                        // Persist occasionally as well, so a pass that is killed
                        // by anything other than Stop still leaves its work.
                        let now = Date.timeIntervalSinceReferenceDate
                        guard now - trackingStoredAt >= 2 else { return }
                        trackingStoredAt = now
                        clip.storePlayerTrack(combined)
                    }
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try await SelectedPlayerTracking.track(url: url, seed: seed, from: start, to: end,
                                                           direction: direction, prior: prior, includeBodyMasks: includeBodyMasks, confirmedSeed: confirmedSeed, checkpoint: publish)
                }
                let outcome = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard trackingJob == job else { return }
                let combined = folded(outcome.motion, into: prior, id: id, from: start, direction: direction,
                                      fillOnlyRange: fillOnlyRange)
                clip.storePlayerTrack(combined); selectedPlayerTrackID = id
                let reached = direction == .forward
                    ? (outcome.motion.samples.last?.time ?? start)
                    : (outcome.motion.samples.first?.time ?? start)
                seek(reached)
                selectedPlayer = combined.box(at: reached).map { .init(time: reached, box: $0) }
                if let effects {
                    selectedID = clip.applyPlayerEffects(effects, replacing: [], box: seed, motion: combined, at: start)
                    tool = .select
                }
                if outcome.stopped {
                    error = "Stopped at \(timelineTimecode(reached - clip.startSeconds, includesTenths: true)). Everything tracked up to there is saved; use Track forward or Track backward from the playhead to continue."
                } else if let next = continuation,
                          next == .forward ? start < clip.endSeconds - 0.1 : start > clip.startSeconds + 0.1 {
                    // Whole-clip tracking is the two halves in turn: the second
                    // starts from the same seed frame, once this pass has
                    // released tracking, and is stoppable in its own right.
                    let player = clip.trackingLibrary?.players.first(where: { $0.id == id })
                    Task { @MainActor in
                        await Task.yield()
                        guard let player, let box = player.motion.box(at: start) else { return }
                        var motion = player.motion; motion.identity = player.identity
                        runPlayerTracking(id: id, seed: box, from: start,
                                          to: next == .forward ? replacementRange?.upperBound ?? clip.endSeconds : replacementRange?.lowerBound ?? clip.startSeconds,
                                          direction: next, prior: motion, includeBodyMasks: includeBodyMasks,
                                          replacementRange: replacementRange, recordUndo: replacementRange == nil)
                    }
                } else if direction == .forward, let lost = outcome.motion.lostAt {
                    error = "Tracking stopped at \(timelineTimecode(lost - clip.startSeconds, includesTenths: true)). Paused at the last tracked frame. Use Correct to select this player and continue."
                } else if direction == .backward, let first = combined.samples.first?.time, first - clip.startSeconds > 0.15 {
                    error = "Followed back to \(timelineTimecode(first - clip.startSeconds, includesTenths: true)); before that the player could not be recognised. Use Place here or Correct on earlier frames if needed."
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Saves source motion directly; creating or correcting a player never needs
    /// a temporary drawing and never replaces another player's identity.
    /// Follow a saved player backwards from the current frame to the clip start,
    /// optionally continuing to the clip end afterwards (whole clip).
    private func trackPlayerBackward(_ id: UUID, thenForward: Bool, at requestedTime: Double? = nil) {
        guard trackingID == nil, clip.freezeDuration == nil,
              let saved = clip.trackingLibrary?.players.first(where: { $0.id == id }) else { return }
        var motion = saved.motion; motion.identity = saved.identity
        let start = requestedTime ?? time
        guard let seed = motion.trackingSeed(at: start) else {
            seek(start); pickPlayerTrack(correcting: id, direction: start - clip.startSeconds > 0.1 ? .backward : .forward, wholeClip: thenForward); return
        }
        guard start - clip.startSeconds > 0.1 || thenForward else { return }
        let replacing = thenForward ? clip.startSeconds...clip.endSeconds : clip.startSeconds...start
        motion = motion.clearingTracking(in: replacing)
        motion.place(seed, at: start)
        if thenForward {
            motion.jerseyProfile = nil
            if let identity = motion.identity {
                motion.identity = identity.restartingAutomaticLearning()
            }
        }
        if start - clip.startSeconds > 0.1 {
            runPlayerTracking(id: id, seed: seed, from: start, to: clip.startSeconds, direction: .backward,
                              prior: motion, includeBodyMasks: includeBodyMasks, then: thenForward ? .forward : nil,
                              replacementRange: replacing)
        } else if thenForward {
            runPlayerTracking(id: id, seed: seed, from: start, to: clip.endSeconds, direction: .forward,
                              prior: motion, includeBodyMasks: includeBodyMasks, replacementRange: replacing)
        }
    }

    private func trackPlayerToEnd(_ id: UUID, from requestedTime: Double? = nil) {
        guard trackingID == nil, clip.freezeDuration == nil,
              let saved = clip.trackingLibrary?.players.first(where: { $0.id == id }) else { return }
        var motion = saved.motion; motion.identity = saved.identity
        let start = requestedTime ?? time
        guard start < clip.endSeconds - 0.1 else { return }
        guard let seed = motion.trackingSeed(at: start) else {
            seek(start); pickPlayerTrack(correcting: id); return
        }
        let replacing = start...clip.endSeconds
        motion = motion.clearingTracking(in: replacing)
        motion.place(seed, at: start)
        runPlayerTracking(id: id, seed: seed, from: start, to: clip.endSeconds, direction: .forward,
                          prior: motion, includeBodyMasks: includeBodyMasks, replacementRange: replacing)
    }

    /// Track the missing interval nearest the playhead. The pass starts from
    /// the closest confirmed sample on either side, then merges only new
    /// samples inside that interval; existing samples are never replaced.
    private func fillPlayerGap(_ id: UUID) {
        guard trackingID == nil, clip.freezeDuration == nil,
              let player = clip.trackingLibrary?.players.first(where: { $0.id == id }) else { return }
        let motion = player.motion
        let range = clip.startSeconds...clip.endSeconds
        let gaps = motion.missingIntervals(in: range)
        guard let gap = gaps.first(where: { $0.contains(time) }) ?? gaps.min(by: {
            abs($0.lowerBound + ($0.upperBound - $0.lowerBound) / 2 - time) <
            abs($1.lowerBound + ($1.upperBound - $1.lowerBound) / 2 - time)
        }) else { return }

        let before = motion.samples.last { $0.time < gap.lowerBound && !motion.isMissing(at: $0.time) }
        let after = motion.samples.first { $0.time > gap.upperBound && !motion.isMissing(at: $0.time) }
        var prior = motion; prior.identity = player.identity

        if let before, gap.upperBound - before.time > 0.05 {
            runPlayerTracking(id: id, seed: before.box, from: before.time, to: gap.upperBound,
                              direction: .forward, prior: prior, includeBodyMasks: includeBodyMasks,
                              fillOnlyRange: gap)
        } else if let after, after.time - gap.lowerBound > 0.05 {
            runPlayerTracking(id: id, seed: after.box, from: after.time, to: gap.lowerBound,
                              direction: .backward, prior: prior, includeBodyMasks: includeBodyMasks,
                              fillOnlyRange: gap)
        }
    }

    private func trackIndependentPlayer(seed: CGRect, effects: AnalysisPlayerEffects? = nil, from requestedStart: Double? = nil) {
        if let view = referenceView, let id = correctingTrackID { capturePlayerReference(id, seed: seed, view: view); return }
        if placingPlayer, let id = correctingTrackID { placeSelectedPlayer(id, seed: seed); return }
        let start = requestedStart ?? time
        let direction = correctingTrackID == nil ? PlayerTrackingDirection.forward : pickedDirection
        let replacing = pickedReplacementRange
        let end = direction == .forward ? replacing?.upperBound ?? clip.endSeconds : replacing?.lowerBound ?? clip.startSeconds
        guard trackingID == nil, clip.freezeDuration == nil, abs(end - start) > 0.05 else { return }
        var previous = clip.trackingLibrary?.players.first(where: { $0.id == correctingTrackID })?.motion
        previous?.identity = clip.trackingLibrary?.players.first(where: { $0.id == correctingTrackID })?.identity
        if let replacing {
            previous = previous?.clearingTracking(in: replacing)
            previous?.place(seed, at: start)
        } else {
            previous = previous?.preparingCorrection(at: start, direction: direction)
        }
        let id = previous?.trackID ?? correctingTrackID ?? UUID()
        let next: PlayerTrackingDirection? = replacing != nil
            ? (direction == .backward && replacing!.upperBound - start > 0.05 ? .forward : nil)
            : previous != nil && pickedWholeClip && direction == .backward ? .forward : previous == nil && start - clip.startSeconds > 0.1 ? .backward : nil
        runPlayerTracking(id: id, seed: seed, from: start, to: end, direction: direction, prior: previous,
                          includeBodyMasks: includeBodyMasks, confirmedSeed: true, effects: effects, then: next,
                          replacementRange: replacing)
    }

    private func capturePlayerReference(_ id: UUID, seed: CGRect, view: PlayerIdentityView) {
        guard trackingID == nil, !playback.isSeeking else { return }
        let sourceTime = time, url = request.recording.fileURL
        referenceView = nil; pickingPlayerTrack = false; placingPlayer = false; correctingTrackID = nil
        trackingID = id; trackingProgress = 0
        trackingTask = Task { @MainActor in
            defer { trackingID = nil; trackingTask = nil }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await PlayerAppearancePrinter.reference(url: url, box: seed, at: sourceTime)
                }
                let observation = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard observation.jersey != nil, !observation.crowded, !PlayerBodyExtent.isCropped(seed) else {
                    error = "Choose a clear, fully visible view of this player for the identity reference."; return
                }
                guard let index = clip.trackingLibrary?.players.firstIndex(where: { $0.id == id }) else { return }
                checkpoint()
                var memory = clip.trackingLibrary?.players[index].identity ?? PlayerIdentityMemory()
                memory.confirm(observation, view: view)
                clip.trackingLibrary?.players[index].identity = memory
                clip.trackingLibrary?.players[index].motion.jerseyProfile = memory.jersey
                selectedPlayerTrackID = id
                error = "\(view.title) reference saved."
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func setPlayerNumber(_ id: UUID, number: String) {
        let value = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || PlayerNumberVotes.isShirtNumber(value),
              let index = clip.trackingLibrary?.players.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        var memory = clip.trackingLibrary?.players[index].identity ?? PlayerIdentityMemory()
        memory.number.manual = value.isEmpty ? nil : value
        if value.isEmpty { memory.number.counts = [:] }
        clip.trackingLibrary?.players[index].identity = memory
    }

    private var measurementStatus: String? {
        guard let calibration = clip.groundCalibration else { return nil }
        return calibration.isApproximate ? "Approximate local measurements · not perspective corrected." : "Ground-calibrated estimates · speed uses the recorded source time."
    }

    private func openMeasurements() {
        playback.pause()
        var existing = clip.groundCalibration
        // Edit the reference on its original source frame, not a moved camera pose.
        let reference = existing?.referenceTime ?? time
        if clip.freezeDuration != nil { existing?.fixedCamera = true }
        groundRequest = .init(sourceTime: clip.freezeDuration == nil ? reference : clip.startSeconds,
                              annotationTime: reference, existing: existing, isStill: clip.freezeDuration != nil,
                              sourceRange: clip.startSeconds...clip.endSeconds, cameraMotion: clip.trackingLibrary?.sharedCamera)
    }

    private func applyGroundCalibration(_ value: GroundCalibration?) {
        checkpoint(); playback.pause(); clip.groundCalibration = value
        if let value, clip.freezeDuration == nil { seek(value.referenceTime) }
        guard let value, value.valid, !value.fixedCamera, clip.freezeDuration == nil else { return }
        clip.refreshSharedCameraBindings()
        ensureSharedCameraTracking()
    }
    private func beginTracking(id: UUID, seed: CGRect, from start: Double, confirmedSeed: Bool = false) {
        guard clip.freezeDuration == nil, seed.width > 0.002, seed.height > 0.005,
              let index = clip.annotations.firstIndex(where: { $0.id == id }), clip.annotations[index].end > start else { return }
        trackingTask?.cancel(); session.cancel(); playback.pause()
        let original = clip.annotations[index]
        let trackID = original.playerMotion?.trackID ?? UUID()
        let prior = original.playerMotion.map { clip.trackingLibrary?.resuming($0) ?? $0 }
            .map { confirmedSeed ? $0.preparingCorrection(at: start, direction: .forward) : $0 }
        // Switching an authored animation to follow starts from the pose the
        // user is looking at, not the drawing's original unanimated position.
        if original.playerMotion == nil { clip.annotations[index].points = original.points(at: start) }
        // A repair is transactional: don't swap a complete saved track for a
        // one-frame placeholder while the worker is running.
        if original.playerMotion == nil {
            clip.annotations[index].playerMotion = PlayerMotion(samples: [.init(time: start, box: seed)], lostAt: start + 0.1)
        }
        let job = UUID()
        trackingID = id; trackingJob = job; trackingProgress = 0
        let url = request.recording.fileURL, end = clip.endSeconds
        // Read once here: the worker below must not touch view state.
        let includeBodyMasks = self.includeBodyMasks
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await SelectedPlayerTracking.track(url: url, seed: seed, from: start, to: end, prior: prior, includeBodyMasks: includeBodyMasks, confirmedSeed: confirmedSeed) { fraction in
                        Task { @MainActor in if trackingJob == job { trackingProgress = fraction } }
                    }
                }
                let motion = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard trackingJob == job, let index = clip.annotations.firstIndex(where: { $0.id == id }) else { return }
                var combined = prior?.continuing(with: motion, from: start) ?? motion
                combined.smoothing = original.playerMotion?.smoothing ?? (original.tool == .text ? 0.95 : nil)
                combined.trackID = trackID
                combined.referenceBox = original.playerMotion?.reference ?? seed
                clip.annotations[index].playerMotion = combined
                clip.annotations[index].cameraMotion = nil; clip.annotations[index].linkedPlayers = nil
                clip.annotations[index].keyframes = []
                clip.storePlayerTrack(combined); selectedPlayerTrackID = trackID
                if let lost = motion.lostAt {
                    seek(motion.correctionTime ?? lost)
                    error = "Tracking stopped at \(timelineTimecode(lost - clip.startSeconds, includesTenths: true)). Tap Correct, then select the same player to continue."
                }
            } catch is CancellationError {
                if trackingJob == job, let index = clip.annotations.firstIndex(where: { $0.id == id }) {
                    clip.annotations[index].playerMotion = original.playerMotion
                    clip.annotations[index].points = original.points
                }
            } catch {
                if trackingJob == job, let index = clip.annotations.firstIndex(where: { $0.id == id }) {
                    clip.annotations[index].playerMotion = original.playerMotion
                    clip.annotations[index].points = original.points
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func beginLinkedTracking(id: UUID, seeds: [PlayerMotionSample], replacing: Int? = nil) {
        guard !seeds.isEmpty, let index = clip.annotations.firstIndex(where: { $0.id == id }), clip.freezeDuration == nil else { return }
        let original = clip.annotations[index]
        let initial = (original.linkedPlayers ?? seeds.map { seed in
            clip.trackingLibrary?.player(matching: seed.box, at: seed.time)?.motion.bound(at: seed.time)
                ?? PlayerMotion(samples: [seed], trackID: UUID(), referenceBox: seed.box)
        }).map { clip.trackingLibrary?.resuming($0) ?? $0 }
        checkpoint(); trackingTask?.cancel(); session.cancel(); playback.pause()
        let job = UUID(); trackingID = id; trackingJob = job; trackingProgress = 0
        let url = request.recording.fileURL
        let end = clip.endSeconds
        let includeBodyMasks = self.includeBodyMasks
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    var motions = initial
                    var repairFailure: (index: Int, time: Double)?
                    for (offset, seed) in seeds.enumerated() {
                        try Task.checkCancellation()
                        let target = replacing ?? offset
                        guard motions.indices.contains(target), seed.time < end else { continue }
                        let old = motions[target]
                        if replacing == nil, (old.samples.last?.time ?? 0) >= end - 0.12 || old.lostAt != nil { continue }
                        let trackingSeed = replacing == nil && old.samples.count > 1 ? old.samples.last ?? seed : seed
                        let confirmed = replacing != nil || old.samples.count <= 1
                        let prior = replacing != nil ? old.preparingCorrection(at: trackingSeed.time, direction: .forward) : old
                        let motion = try await SelectedPlayerTracking.track(url: url, seed: trackingSeed.box, from: trackingSeed.time, to: end, prior: prior, includeBodyMasks: includeBodyMasks, confirmedSeed: confirmed) { fraction in
                            Task { @MainActor in if trackingJob == job { trackingProgress = (Double(offset) + fraction) / Double(seeds.count) } }
                        }
                        if let time = motion.correctionTime, time < (repairFailure?.time ?? .infinity) {
                            repairFailure = (target, time)
                        }
                        motions[target] = prior.continuing(with: motion, from: trackingSeed.time)
                        motions[target].trackID = old.trackID ?? UUID()
                        motions[target].referenceBox = old.reference
                    }
                    return (motions: motions, repairFailure: repairFailure)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                let motions = result.motions
                try Task.checkCancellation()
                guard trackingJob == job, let index = clip.annotations.firstIndex(where: { $0.id == id }) else { return }
                clip.annotations[index].linkedPlayers = motions
                clip.annotations[index].playerMotion = nil; clip.annotations[index].cameraMotion = nil; clip.annotations[index].keyframes = []
                for motion in motions { clip.storePlayerTrack(motion) }
                if let failure = result.repairFailure {
                    // Preserved future coverage can hide a failed repair's
                    // terminal loss in the merged track. Focus the actual pass.
                    correctingAnchor = failure.index; seek(failure.time)
                    correctingPlayer = true; tool = .select; detect(motion: false)
                } else if let failed = motions.enumerated().filter({ $0.element.lostAt != nil }).min(by: { ($0.element.lostAt ?? .infinity) < ($1.element.lostAt ?? .infinity) }),
                   let lost = failed.element.lostAt {
                    correctingAnchor = failed.offset
                    seek(failed.element.correctionTime ?? lost)
                    correctingPlayer = true; tool = .select; detect(motion: false)
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private var cameraCoverageStatus: String {
        if clip.hasFullCameraTrack { return "First to last frame · shared camera track" }
        guard let camera = clip.trackingLibrary?.sharedCamera,
              let first = camera.samples.first, let last = camera.samples.last else { return "Camera not tracked yet" }
        return "Partial coverage · \(timelineTimecode(max(0, first.time - clip.startSeconds), includesTenths: false))–\(timelineTimecode(max(0, last.time - clip.startSeconds), includesTenths: false))"
    }

    private func beginCameraTracking(fromCurrentFrame: Bool = true) {
        guard var mark = selected, mark.isLocked != true, clip.freezeDuration == nil else { return }
        let bindTime = mark.cameraMotion?.referenceTime ?? mark.cameraMotion?.samples.first?.time
            ?? (fromCurrentFrame ? min(mark.end - 0.05, max(mark.start, time)) : mark.start)
        if mark.tool != .trajectory, mark.cameraMotion == nil { mark.makeStatic(at: bindTime) }
        ensureSharedCameraTracking(pending: mark, bindTime: bindTime)
    }

    private func attachToClipCamera(_ mark: AnalysisAnnotation?, at reference: Double?) {
        guard var mark, let reference, var camera = clip.trackingLibrary?.sharedCamera,
              camera.transform(at: reference) != nil,
              let index = clip.annotations.firstIndex(where: { $0.id == mark.id }) else { return }
        if mark.tool == .trajectory { mark.trajectoryCameraMotion = camera }
        else { camera.referenceTime = reference; mark.cameraMotion = camera }
        clip.annotations[index] = mark
    }

    /// Field setup, the clip action and Follow camera all use this single pass.
    /// Calibration/binding time only defines geometry; it never limits coverage.
    private func ensureSharedCameraTracking(force: Bool = false, pending: AnalysisAnnotation? = nil, bindTime: Double? = nil) {
        guard clip.freezeDuration == nil, trackingID == nil else { return }
        if !force, clip.hasFullCameraTrack {
            if pending != nil { checkpoint() }
            clip.refreshSharedCameraBindings()
            attachToClipCamera(pending, at: bindTime)
            return
        }
        checkpoint(); trackingTask?.cancel(); session.cancel(); playback.pause()
        let job = UUID(), url = request.recording.fileURL, range = clip.cameraTrackingRange
        trackingID = job; trackingJob = job; trackingProgress = 0
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await CameraMotionTracking.track(url: url, from: range.lowerBound, to: range.upperBound) { fraction in
                        Task { @MainActor in
                            if trackingJob == job, Int(trackingProgress * 100) != Int(fraction * 100) { trackingProgress = fraction }
                        }
                    }
                }
                let motion = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); guard trackingJob == job else { return }
                let adopted = clip.storeSharedCameraTrack(motion)
                attachToClipCamera(pending, at: bindTime)
                if let lost = motion.lostAt {
                    seek(motion.samples.last?.time ?? lost)
                    let result = adopted ? "The partial track was saved." : "The previous longer track was kept."
                    error = "Camera motion could not be connected at \(timelineTimecode(lost - clip.startSeconds, includesTenths: true)). \(result) Field preview and camera-following layers share this coverage; a cut or obscured view may need a separate clip."
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func prepare() async {
        guard !initialised else { return }
        playback.commitSeek(request.seconds)
        do {
            let asset = AVURLAsset(url: request.recording.fileURL)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                let display = CGRect(origin: .zero, size: size).applying(transform).standardized.size
                displayAspect = display.width / max(1, display.height)
                let rate = Double(try await track.load(.nominalFrameRate))
                sourceFrameRate = rate.isFinite && rate > 0 ? rate : 30
            }
            if clip.freezeDuration != nil {
                let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let result = try await generator.image(at: CMTime(seconds: clip.startSeconds, preferredTimescale: 600))
                still = UIImage(cgImage: result.image)
            }
            initialised = true
            if analysis?.frame(at: request.seconds) == nil { detect(motion: false) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct AnnotationDrawingSurface: UIViewRepresentable {
    var marks: [AnalysisAnnotation]
    var ground: GroundCalibration?
    var time: Double
    var frame: CGRect
    var selectedID: UUID?
    var detections: [AnalysisDetection]
    var selectedPlayer: CGRect?
    var constructionPoints: [CGPoint]
    var renderMarks = true
    func makeUIView(context: Context) -> DrawingView { let view = DrawingView(); view.isOpaque = false; view.backgroundColor = .clear; return view }
    func updateUIView(_ view: DrawingView, context: Context) { view.content = self; view.setNeedsDisplay() }
    final class DrawingView: UIView {
        var content: AnnotationDrawingSurface?
        override func draw(_ rect: CGRect) {
            guard let content, let context = UIGraphicsGetCurrentContext() else { return }
            if content.renderMarks { AnnotationRenderer.draw(content.marks, time: content.time, in: context, frame: content.frame, editing: true, ground: content.ground) }
            context.setLineWidth(1)
            for detection in content.detections {
                let box = detection.rect
                let mapped = CGRect(x: content.frame.minX + box.minX * content.frame.width, y: content.frame.minY + box.minY * content.frame.height, width: box.width * content.frame.width, height: box.height * content.frame.height)
                context.setStrokeColor(UIColor.white.withAlphaComponent(0.65).cgColor); context.stroke(mapped)
            }
            if let box = content.selectedPlayer {
                let mapped = CGRect(x: content.frame.minX + box.minX * content.frame.width, y: content.frame.minY + box.minY * content.frame.height, width: box.width * content.frame.width, height: box.height * content.frame.height)
                context.setStrokeColor(UIColor(Theme.signal).cgColor); context.setLineWidth(2); context.stroke(mapped.insetBy(dx: -3, dy: -3))
            }
            if let selected = content.marks.first(where: { $0.id == content.selectedID }), selected.isLocked != true,
               selected.isHidden != true, selected.isActiveInEditor(at: content.time) {
                if selected.tool == .zoom {
                    let transform = AnnotationViewport.transform(marks: [selected], time: (selected.start + selected.end) / 2, frame: content.frame, bounds: bounds)
                    let crop = content.frame.intersection(bounds).applying(transform.inverted())
                    context.setStrokeColor(UIColor(Theme.signal).cgColor); context.setLineWidth(1.5)
                    context.setLineDash(phase: 0, lengths: [6, 4]); context.stroke(crop); context.setLineDash(phase: 0, lengths: [])
                }
                context.setFillColor(UIColor.white.cgColor)
                context.setStrokeColor(UIColor.black.cgColor); context.setLineWidth(2)
                for point in selected.linkedPlayers == nil ? selected.editHandles(at: content.time, ground: content.ground) : [] {
                    let handle = CGRect(x: content.frame.minX + point.x * content.frame.width - 6, y: content.frame.minY + point.y * content.frame.height - 6, width: 12, height: 12)
                    context.fillEllipse(in: handle); context.strokeEllipse(in: handle)
                }
            }
            AnalysisConstructionOverlay.draw(points: content.constructionPoints, frame: content.frame, in: context)
        }
    }
}

private struct AnalysisPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> Surface { let view = Surface(); view.layerPlayer.videoGravity = .resizeAspect; return view }
    func updateUIView(_ view: Surface, context: Context) { view.layerPlayer.player = player }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.layerPlayer.player = nil }
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
