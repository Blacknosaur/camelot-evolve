import AVKit
import SwiftUI

enum AnalysisWorkspaceMode: String, Identifiable {
    case video, freezeFrame
    var id: String { rawValue }
    var title: String { self == .video ? "Analyse" : "Freeze frame" }
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

/// Analyse one clip: highlight players, draw, add text and zoom.
///
/// The screen is task-first. The bottom bar shows the tasks at rest, the
/// palette or instruction of the task in progress, or the actions of what is
/// selected. Following a player is automatic: pick a player and a highlight,
/// and the video runs along with the pass. Fixing it is one idea — tap the
/// right player on any frame — rather than a set of tracking directions.
struct AnalysisWorkspaceView: View {
    let request: AnalysisWorkspaceRequest
    let session: AnalysisSession
    let save: (CompositionClip) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var playback: EditorPlayback
    @State private var clip: CompositionClip
    @State private var selectedID: UUID?
    @State private var tool: AnalysisDrawingTool = .select
    /// The Draw palette reopens on the last shape used.
    @State private var lastDrawTool: AnalysisDrawingTool = .arrow
    @State private var color = AnnotationColor.yellow
    @State private var width = 0.006
    @State private var draft: AnalysisAnnotation?
    @State private var dragOriginal: AnalysisAnnotation?
    @State private var undo: [CompositionClip] = []
    @State private var redo: [CompositionClip] = []
    @State private var displayAspect: CGFloat = 16 / 9
    @State private var still: UIImage?
    @State private var error: String?
    @State private var notice: String?
    @State private var noticeToken = UUID()
    @State private var selectedKeyframe: UUID?
    @State private var showsPlayers = true
    @State private var initialised = false
    @State private var freezeTime = 0.0
    @State private var selectedPlayer: PlayerMotionSample?
    @State private var selectedPlayerTrackID: UUID?
    @State private var showPlayerEffects = false
    /// Fix mode: the next tap on the video is where this player really is.
    @State private var pickingPlayerTrack = false
    @State private var correctingTrackID: UUID?
    @State private var trackingTask: Task<Void, Never>?
    @State private var trackingID: UUID?
    @State private var trackingJob: UUID?
    @State private var trackingProgress = 0.0
    @State private var trackingPhase: PlayerTrackingPhase = .following
    @State private var trackingStoredAt = 0.0
    /// Set while the clip camera is being read rather than a player followed.
    @State private var readingCamera = false
    /// Where a follow or fix began; the playhead returns here when it ends.
    @State private var followOrigin: Double?
    @State private var correctingPlayer = false
    @State private var showProperties = false
    @State private var showPitchOptions = false
    @State private var confirmDiscard = false
    @State private var renamingPlayer: UUID?
    @State private var draftName = ""
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
    @State private var editingTextSize = false
    @State private var groundRequest: GroundCalibrationRequest?
    @State private var fieldPreviewEnabled = false
    /// Nil until the coach drags the divider: the video then gets exactly the
    /// height the footage needs and everything else goes to the workspace.
    @State private var workspaceHeight: Double?
    @State private var sidebarWidth = 360.0
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
    private var clipRange: ClosedRange<Double> { clip.startSeconds...clip.endSeconds }
    private var selected: AnalysisAnnotation? { clip.annotations.first { $0.id == selectedID } }
    private var analysis: RecordingAnalysis? { session.analysis(for: request.recording.id) }
    private var detectionTime: Double { clip.freezeDuration == nil ? time : clip.startSeconds }
    private var detections: [AnalysisDetection] { analysis?.frame(at: detectionTime)?.detections ?? [] }
    private var isDrawing: Bool { AnalysisDrawingTool.drawShapes.contains(tool) }
    private var pickingConnection: Bool { tool == .connection || tool == .zone && areaUsesPlayers }
    private var isBusy: Bool { trackingID != nil }
    private var playerEffectLayers: [AnalysisAnnotation] {
        clip.annotations.filter { mark in
            [.player, .spotlight, .text, .trajectory, .loupe].contains(mark.tool) &&
            (selectedPlayerTrackID != nil ? mark.playerMotion?.trackID == selectedPlayerTrackID :
                selected?.playerEffectGroupID != nil ? mark.playerEffectGroupID == selected?.playerEffectGroupID : mark.id == selectedID)
        }
    }
    private func playerName(_ id: UUID?) -> String {
        clip.trackingLibrary?.players.first(where: { $0.id == id })?.name ?? "the player"
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

    /// One short instruction on the video, where the finger is going.
    private var canvasHint: String {
        if isBusy { return "" }
        if pickingPlayerTrack { return "Tap \(playerName(correctingTrackID))" }
        if correctingPlayer { return "Tap the player to follow" }
        switch tool {
        case .player: return "Tap a player"
        case .text: return "Tap where the text goes"
        case .zoom: return "Tap where to zoom in"
        case .loupe: return "Tap a player or a spot to magnify"
        case .connection: return "Tap players in order"
        case .zone: return areaUsesPlayers ? "Tap players in order" : "Tap each corner"
        case .pen: return "Draw with your finger"
        case .arrow, .line, .ellipse, .rectangle: return "Drag to draw"
        default: break
        }
        if let selected, selected.tool == .zoom { return "Drag to move the zoom" }
        if let selected, selected.motionMode == .keyframes { return "Scrub, then drag to set a position" }
        return ""
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
                    let fitted = layout.size.height - 20 - (layout.size.width / max(0.5, displayAspect) + 64)
                    let sizes = EditorPanelSizes(height: layout.size.height, workspace: workspaceHeight ?? max(230, fitted), minimumWorkspace: 230)
                    VStack(spacing: 0) {
                        analysisPreview.frame(height: sizes.preview).clipped()
                        EditorPanelDivider(title: "Workspace", value: sizes.workspace,
                            limits: min(230, layout.size.height * 0.45)...max(230, layout.size.height - 180)) { workspaceHeight = $0 }
                        analysisWorkspace.frame(height: sizes.workspace).clipped()
                    }
                }
            }
            .background(Theme.inkPanel)
            .navigationTitle(request.mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { if undo.isEmpty { dismiss() } else { playback.pause(); confirmDiscard = true } } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(.rect)
                    }.accessibilityLabel("Close without saving").accessibilityIdentifier("cancel-analysis-workspace")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { undoEdit() }
                        .disabled(undo.isEmpty || isBusy).accessibilityIdentifier("analysis-undo")
                    Button("Redo", systemImage: "arrow.uturn.forward") { redoEdit() }
                        .disabled(redo.isEmpty || isBusy).accessibilityIdentifier("analysis-redo")
                    Button("Done") {
                        do { try save(clip); dismiss() } catch { self.error = error.localizedDescription }
                    }.bold().foregroundStyle(Theme.signal).disabled(isBusy)
                        .accessibilityIdentifier("save-analysis-workspace")
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("Analysis", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .confirmationDialog("Pitch", isPresented: $showPitchOptions, titleVisibility: .hidden) {
                Button(fieldPreviewEnabled ? "Hide pitch lines" : "Show pitch lines") { toggleFieldPreview() }
                    .accessibilityIdentifier("analysis-tool-field-preview")
                Button("Line up the pitch again") { openMeasurements() }
                    .accessibilityIdentifier("analysis-tool-measure")
                Button("Cancel", role: .cancel) {}
            }
            .alert("Player name", isPresented: Binding(get: { renamingPlayer != nil }, set: { if !$0 { renamingPlayer = nil } })) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) { renamingPlayer = nil }
                Button("Save") { if let id = renamingPlayer { renamePlayerTrack(id, name: draftName) }; renamingPlayer = nil }
            }
        }
        .sheet(isPresented: $showProperties) {
            AnalysisInspectorSheet(title: selected?.title ?? "Style",
                                   style: { inspectorStyle.disabled(isBusy) },
                                   timing: { inspectorTiming.disabled(isBusy) })
                .id(selectedID)
        }
        .sheet(isPresented: $showPlayerEffects) {
            AnalysisPlayerEffectsSheet(name: selectedPlayerTrackID == nil ? "Player \((clip.trackingLibrary?.players.count ?? 0) + 1)" : selectedPlayerName,
                                       existing: playerEffectLayers, allowsTrajectory: clip.freezeDuration == nil,
                                       measurementStatus: measurementStatus, apply: applyPlayerEffects)
        }
        .fullScreenCover(item: $groundRequest) { request in
            GroundCalibrationSheet(url: self.request.recording.fileURL, request: request, apply: applyGroundCalibration)
        }
        .preferredColorScheme(.dark).tint(.white)
        .task { await prepare() }
        .task(id: noticeToken) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { withAnimation { notice = nil } }
        }
        .onDisappear {
            // A full-screen placement editor temporarily covers this workspace.
            // Keep the time observer so playback/scrubbing still updates on return.
            if groundRequest != nil { playback.pause() }
            else { playback.stop(); session.cancel(); trackingTask?.cancel() }
        }
        // Player finding is a convenience: when it fails the coach can still
        // draw a box, so say that instead of interrupting with an alert.
        .onChange(of: session.errorMessage) {
            if session.errorMessage != nil { show("Couldn't pick out players on this frame. Draw a box around one instead.") }
        }
        .onChange(of: selectedID) {
            selectedVertex = nil
            correctingAnchor = nil
            if selected?.keyframes.contains(where: { $0.id == selectedKeyframe }) != true { selectedKeyframe = nil }
            correctingPlayer = false
        }
        .task(id: detectionTime) {
            guard initialised, !playback.isPlaying, !isBusy, selectedID == nil || correctingPlayer || pickingConnection else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if analysis?.frame(at: detectionTime) == nil { detect() }
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

    private func show(_ message: String) {
        withAnimation { notice = message }
        noticeToken = UUID()
    }

    // MARK: - Preview

    private var analysisPreview: some View {
        canvas.background(.black)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 52).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                EditorPreviewControls(playback: playback, isPreparing: !initialised,
                    isEnabled: initialised && clip.freezeDuration == nil && !isBusy && constructionPoints.isEmpty,
                    play: togglePlayback, currentTime: time - clip.startSeconds,
                    totalTime: clip.annotationEnd - clip.startSeconds,
                    timeIdentifier: "analysis-current-time", playIdentifier: "analysis-play-pause",
                    previousFrame: { seek(time - 1 / sourceFrameRate) }, nextFrame: { seek(time + 1 / sourceFrameRate) })
                    .padding(.horizontal, 8).padding(.bottom, 2)
            }
            .overlay(alignment: .top) {
                if let notice {
                    Text(notice).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.signal, in: .rect(cornerRadius: Theme.Radius.medium))
                        .foregroundStyle(Theme.ink).padding(.horizontal, 16).padding(.top, 48)
                        .onTapGesture { withAnimation { self.notice = nil } }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("analysis-notice")
                }
            }
    }

    private func togglePlayback() {
        if playback.isPlaying { playback.pause() }
        else { playback.playRange(from: time >= clip.endSeconds - 0.04 ? clip.startSeconds : time, to: clip.endSeconds) }
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

    /// Detected players are offered whenever a tap on one would do something.
    private var offersPlayers: Bool {
        showsPlayers && !playback.isPlaying && !isBusy &&
            ((tool == .select || tool == .player) && (selectedID == nil || correctingPlayer) || pickingConnection)
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
            AnnotationDrawingSurface(marks: marks, ground: clip.groundCalibration, time: time, frame: frame,
                                     selectedID: playback.isPlaying ? nil : selectedID,
                                     detections: offersPlayers ? detections : [],
                                     selectedPlayer: playback.isPlaying ? nil : selectedPlayer?.box,
                                     constructionPoints: constructionPoints, renderMarks: !usesLoupe)
                .allowsHitTesting(false)
                .overlay {
                    ConnectionAnchorSurface(anchors: playback.isPlaying || selected?.isHidden == true ? [] : connectionAnchors,
                                            correcting: correctingPlayer ? correctingAnchor : nil, frame: frame).allowsHitTesting(false)
                }
            if fieldPreviewEnabled {
                AnalysisFieldPreview(calibration: clip.groundCalibration, time: time, frame: frame, bounds: bounds)
                    .allowsHitTesting(false)
            }
            if offersPlayers {
                ForEach(Array(detections.enumerated()), id: \.offset) { index, detection in
                    Button {
                        if pickingConnection { appendConstructionPlayer(detection.rect) }
                        else { selectPlayer(detection.rect) }
                    } label: { Color.clear.contentShape(.rect) }
                        .buttonStyle(.plain)
                        .frame(width: max(24, detection.rect.width * frame.width), height: max(30, detection.rect.height * frame.height))
                        .position(x: frame.minX + detection.rect.midX * frame.width, y: frame.minY + detection.rect.midY * frame.height)
                        .accessibilityLabel("Player \(index + 1)")
                        .accessibilityHint("Select to highlight this player")
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
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: .capsule).allowsHitTesting(false)
                    .accessibilityIdentifier("analysis-canvas-hint")
            }
            Spacer(minLength: 4)
            if isBusy, let player = activePlayer { followingChip(player) }
            if abs(canvasZoom - 1) > 0.01 || hypot(zoomCenter.x - 0.5, zoomCenter.y - 0.5) > 0.01 {
                Button("Fit preview", systemImage: "arrow.down.right.and.arrow.up.left") {
                    canvasZoom = 1; zoomCenter = CGPoint(x: 0.5, y: 0.5)
                }.labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle())
                    .accessibilityIdentifier("analysis-inspect-fit")
            }
        }.padding(8)
    }

    private func followingChip(_ player: AnalysisTrackingLibrary.Player) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.run").symbolEffect(.pulse)
            Text("\(player.name) · \(Int(trackingProgress * 100))%").monospacedDigit()
        }
        .font(.caption.bold()).foregroundStyle(Theme.ink)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.signal, in: .capsule)
        .accessibilityIdentifier("analysis-selected-player-chip")
        .accessibilityLabel("Following \(player.name)")
    }

    // MARK: - Workspace

    private var analysisWorkspace: some View {
        VStack(spacing: 0) {
            if correctingPlayer, let anchor = correctingConnectionAnchor {
                AnalysisConnectionCorrectionCard(anchor: anchor, url: request.recording.fileURL, clipStart: clip.startSeconds, showLastSeen: { seek($0) }).id(anchor.id)
            }
            constructionControls
            if selected?.linkedPlayers != nil, !correctingPlayer, !isBusy {
                AnalysisConnectionSelectionStrip(anchors: connectionAnchors, selected: correctingAnchor) { anchor in
                    correctingAnchor = anchor; correctingPlayer = true; tool = .select
                    playback.pause(); detect()
                }.disabled(selected?.isLocked == true)
            }
            layerTimeline
            Rectangle().fill(Theme.inkStroke).frame(height: 1)
            bottomBar.background(Theme.inkPanel)
        }.background(Theme.inkPanel)
    }

    /// Exactly one bar at a time; the first matching state wins.
    @ViewBuilder private var bottomBar: some View {
        if isBusy {
            AnalysisFollowingBar(title: readingCamera ? "Reading the camera movement" : "Following \(activePlayer?.name ?? "the player")",
                                 progress: trackingProgress,
                                 status: readingCamera ? "So drawings stay on the pitch as the camera pans." : trackingStatus,
                                 stop: { trackingTask?.cancel() })
        } else if pickingPlayerTrack, let id = correctingTrackID {
            fixPrompt(id)
        } else if correctingPlayer {
            AnalysisPromptBar(title: "Choose a player to follow", message: "Tap them on the video, or draw a box around them.",
                              identifier: "analysis-correct-tracking") {
                correctingPlayer = false; tool = .select; session.cancel()
            }
        } else if isDrawing, constructionPoints.isEmpty {
            AnalysisDrawPalette(tool: tool, color: $color, choose: chooseTool, done: { tool = .select })
        } else if isDrawing {
            EmptyView()
        } else if tool == .player {
            AnalysisPromptBar(title: "Highlight a player", message: "Tap a player on the video. If one isn't picked up, draw a box around them.",
                              identifier: "analysis-player-prompt") { tool = .select }
        } else if tool == .text {
            AnalysisPromptBar(title: "Add text", message: "Tap where the text should go.", identifier: "analysis-text-prompt") { tool = .select }
        } else if tool == .zoom {
            AnalysisPromptBar(title: "Zoom in", message: "Tap the spot to zoom in on. Trim its bar to set how long.", identifier: "analysis-zoom-prompt") { tool = .select }
        } else if let player = activePlayer {
            AnalysisPlayerBar(player: player, range: clipRange, time: time,
                              rename: { draftName = player.name; renamingPlayer = player.id },
                              effects: { openPlayerEffects(for: player) },
                              fix: { beginFix(player.id) },
                              seek: { seek($0) }, allowsFix: clip.freezeDuration == nil, close: clearSelection) { playerMenu(player) }
        } else if selectedPlayer != nil, selectedID == nil {
            AnalysisSelectionBar(title: "New player", symbol: "person.crop.circle.badge.plus", close: clearSelection) {
                Button("Highlight", systemImage: "sparkles") { showPlayerEffects = true }
                    .labelStyle(.titleAndIcon).fixedSize()
                    .buttonStyle(EditorActionStyle(prominent: true)).accessibilityIdentifier("analysis-player-effects")
            }
        } else if let selected {
            drawingBar(selected)
        } else {
            VStack(spacing: 0) {
                freezeControls
                AnalysisTaskBar(hasPitch: clip.groundCalibration != nil, allowsPlayers: true,
                                player: { chooseTool(.player) }, draw: { chooseTool(lastDrawTool) },
                                text: { chooseTool(.text) }, zoom: { chooseTool(.zoom) }, pitch: openPitch)
            }
        }
    }

    private var trackingStatus: String {
        switch trackingPhase {
        case .following: "The video moves with them. Stop keeps what's done."
        case .occluded: "Hidden behind someone · still looking"
        case .offscreen: "Out of the picture · waiting for them to return"
        case .searching: "Looking for them again"
        }
    }

    // MARK: Player

    /// The player the bottom bar is about: the selected drawing's player, or
    /// the saved player picked on the video.
    private var activePlayer: AnalysisTrackingLibrary.Player? {
        let id = selected.map { $0.playerMotion?.trackID } ?? selectedPlayerTrackID
        guard selected == nil || selected?.playerMotion != nil, let id else { return nil }
        return clip.trackingLibrary?.players.first { $0.id == id }
    }

    private func playerMenu(_ player: AnalysisTrackingLibrary.Player) -> some View {
        Menu {
            Button("Rename", systemImage: "pencil") { draftName = player.name; renamingPlayer = player.id }
            if let selected {
                Button("Style this effect", systemImage: "paintpalette") { showProperties = true }
                Button("Play this effect", systemImage: "play") { playback.playRange(from: selected.start, to: selected.end) }
            }
            Button("Remove highlight", systemImage: "trash", role: .destructive) { removeHighlights(of: player.id) }
                .accessibilityIdentifier("analysis-remove-selected-player")
        } label: { AnalysisMoreLabel() }
            .buttonStyle(.plain).accessibilityIdentifier("analysis-layer-options")
    }

    private var fixLostSections: [ClosedRange<Double>] {
        guard let id = correctingTrackID, let motion = clip.trackingLibrary?.players.first(where: { $0.id == id })?.motion else { return [] }
        return AnalysisTrackingStrip.lostSections(motion, range: clipRange)
    }

    private func fixPrompt(_ id: UUID) -> some View {
        let lost = fixLostSections
        return AnalysisPromptBar(title: "Where is \(playerName(id))?",
                                 message: "Go to a frame where they're visible and tap them. Following continues from there.",
                                 identifier: "analysis-fix-prompt", cancel: endFix) {
            if !lost.isEmpty {
                Button("Next lost part", systemImage: "arrow.right.to.line") {
                    let next = lost.first { $0.lowerBound > time + 0.05 } ?? lost[0]
                    seek(min(next.upperBound, next.lowerBound + 0.05))
                }.labelStyle(.iconOnly).buttonStyle(EditorActionStyle())
                    .accessibilityIdentifier("analysis-next-gap")
            }
        }
    }

    private func openPlayerEffects(for player: AnalysisTrackingLibrary.Player) {
        let motion = player.motion
        let effectTime: Double
        if motion.box(at: time) != nil { effectTime = time }
        else if let nearest = motion.samples.filter({ clipRange.contains($0.time) && motion.box(at: $0.time) != nil })
                    .min(by: { abs($0.time - time) < abs($1.time - time) }) { effectTime = nearest.time }
        else { show("\(player.name) isn't followed anywhere yet. Tap Fix to find them."); return }
        selectedPlayerTrackID = player.id
        selectedPlayer = .init(time: effectTime, box: motion.box(at: effectTime) ?? .zero)
        if effectTime != time { seek(effectTime) }
        showPlayerEffects = true
    }

    private func removeHighlights(of id: UUID) {
        let ids = Set(clip.annotations.filter { $0.playerMotion?.trackID == id && $0.isLocked != true }.map(\.id))
        checkpoint()
        clip.annotations.removeAll { ids.contains($0.id) }
        _ = clip.removePlayerTrack(id)
        selectedID = nil; selectedPlayer = nil; selectedPlayerTrackID = nil
    }

    // MARK: Drawing

    private func drawingBar(_ selected: AnalysisAnnotation) -> some View {
        VStack(spacing: 0) {
            AnalysisSelectionBar(title: selected.title, symbol: selected.tool.symbol, close: clearSelection) {
                if selected.tool != .trajectory { movementMenu(selected) }
                Button("Style", systemImage: "paintpalette") { showProperties = true }
                    .labelStyle(AnalysisCompactLabelStyle())
                    .buttonStyle(EditorActionStyle()).accessibilityIdentifier("analysis-drawing-style")
                layerMenu(selected)
            }.disabled(isBusy)
            if selected.tool == .zone, selected.fieldLines != true, selected.linkedPlayers == nil {
                HStack(spacing: 12) {
                    Text(selectedVertex.map { "Corner \($0 + 1)" } ?? "Tap a corner to edit it").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Add corner", systemImage: "plus") {
                        let index = selectedVertex ?? max(0, selected.points.count - 1)
                        updateSelected { $0.insertPolygonCorner(after: index) }; selectedVertex = index + 1
                    }.disabled(selected.points.count >= 12)
                    Button("Remove corner", systemImage: "minus") {
                        guard let index = selectedVertex else { return }
                        updateSelected { $0.removePolygonCorner(at: index) }; selectedVertex = nil
                    }.labelStyle(.iconOnly).disabled(selectedVertex == nil || selected.points.count <= 3)
                }.buttonStyle(AnalysisControlStyle()).padding(.horizontal, 12).disabled(selected.isLocked == true)
            }
            if selected.motionMode == .keyframes {
                HStack(spacing: 12) {
                    Button("Previous position", systemImage: "backward.end") { stepKeyframe(-1) }.labelStyle(.iconOnly)
                    Button("Set position here", systemImage: "diamond") { addKeyframe() }.accessibilityIdentifier("analysis-add-keyframe")
                    Button("Next position", systemImage: "forward.end") { stepKeyframe(1) }.labelStyle(.iconOnly)
                    Spacer(minLength: 0)
                    Button("Remove position", systemImage: "diamond.slash") { deleteKeyframe() }.labelStyle(.iconOnly).disabled(selectedKeyframe == nil)
                }.buttonStyle(AnalysisControlStyle()).padding(.horizontal, 12)
                    .disabled(selected.isLocked == true || time < selected.start || time > selected.end)
            }
        }
    }

    private func movementTitle(_ mode: AnnotationMotionMode) -> String {
        switch mode {
        case .still: "Stays put"
        case .camera: "On the pitch"
        case .player: "Follows player"
        case .keyframes: "Animated"
        }
    }

    private func movementMenu(_ selected: AnalysisAnnotation) -> some View {
        Menu {
            Button("Stay put on screen", systemImage: "pin") { setMotionMode(.still) }
            if clip.freezeDuration == nil {
                Button("Stick to the pitch as the camera moves", systemImage: "sportscourt") { setMotionMode(.camera) }
                Button(selected.playerMotion == nil ? "Follow a player" : "Follow a different player", systemImage: "figure.run") { setMotionMode(.player) }
            }
            Button("Animate by hand", systemImage: "diamond") { setMotionMode(.keyframes) }
        } label: {
            Label(movementTitle(selected.motionMode), systemImage: "move.3d").labelStyle(.titleAndIcon).fixedSize()
        }
        .buttonStyle(EditorActionStyle()).disabled(selected.isLocked == true)
        .accessibilityLabel("Movement").accessibilityValue(movementTitle(selected.motionMode))
        .accessibilityIdentifier("analysis-motion-mode")
    }

    private func layerMenu(_ selected: AnalysisAnnotation) -> some View {
        Menu {
            if clip.freezeDuration == nil {
                Button("Play this drawing", systemImage: "play") { playback.playRange(from: selected.start, to: selected.end) }
            }
            Button("Start here", systemImage: "arrow.right.to.line") { changeTiming { $0.start = max(clip.startSeconds, min(time, $0.end - 1 / 30)) } }
                .disabled(selected.isLocked == true)
            Button("End here", systemImage: "arrow.left.to.line") { changeTiming { $0.end = min(clip.annotationEnd, max(time, $0.start + 1 / 30)) } }
                .disabled(selected.isLocked == true)
            Button("Duplicate", systemImage: "plus.square.on.square", action: duplicate)
            if selected.motionMode == .camera {
                Button("Re-check camera movement", systemImage: "arrow.clockwise") { ensureSharedCameraTracking(force: true) }
                    .accessibilityIdentifier("analysis-correct-tracking")
            }
            Button(selected.isLocked == true ? "Unlock" : "Lock", systemImage: selected.isLocked == true ? "lock.open" : "lock") { toggleLayerLocked(selected.id) }
            Button("Delete", systemImage: "trash", role: .destructive) { deleteSelected() }
                .disabled(selected.isLocked == true).accessibilityIdentifier("analysis-delete-layer")
        } label: { AnalysisMoreLabel() }
            .buttonStyle(.plain).accessibilityIdentifier("analysis-layer-options")
    }

    private func clearSelection() {
        selectedID = nil; selectedPlayer = nil; selectedPlayerTrackID = nil
        selectedKeyframe = nil; correctingPlayer = false; tool = .select
    }

    private func deleteSelected() {
        guard let selected, selected.isLocked != true else { return }
        checkpoint(); clip.annotations.removeAll { $0.id == selected.id }; selectedID = nil; selectedPlayer = nil
    }

    private var layerTimeline: some View {
        AnalysisLayerTimeline(annotations: clip.annotations, bounds: clip.startSeconds...clip.annotationEnd, time: time,
                    selectedID: selectedID, selectedKeyframe: selectedKeyframe,
                    select: selectTimelineLayer, seek: { seek($0) }, previewSeek: previewSeek,
                    beginEdit: { playback.pause(); checkpoint() }, edit: editTimelineLayer,
                    selectKeyframe: selectTimelineKeyframe, toggleHidden: toggleLayerHidden,
                    toggleLocked: toggleLayerLocked, reorder: reorderLayer,
                    freezeTime: clip.freezeDuration == nil ? nil : clip.startSeconds,
                    zoom: $timelineZoom)
                    .frame(maxHeight: .infinity).disabled(isBusy)
    }

    // MARK: Pitch

    private func openPitch() {
        playback.pause()
        if clip.groundCalibration == nil { fieldPreviewEnabled = true; openMeasurements() }
        else { showPitchOptions = true }
    }

    private func toggleFieldPreview() {
        if clip.groundCalibration == nil { fieldPreviewEnabled = true; openMeasurements() }
        else {
            fieldPreviewEnabled.toggle()
            if fieldPreviewEnabled, clip.groundCalibration?.fixedCamera == false { ensureSharedCameraTracking() }
        }
    }

    // MARK: - Style sheet

    @ViewBuilder private var inspectorStyle: some View {
        if selected?.isLocked == true {
            Section { Label("Unlock this drawing (⋯ → Unlock) to change it.", systemImage: "lock").foregroundStyle(.secondary) }
        }
        inspectorText
        inspectorAppearance
        inspectorEffect
        inspectorMeasurements
    }

    @ViewBuilder private var inspectorText: some View {
        if selected?.tool == .text {
            Section("Text") {
                TextField("Text", text: Binding(get: { selected?.text ?? "" }, set: { value in updateSelected { $0.text = value } }), axis: .vertical)
                    .lineLimit(2...5).accessibilityIdentifier("analysis-text-input")
                AnalysisTextControls(style: Binding(get: { selected?.resolvedTextStyle ?? .init() }, set: { value in
                    updateSelected(recordUndo: !editingTextSize) { $0.textStyle = value }
                }), sizeEditingChanged: { editing in
                    if editing { checkpoint() }
                    editingTextSize = editing
                })
            }.disabled(selected?.isLocked == true)
        }
    }

    @ViewBuilder private var inspectorMeasurements: some View {
        if let selected, selected.tool == .text || [.line, .arrow, .connection, .zone].contains(selected.tool) {
            Section("Measurements") {
                if selected.tool == .text {
                    Toggle("Show player speed", isOn: Binding(get: { self.selected?.showsSpeed == true }, set: { value in updateSelected { $0.showsSpeed = value } }))
                        .disabled(clip.freezeDuration != nil || selected.playerMotion == nil)
                } else if selected.fieldLines != true {
                    Toggle("Show distances in metres", isOn: Binding(get: { self.selected?.showsDistance == true }, set: { value in
                        updateSelected { $0.showsDistance = value }
                        if value, clip.groundCalibration == nil { showProperties = false; openMeasurements() }
                    })).accessibilityIdentifier("analysis-show-distance")
                }
                if clip.groundCalibration == nil {
                    Text("Needs the pitch lined up first (Pitch in the bottom bar).").font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(selected.isLocked == true)
        }
    }

    @ViewBuilder private var inspectorAppearance: some View {
        if let selected, selected.tool != .zoom, selected.tool != .loupe {
            Section("Colour") {
                AnalysisColorSwatches(color: Binding(get: { self.selected?.color ?? color }, set: { value in
                    color = value; updateSelected { $0.color = value }
                }))
            }.disabled(selected.isLocked == true)
            if selected.tool != .text {
                Section("Thickness") {
                    Picker("Thickness", selection: Binding(get: { Self.thickness(for: self.selected?.width ?? width) }, set: { value in
                        width = value; updateSelected { $0.width = value }
                    })) {
                        Text("Thin").tag(0.004)
                        Text("Medium").tag(0.008)
                        Text("Thick").tag(0.014)
                    }.pickerStyle(.segmented).accessibilityIdentifier("analysis-thickness")
                }.disabled(selected.isLocked == true)
            }
        }
    }

    private static func thickness(for width: Double) -> Double {
        [0.004, 0.008, 0.014].min { abs($0 - width) < abs($1 - width) } ?? 0.008
    }

    @ViewBuilder private var inspectorEffect: some View {
        if let selected {
            if [.line, .arrow, .pen, .connection, .zone, .rectangle, .ellipse].contains(selected.tool), selected.fieldLines != true {
                Section("Line") {
                    AnalysisLineControls(mark: selected, style: { value in updateSelected(recordUndo: false) { $0.lineStyle = value } }, beginEdit: checkpoint)
                }
            }
            if selected.tool == .zoom {
                Section("Zoom") {
                    AnalysisZoomControls(mark: selected,
                        amount: { value in updateSelected(recordUndo: false) { $0.zoomScale = value } },
                        ramp: { value in updateSelected(recordUndo: false) { $0.zoomRamp = value } }, beginEdit: checkpoint)
                }
            } else if selected.tool == .loupe {
                Section("Magnifier") {
                    AnalysisLoupeControls(style: Binding(get: { self.selected?.loupeStyle ?? .init() }, set: { value in
                        updateSelected(recordUndo: false) { $0.loupeStyle = value }
                    }), beginEdit: checkpoint).disabled(selected.isLocked == true)
                }
            } else if selected.tool == .trajectory {
                Section("Trail") {
                    AnalysisTrajectoryControls(style: Binding(get: { self.selected?.trajectoryStyle ?? .init() }, set: { value in updateSelected { $0.trajectoryStyle = value } }))
                        .disabled(selected.isLocked == true)
                }
            } else if selected.tool != .text {
                Section("Effect") {
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
        }
    }

    private func setGrounding(_ enabled: Bool) {
        updateSelected { $0.setGrounding(enabled, at: time, ground: clip.groundCalibration) }
    }

    @ViewBuilder private var inspectorTiming: some View {
        if let selected {
            Section {
                LabeledContent("Shows", value: "\(timelineTimecode(selected.start - clip.startSeconds, includesTenths: true)) – \(timelineTimecode(selected.end - clip.startSeconds, includesTenths: true))")
                    .accessibilityIdentifier("analysis-layer-range")
                HStack(spacing: 8) {
                    Button("Start here") { changeTiming { $0.start = max(clip.startSeconds, min(time, $0.end - 1 / 30)) } }
                        .accessibilityIdentifier("analysis-layer-in")
                    Button("End here") { changeTiming { $0.end = min(clip.annotationEnd, max(time, $0.start + 1 / 30)) } }
                        .accessibilityIdentifier("analysis-layer-out")
                    Button("Whole clip") { changeTiming { $0.start = clip.startSeconds; $0.end = clip.annotationEnd } }
                }.buttonStyle(EditorActionStyle()).frame(maxWidth: .infinity)
                if selected.tool != .zoom {
                    Toggle("Fade in and out", isOn: Binding(get: { self.selected?.fade ?? false }, set: { value in updateSelected { $0.fade = value } }))
                }
            } header: { Text("When it shows") } footer: {
                Text("\"Here\" is the current frame. You can also drag the ends of its bar on the timeline.")
            }.disabled(selected.isLocked == true)
        }
    }

    @ViewBuilder private var freezeControls: some View {
        if clip.freezeDuration != nil {
            Stepper("Hold the frame for \((clip.freezeDuration ?? 5).formatted()) s", value: Binding(get: { clip.freezeDuration ?? 5 }, set: { value in
                checkpoint()
                let oldEnd = clip.annotationEnd; clip.freezeDuration = value
                for index in clip.annotations.indices where clip.annotations[index].end >= oldEnd - 0.01 { clip.annotations[index].end = clip.annotationEnd }
                freezeTime = min(freezeTime, clip.annotationEnd)
            }), in: 1...30, step: 1)
            .font(.subheadline).padding(.horizontal, 12).frame(minHeight: 44)
            .accessibilityIdentifier("analysis-freeze-hold")
        }
    }

    // MARK: - Construction (areas and connected players)

    private var constructionPreview: [AnalysisAnnotation] {
        guard !constructionPoints.isEmpty else { return [] }
        var mark = AnalysisAnnotation(id: constructionID, tool: tool, points: constructionPoints, color: color, width: width, start: time, end: time + 1)
        mark.effect = .neon
        return [mark]
    }

    @ViewBuilder private var constructionControls: some View {
        if tool == .connection || tool == .zone {
            HStack(spacing: 12) {
                if tool == .zone {
                    Toggle("Use players", isOn: $areaUsesPlayers).font(.subheadline).fixedSize()
                        .onChange(of: areaUsesPlayers) { constructionPoints = []; constructionPlayers = []; detect() }
                }
                Text("\(constructionPoints.count) \(tool == .connection || areaUsesPlayers ? "player" : "corner")\(constructionPoints.count == 1 ? "" : "s")").font(.subheadline)
                    .accessibilityIdentifier("analysis-construction-count")
                Spacer(minLength: 0)
                Button("Remove last point", systemImage: "arrow.uturn.backward") {
                    if !constructionPoints.isEmpty { constructionPoints.removeLast() }
                    if !constructionPlayers.isEmpty { constructionPlayers.removeLast() }
                }.labelStyle(.iconOnly).disabled(constructionPoints.isEmpty)
                Button("Finish", action: finishConstruction)
                    .buttonStyle(EditorActionStyle(prominent: true))
                    .disabled(constructionPoints.count < (tool == .zone ? 3 : 2))
                    .accessibilityIdentifier("analysis-finish-construction")
            }.padding(.horizontal, 12).frame(height: 52).background(Theme.inkPanel)
        }
    }

    private func finishConstruction() {
        var mark = AnalysisAnnotation(tool: tool, points: constructionPoints, color: color, width: width,
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

    // MARK: - Canvas touches

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
        guard initialised, !isBusy, frame.contains(startLocation) || editsOffscreenField else { return }
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
            draft = AnalysisAnnotation(tool: tool, points: [start], color: color, width: width, text: tool == .text ? "Text" : "", start: min(time, clip.annotationEnd - 0.05), end: min(clip.annotationEnd, time + 4))
        }
        if tool == .pen { draft?.points.append(point) }
        else { draft?.points = tool == .zoom || tool == .loupe ? [point] : [start, point] }
    }

    private func endCanvasDrawing(startLocation: CGPoint, location: CGPoint, frame: CGRect) {
        defer { draft = nil; dragOriginal = nil; dragVertex = nil; dragFrame = nil }
        guard initialised, !isBusy, frame.contains(startLocation) || editsOffscreenField else { return }
        let start = normalise(startLocation, frame: frame)
        let end = normalise(location, frame: frame)
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        if pickingPlayerTrack {
            guard !playback.isSeeking, draft != nil else { return }
            guard box.width > 0.003, box.height > 0.01 else { tapCanvas(startLocation, frame: frame); return }
            if let id = correctingTrackID { fixPlayer(id, seed: box) }
            return
        }
        if correctingPlayer, selectedID != nil {
            guard box.width > 0.003, box.height > 0.01 else { return }
            selectPlayer(box)
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
        }.min { $0.1 < $1.1 }.flatMap { $0.1 <= 26 ? $0.0 : nil }
    }
    private func tapCanvas(_ location: CGPoint, frame: CGRect) {
        guard initialised, !isBusy, frame.contains(location) || editsOffscreenField else { return }
        playback.pause()
        let point = normalise(location, frame: frame)
        if pickingPlayerTrack {
            guard !playback.isSeeking else { return }
            if let box = player(at: point), let id = correctingTrackID { fixPlayer(id, seed: box) }
            else { show("No player found there. Draw a box around them instead.") }
            return
        }
        if tool == .zone || tool == .connection {
            guard constructionPoints.count < 12 else { return }
            if tool == .connection || areaUsesPlayers {
                guard let box = player(at: point) else { show("Tap a player. If one isn't picked up, move a frame and try again."); return }
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
            } else if !correctingPlayer { selectedID = nil; selectedPlayer = nil; selectedPlayerTrackID = nil }
            return
        }
        if tool == .player {
            if let box = player(at: point) { selectPlayer(box) }
            else { show("No player found there. Draw a box around them instead.") }
            return
        }
        guard [.text, .spotlight, .pen, .zoom, .loupe].contains(tool) else { return }
        var mark = AnalysisAnnotation(tool: tool, points: [point], color: color, width: width, text: tool == .text ? "Text" : "", start: min(time, clip.annotationEnd - 0.05), end: min(clip.annotationEnd, time + 4))
        if tool == .loupe {
            selectedPlayer = player(at: point).map { .init(time: time, box: $0) }
        }
        if tool == .spotlight {
            if let player = detections.filter({ $0.rect.insetBy(dx: -0.015, dy: -0.015).contains(point) }).min(by: { $0.rect.width < $1.rect.width }) {
                mark.points = [player.rect.origin, CGPoint(x: player.rect.maxX, y: player.rect.maxY)]
            } else { mark.points = [CGPoint(x: point.x - 0.022, y: point.y - 0.10), CGPoint(x: point.x + 0.022, y: point.y)] }
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
        endFix()
        constructionPoints = []; constructionPlayers = []
        selectedID = mark.id; tool = .select
        if time < mark.start || time >= mark.end { seek(min(clip.annotationEnd - 0.02, max(clip.startSeconds, mark.start))) }
        selectedPlayer = (mark.playerMotion?.box(at: time) ?? (mark.playerMotion == nil ? mark.playerEffectBox : nil)).map { .init(time: time, box: $0) }
        selectedPlayerTrackID = mark.playerMotion?.trackID
    }

    // MARK: - Editing

    private func checkpoint() { undo.append(clip); if undo.count > 60 { undo.removeFirst() }; redo = [] }
    private func undoEdit() {
        guard let previous = undo.popLast() else { return }
        endFix()
        redo.append(clip); clip = previous; selectedID = nil
    }
    private func redoEdit() {
        guard let next = redo.popLast() else { return }
        endFix()
        undo.append(clip); clip = next; selectedID = nil
    }
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
        guard let mark = selected, let motion = mark.playerMotion, mark.playerEffectGroupID == nil else { return }
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
        // Player highlights share the clip's player track; only one-off
        // drawings that follow a player extend their own motion here.
        guard finished, mark.playerEffectGroupID == nil, let motion = mark.playerMotion, motion.lostAt == nil,
              let last = motion.samples.last, mark.end > last.time + 0.12 else { return }
        beginTracking(id: mark.id, seed: last.box, from: last.time)
    }
    private func selectTimelineKeyframe(_ layer: UUID, _ frame: UUID, _ seconds: Double) {
        endFix()
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
            if time < mark.start || time >= mark.end { seek(mark.start) }
            // Picking a player next replaces whatever this drawing followed before.
            if mark.playerMotion != nil { updateSelected { $0.makeStatic(at: time) } }
            correctingPlayer = true; showsPlayers = true; detect()
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
    private func detect() {
        let start = max(clip.startSeconds, detectionTime - 0.05)
        let end = min(request.recording.duration, detectionTime + 0.1)
        if end > start { session.analyze(recording: request.recording, range: start...end) }
    }
    private func player(at point: CGPoint) -> CGRect? {
        PlayerSelection.box(at: point, among: detections.map(\.rect), aspectRatio: displayAspect)
    }
    private func selectPlayer(_ box: CGRect) {
        if pickingPlayerTrack {
            guard !playback.isSeeking, let id = correctingTrackID else { return }
            fixPlayer(id, seed: box); return
        }
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
        endFix()
        canvasNavigation = nil
        correctingPlayer = false
        constructionPoints = []; constructionPlayers = []
        selectedID = nil; selectedPlayer = nil; selectedPlayerTrackID = nil
        if AnalysisDrawingTool.drawShapes.contains(item) { lastDrawTool = item }
        if item == .zoom { canvasZoom = 1; zoomCenter = CGPoint(x: 0.5, y: 0.5) }
        tool = item
        if item == .player || item == .zone || item == .connection {
            showsPlayers = true
            if analysis?.frame(at: detectionTime) == nil { detect() }
        }
    }

    private func applyPlayerEffects(_ options: AnalysisPlayerEffects) {
        guard let player = selectedPlayer, !isBusy else { return }
        let saved = reusablePlayer(box: player.box, at: time)
        checkpoint()
        if clip.freezeDuration == nil, saved == nil, !options.tools.isEmpty {
            // Show the highlight straight away on a one-frame track, then let
            // the pass extend it: the effect follows the player as the video runs.
            let id = UUID()
            let seed = PlayerMotion(samples: [.init(time: time, box: player.box)], trackID: id)
            clip.storePlayerTrack(seed)
            selectedID = clip.applyPlayerEffects(options, replacing: [], box: player.box, motion: seed, at: time)
            selectedPlayerTrackID = id; tool = .select
            nameFromLabel(options, player: id)
            followPlayer(id, seed: player.box, from: time)
        } else {
            selectedID = clip.applyPlayerEffects(options, replacing: Set(playerEffectLayers.map(\.id)),
                                                 box: player.box, motion: saved?.motion, at: time)
            selectedPlayerTrackID = saved?.id; tool = .select
            if let id = saved?.id { nameFromLabel(options, player: id) }
        }
    }
    /// A typed name label is the player's name too, so the bar and later
    /// highlights use it.
    private func nameFromLabel(_ options: AnalysisPlayerEffects, player id: UUID) {
        let name = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard options.label, !name.isEmpty,
              let index = clip.trackingLibrary?.players.firstIndex(where: { $0.id == id }) else { return }
        clip.trackingLibrary?.players[index].name = name
    }

    private func insertMark(_ mark: AnalysisAnnotation) {
        var mark = mark
        if mark.tool == .zoom { mark.zoomScale = 2; mark.zoomRamp = 0.35; selectedPlayer = nil }
        if mark.tool == .player, mark.effect == nil { mark.effect = .radar }
        if mark.tool == .loupe { mark.loupeStyle = mark.loupeStyle ?? .init() }
        checkpoint(); clip.annotations.append(mark); selectedID = mark.id; tool = .select
        if mark.tool == .text { showProperties = true }
        guard clip.freezeDuration == nil, mark.playerMotion == nil else { return }
        if mark.tool == .spotlight, let first = mark.points.first, let last = mark.points.last {
            let seed = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            selectedPlayer = .init(time: time, box: seed)
            attachOrTrack(id: mark.id, seed: seed)
        } else if mark.tool == .loupe, let player = selectedPlayer { attachOrTrack(id: mark.id, seed: player.box) }
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

    private func renamePlayerTrack(_ id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = clip.trackingLibrary?.players.firstIndex(where: { $0.id == id }),
              clip.trackingLibrary?.players[index].name != name else { return }
        checkpoint(); clip.trackingLibrary?.players[index].name = name
    }

    // MARK: - Following players

    /// Follow a player through the whole clip: forward first, so the video
    /// plays along with the pass, then back to the start. Stop keeps both.
    private func followPlayer(_ id: UUID, seed: CGRect, from start: Double) {
        followOrigin = start
        let backward = {
            guard start - clip.startSeconds > 0.1, let player = clip.trackingLibrary?.players.first(where: { $0.id == id }),
                  let box = player.motion.box(at: start) else { finishFollowing(id); return }
            var motion = player.motion; motion.identity = player.identity
            runPlayerTracking(id: id, seed: box, from: start, to: clip.startSeconds, direction: .backward,
                              prior: motion, recordUndo: false) { finishFollowing(id) }
        }
        if start < clip.endSeconds - 0.1 {
            runPlayerTracking(id: id, seed: seed, from: start, to: clip.endSeconds, direction: .forward,
                              prior: nil, confirmedSeed: true, recordUndo: false, then: backward)
        } else { backward() }
    }

    private func beginFix(_ id: UUID) {
        guard !isBusy, clip.freezeDuration == nil else { return }
        playback.pause(); tool = .select; correctingPlayer = false
        constructionPoints = []; constructionPlayers = []; canvasNavigation = nil
        selectedID = nil; selectedPlayerTrackID = id
        correctingTrackID = id; pickingPlayerTrack = true; showsPlayers = true
        detect()
    }

    private func endFix() { pickingPlayerTrack = false; correctingTrackID = nil }

    /// The coach showed where the player really is on this frame. Inside a
    /// lost part, only that part is filled in (the rest is kept). On a frame
    /// that was followed, the track was on someone else: follow again from here.
    private func fixPlayer(_ id: UUID, seed: CGRect) {
        guard let player = clip.trackingLibrary?.players.first(where: { $0.id == id }) else { endFix(); return }
        let start = time
        var motion = player.motion; motion.identity = player.identity
        let section = motion.missingIntervals(in: clipRange).first { $0.contains(start) }
        endFix()
        checkpoint()
        followOrigin = start
        selectedPlayerTrackID = id
        guard let section else {
            let prior = motion.preparingCorrection(at: start, direction: .forward)
            runPlayerTracking(id: id, seed: seed, from: start, to: clip.endSeconds, direction: .forward,
                              prior: prior, confirmedSeed: true, recordUndo: false) { finishFollowing(id) }
            return
        }
        // The tap itself is certain; keep it even if following fails at once.
        motion.place(seed, at: start)
        clip.storePlayerTrack(motion)
        let backward = {
            guard start - section.lowerBound > 0.05,
                  let saved = clip.trackingLibrary?.players.first(where: { $0.id == id }) else { finishFollowing(id); return }
            var prior = saved.motion; prior.identity = saved.identity
            runPlayerTracking(id: id, seed: seed, from: start, to: section.lowerBound, direction: .backward, prior: prior,
                              confirmedSeed: true, fillOnlyRange: section, recordUndo: false) { finishFollowing(id) }
        }
        if section.upperBound - start > 0.05 {
            runPlayerTracking(id: id, seed: seed, from: start, to: min(clip.endSeconds, section.upperBound), direction: .forward,
                              prior: motion, confirmedSeed: true, fillOnlyRange: section, recordUndo: false, then: backward)
        } else { backward() }
    }

    private func finishFollowing(_ id: UUID, stopped: Bool = false) {
        if let origin = followOrigin { seek(origin) }
        followOrigin = nil
        selectedPlayerTrackID = id
        guard let player = clip.trackingLibrary?.players.first(where: { $0.id == id }) else { return }
        selectedPlayer = player.motion.box(at: time).map { .init(time: time, box: $0) }
        let lost = AnalysisTrackingStrip.lostSections(player.motion, range: clipRange).count
        if stopped { show("Stopped. \(player.name) is kept up to there.") }
        else if lost == 0 { show("\(player.name) followed through the whole clip") }
        else { show("\(player.name) was lost in \(lost) \(lost == 1 ? "place" : "places"). Tap Fix to show where they are.") }
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
    /// runs and the playhead follows the tracked frame, so the highlight moves
    /// with the video and stopping keeps everything up to that point.
    /// `then` runs after a pass that finished on its own (not stopped).
    private func runPlayerTracking(id: UUID, seed: CGRect, from start: Double, to end: Double,
                                   direction: PlayerTrackingDirection,
                                   prior: PlayerMotion?,
                                   confirmedSeed: Bool = false,
                                   fillOnlyRange: ClosedRange<Double>? = nil,
                                   recordUndo: Bool = true,
                                   then continuation: (() -> Void)? = nil) {
        guard clip.freezeDuration == nil, abs(end - start) > 0.05 else { continuation?(); return }
        let url = request.recording.fileURL
        let job = UUID()
        session.cancel(); playback.pause()
        selectedPlayerTrackID = id
        selectedPlayer = .init(time: start, box: seed)
        trackingID = id; trackingJob = job; trackingProgress = 0
        trackingPhase = .following
        if recordUndo { checkpoint() }
        trackingStoredAt = Date.timeIntervalSinceReferenceDate

        trackingTask = Task { @MainActor in
            defer {
                if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil }
            }
            do {
                let publish: @Sendable (PlayerTrackingCheckpoint) -> Void = { update in
                    Task { @MainActor in
                        guard trackingJob == job else { return }
                        trackingProgress = update.fraction
                        trackingPhase = update.phase
                        previewSeek(update.time)
                        guard let partial = update.motion, partial.samples.count > 1 else { return }
                        let combined = folded(partial, into: prior, id: id, from: start, direction: direction,
                                              fillOnlyRange: fillOnlyRange)
                        selectedPlayer = combined.box(at: update.time).map { .init(time: update.time, box: $0) }
                        // Store often so the highlight itself follows the
                        // player live, and a killed pass still leaves its work.
                        let now = Date.timeIntervalSinceReferenceDate
                        guard now - trackingStoredAt >= 0.4 else { return }
                        trackingStoredAt = now
                        clip.storePlayerTrack(combined)
                    }
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try await SelectedPlayerTracking.track(url: url, seed: seed, from: start, to: end,
                                                           direction: direction, prior: prior, includeBodyMasks: false,
                                                           confirmedSeed: confirmedSeed, checkpoint: publish)
                }
                let outcome = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard trackingJob == job else { return }
                let combined = folded(outcome.motion, into: prior, id: id, from: start, direction: direction,
                                      fillOnlyRange: fillOnlyRange)
                clip.storePlayerTrack(combined); selectedPlayerTrackID = id
                trackingID = nil; trackingTask = nil; trackingJob = nil
                if outcome.stopped { finishFollowing(id, stopped: true) }
                else if let continuation {
                    // The next pass starts once this one has released tracking.
                    Task { @MainActor in await Task.yield(); continuation() }
                } else { finishFollowing(id) }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription; followOrigin = nil }
        }
    }

    /// Drawings that follow a player on their own (not a highlight): a
    /// one-off pass bound to the drawing, stored as a clip player.
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
            clip.annotations[index].playerMotion = PlayerMotion(samples: [.init(time: start, box: seed)], lostAt: start + 0.1, trackID: trackID)
        }
        let job = UUID()
        trackingID = trackID; trackingJob = job; trackingProgress = 0; trackingPhase = .following
        selectedPlayerTrackID = trackID
        let url = request.recording.fileURL, end = clip.endSeconds
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await SelectedPlayerTracking.track(url: url, seed: seed, from: start, to: end, prior: prior, includeBodyMasks: false, confirmedSeed: confirmedSeed) { fraction in
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
                    show("Lost the player at \(timelineTimecode(lost - clip.startSeconds, includesTenths: true)). Tap Fix to show where they are.")
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
        let job = UUID(); trackingID = id; trackingJob = job; trackingProgress = 0; trackingPhase = .following
        let url = request.recording.fileURL
        let end = clip.endSeconds
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
                        let motion = try await SelectedPlayerTracking.track(url: url, seed: trackingSeed.box, from: trackingSeed.time, to: end, prior: prior, includeBodyMasks: false, confirmedSeed: confirmed) { fraction in
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
                    correctingPlayer = true; tool = .select; detect()
                } else if let failed = motions.enumerated().filter({ $0.element.lostAt != nil }).min(by: { ($0.element.lostAt ?? .infinity) < ($1.element.lostAt ?? .infinity) }),
                   let lost = failed.element.lostAt {
                    correctingAnchor = failed.offset
                    seek(failed.element.correctionTime ?? lost)
                    correctingPlayer = true; tool = .select; detect()
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    // MARK: - Camera and pitch

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

    /// Pitch setup, the pitch lines and "Stick to the pitch" all use this single
    /// camera pass. Calibration/binding time only defines geometry; it never limits coverage.
    private func ensureSharedCameraTracking(force: Bool = false, pending: AnalysisAnnotation? = nil, bindTime: Double? = nil) {
        guard clip.freezeDuration == nil, !isBusy else { return }
        if !force, clip.hasFullCameraTrack {
            if pending != nil { checkpoint() }
            clip.refreshSharedCameraBindings()
            attachToClipCamera(pending, at: bindTime)
            return
        }
        checkpoint(); trackingTask?.cancel(); session.cancel(); playback.pause()
        let job = UUID(), url = request.recording.fileURL, range = clip.cameraTrackingRange
        trackingID = job; trackingJob = job; trackingProgress = 0; trackingPhase = .following
        readingCamera = true
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil; readingCamera = false } }
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
                    show(adopted
                        ? "Camera movement could only be followed up to \(timelineTimecode(lost - clip.startSeconds, includesTenths: true)). A cut or blocked view can cause this."
                        : "Couldn't follow the camera further than before; the earlier result is kept.")
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private var measurementStatus: String? {
        guard let calibration = clip.groundCalibration else { return nil }
        return calibration.isApproximate ? "Approximate measurements" : "Measured from the pitch"
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
            if analysis?.frame(at: request.seconds) == nil { detect() }
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
            func mapped(_ box: CGRect) -> CGRect {
                CGRect(x: content.frame.minX + box.minX * content.frame.width, y: content.frame.minY + box.minY * content.frame.height,
                       width: box.width * content.frame.width, height: box.height * content.frame.height)
            }
            // Tappable players: soft rounded outlines, so the video stays readable.
            context.setLineWidth(1.5)
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.7).cgColor)
            for detection in content.detections {
                context.addPath(UIBezierPath(roundedRect: mapped(detection.rect).insetBy(dx: -2, dy: -2), cornerRadius: 6).cgPath)
                context.strokePath()
            }
            if let box = content.selectedPlayer {
                context.setStrokeColor(UIColor(Theme.signal).cgColor); context.setLineWidth(2.5)
                context.addPath(UIBezierPath(roundedRect: mapped(box).insetBy(dx: -4, dy: -4), cornerRadius: 8).cgPath)
                context.strokePath()
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
                    let handle = CGRect(x: content.frame.minX + point.x * content.frame.width - 8, y: content.frame.minY + point.y * content.frame.height - 8, width: 16, height: 16)
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
