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
    @State private var showPlayerEffects = false
    @State private var pickingPlayerTrack = false
    @State private var correctingTrackID: UUID?
    @State private var trackingTask: Task<Void, Never>?
    @State private var trackingID: UUID?
    @State private var trackingJob: UUID?
    @State private var trackingProgress = 0.0
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
    @State private var canvasTouch: (start: CGPoint, current: CGPoint, frame: CGRect)?
    @State private var canvasDragging = false
    @State private var confirmsDelete = false
    @State private var editingTextSize = false
    @State private var groundRequest: GroundCalibrationRequest?

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
    private var detections: [AnalysisDetection] { analysis?.frame(at: detectionTime)?.detections ?? [] }
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
        if pickingPlayerTrack { return correctingTrackID == nil ? "Tap or draw around a new player to track" : "Tap or draw around the same player to continue its track" }
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
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    workspaceHeader
                    canvas
                    playerActions
                    if correctingPlayer, let anchor = correctingConnectionAnchor {
                        AnalysisConnectionCorrectionCard(anchor: anchor, url: request.recording.fileURL, clipStart: clip.startSeconds, showLastSeen: { seek($0) }).id(anchor.id)
                    }
                    constructionControls
                    transport
                    layerControls
                    AnalysisLayerTimeline(annotations: clip.annotations, bounds: clip.startSeconds...clip.annotationEnd, time: time,
                                          selectedID: selectedID, selectedKeyframe: selectedKeyframe,
                                          select: selectTimelineLayer, seek: { seek($0) }, previewSeek: previewSeek,
                                          beginEdit: { playback.pause(); checkpoint() }, edit: editTimelineLayer,
                                          selectKeyframe: selectTimelineKeyframe, toggleHidden: toggleLayerHidden,
                                          toggleLocked: toggleLayerLocked, reorder: reorderLayer)
                        .frame(height: min(220, max(130, geometry.size.height * (geometry.size.width > geometry.size.height ? 0.32 : 0.28))))
                        .disabled(trackingID != nil)
                    tools
                }.background(Theme.ink)
            }
            .toolbar(.hidden, for: .navigationBar)
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
        .sheet(isPresented: $showPlayerTracks) {
            AnalysisPlayerTracksSheet(players: clip.trackingLibrary?.players ?? [], clipStart: clip.startSeconds,
                                      select: selectSavedPlayer, add: { pickPlayerTrack() },
                                      correct: { pickPlayerTrack(correcting: $0) }, rename: renamePlayerTrack)
        }
        .sheet(isPresented: $showPlayerEffects) {
            AnalysisPlayerEffectsSheet(name: selectedPlayerName, existing: playerEffectLayers, allowsTrajectory: clip.freezeDuration == nil, measurementStatus: measurementStatus, apply: applyPlayerEffects)
        }
        .fullScreenCover(item: $groundRequest) { request in
            GroundCalibrationSheet(url: self.request.recording.fileURL, request: request, apply: applyGroundCalibration)
        }
        .preferredColorScheme(.dark).tint(Theme.signal)
        .task { await prepare() }
        .onDisappear {
            // A full-screen placement editor temporarily covers this workspace.
            // Keep the time observer so playback/scrubbing still updates on return.
            if groundRequest != nil { playback.pause() }
            else { playback.stop(); session.cancel(); trackingTask?.cancel() }
        }
        .onChange(of: session.errorMessage) { if let message = session.errorMessage { error = message } }
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
            if analysis?.frame(at: detectionTime) == nil { detect(motion: false) }
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

    private var workspaceHeader: some View {
        HStack(spacing: 2) {
            Button("Cancel", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                .accessibilityIdentifier("cancel-analysis-workspace")
            Text(request.mode == .video ? "Analysis" : "Freeze frame").font(.subheadline.weight(.semibold))
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo", systemImage: "arrow.uturn.backward", action: undoEdit).labelStyle(.iconOnly).disabled(undo.isEmpty || trackingID != nil)
            Button("Redo", systemImage: "arrow.uturn.forward", action: redoEdit).labelStyle(.iconOnly).disabled(redo.isEmpty || trackingID != nil)
            Button("Save") {
                do { try save(clip); dismiss() } catch { self.error = error.localizedDescription }
            }.foregroundStyle(Theme.signal).disabled(trackingID != nil).accessibilityIdentifier("save-analysis-workspace")
        }.buttonStyle(AnalysisControlStyle()).padding(.horizontal, 6).background(Theme.inkPanel)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("analysis-compact-header")
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
                                            correcting: correctingAnchor, frame: frame).allowsHitTesting(false)
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
            if abs(canvasZoom - 1) > 0.01 || hypot(zoomCenter.x - 0.5, zoomCenter.y - 0.5) > 0.01 {
                Button("Fit preview", systemImage: "arrow.down.right.and.arrow.up.left") {
                    canvasZoom = 1; zoomCenter = CGPoint(x: 0.5, y: 0.5)
                }.labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle())
                    .accessibilityIdentifier("analysis-inspect-fit")
            }
        }.padding(8)
    }

    private var tools: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(AnalysisDrawingTool.toolbarTools) { item in
                    Button { chooseTool(item) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.symbol).font(.system(size: 16))
                            Text(item.title).font(.system(size: 10))
                        }.frame(width: 44, height: 36)
                            .foregroundStyle(tool == item ? .black : .white)
                            .background(tool == item ? Theme.signal : .white.opacity(0.06), in: .rect(cornerRadius: 9))
                        .frame(height: 44).contentShape(.rect)
                    }.buttonStyle(.plain).disabled(trackingID != nil).accessibilityIdentifier("analysis-tool-\(item.rawValue)")
                }
                Button(action: openMeasurements) {
                    VStack(spacing: 4) {
                        Image(systemName: "ruler").font(.system(size: 16))
                        Text("Measure").font(.system(size: 10))
                    }.frame(width: 48, height: 36).background(.white.opacity(0.06), in: .rect(cornerRadius: 9)).frame(height: 44).contentShape(.rect)
                }.buttonStyle(.plain).disabled(trackingID != nil).accessibilityLabel("Measurements").accessibilityIdentifier("analysis-tool-measure")
            }.padding(.horizontal, 6).padding(.vertical, 2)
        }.scrollIndicators(.hidden).background(Theme.inkPanel).accessibilityIdentifier("analysis-drawing-tools")
    }

    @ViewBuilder private var playerActions: some View {
        if trackingID != nil {
            HStack {
                ProgressView(value: trackingProgress).frame(maxWidth: 130)
                Text("Tracking motion… \(Int(trackingProgress * 100))%").font(.caption)
                Spacer()
                Button("Cancel") { trackingTask?.cancel() }.buttonStyle(AnalysisControlStyle())
            }.padding(10).background(Theme.inkPanel)
        } else if pickingPlayerTrack {
            HStack {
                Text(correctingTrackID == nil ? "New player track" : "Correct player track").font(.caption.bold())
                Spacer()
                Button("Cancel pick") { pickingPlayerTrack = false; correctingTrackID = nil }
                    .buttonStyle(AnalysisControlStyle())
            }.padding(.horizontal, 12).padding(.vertical, 4).background(Theme.inkPanel)
        } else if selectedPlayer != nil && (selectedID == nil || selected?.playerMotion != nil || selected?.playerEffectGroupID != nil) {
            HStack(spacing: 12) {
                Text(selectedPlayerName).lineLimit(1).accessibilityIdentifier("analysis-active-player-track")
                Spacer(minLength: 0)
                Button("Player effects", systemImage: "slider.horizontal.3") { showPlayerEffects = true }
                    .accessibilityIdentifier("analysis-player-effects")
                if selectedID == nil, let id = selectedPlayerTrackID {
                    Button("Correct", systemImage: "scope") { pickPlayerTrack(correcting: id) }
                        .labelStyle(.iconOnly).accessibilityIdentifier("analysis-correct-selected-player")
                }
            }.font(.caption.bold()).buttonStyle(AnalysisControlStyle()).padding(.horizontal, 10).padding(.vertical, 5).background(Theme.inkPanel)
        } else if let id = selectedPlayerTrackID, clip.freezeDuration == nil,
                  clip.trackingLibrary?.players.contains(where: { $0.id == id }) == true {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPlayerName).font(.caption.bold())
                    Text("Not tracked at this frame").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Resume here", systemImage: "scope") { pickPlayerTrack(correcting: id) }
                    .buttonStyle(AnalysisControlStyle())
                    .disabled(time >= clip.endSeconds - 0.05).accessibilityIdentifier("analysis-resume-player")
            }.padding(.horizontal, 10).padding(.vertical, 5).background(Theme.inkPanel)
        }
    }

    private var transport: some View {
        HStack(spacing: 4) {
            if clip.freezeDuration == nil {
                Button("Previous frame", systemImage: "backward.frame.fill") { seek(time - 1 / 30) }.labelStyle(.iconOnly)
                Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    if playback.isPlaying { playback.pause() }
                    else { playback.playRange(from: time >= clip.endSeconds - 0.04 ? clip.startSeconds : time, to: clip.endSeconds) }
                }.labelStyle(.iconOnly).accessibilityIdentifier("analysis-play-pause")
                Button("Next frame", systemImage: "forward.frame.fill") { seek(time + 1 / 30) }.labelStyle(.iconOnly)
            } else { Image(systemName: "pause.rectangle").accessibilityLabel("Freeze frame") }
            if let selected, clip.freezeDuration == nil {
                Button("Preview effect", systemImage: "play.rectangle") { playback.playRange(from: selected.start, to: selected.end) }.labelStyle(.iconOnly)
            }
            Spacer(minLength: 4)
            VStack(spacing: 2) {
                Text(timelineTimecode(time - clip.startSeconds, includesTenths: true))
                    .accessibilityIdentifier("analysis-current-time")
                Text("/ \(timelineTimecode(clip.annotationEnd - clip.startSeconds, includesTenths: true))").foregroundStyle(.secondary)
            }.font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button("Drawing style", systemImage: "slider.horizontal.3") { showProperties = true }.labelStyle(.iconOnly)
                .accessibilityIdentifier("analysis-drawing-style")
            Menu {
                if clip.freezeDuration == nil {
                    Button("Track new player", systemImage: "person.badge.plus") { pickPlayerTrack() }
                        .accessibilityIdentifier("analysis-track-new-player")
                    Button("Manage player tracks", systemImage: "person.2") { playback.pause(); showPlayerTracks = true }
                        .accessibilityIdentifier("analysis-manage-player-tracks")
                }
                if let players = clip.trackingLibrary?.players, !players.isEmpty {
                    Section("Saved player tracks") {
                        ForEach(players) { player in
                            Button(player.name, systemImage: "person.crop.circle") { selectSavedPlayer(player) }
                                .accessibilityIdentifier("analysis-saved-player-\(player.id)")
                        }
                    }
                }
                Button("Measurements & ground", systemImage: "ruler", action: openMeasurements)
                if clip.groundCalibration != nil {
                    Button("New ground reference here", systemImage: "ruler.fill") {
                        playback.pause()
                        groundRequest = .init(sourceTime: clip.freezeDuration == nil ? time : clip.startSeconds,
                                              annotationTime: time, existing: nil, isStill: clip.freezeDuration != nil)
                    }
                }
                if selected != nil, clip.freezeDuration == nil {
                    Button("Use camera track", systemImage: "video.badge.waveform") { beginCameraTracking() }
                }
            } label: {
                Label("Clip tracks", systemImage: "point.3.connected.trianglepath.dotted")
                    .labelStyle(.iconOnly).modifier(AnalysisControlSurface())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("analysis-clip-tracks")
        }.buttonStyle(AnalysisControlStyle()).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.inkPanel).disabled(trackingID != nil || !constructionPoints.isEmpty)
    }

    @ViewBuilder private var layerControls: some View {
        if let selected {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    if selected.tool == .trajectory {
                        Label("Follows player track", systemImage: "figure.run")
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                    AnalysisMotionControls(selection: correctingPlayer ? .player : selected.motionMode,
                                           allowsPlayer: clip.freezeDuration == nil, showsCamera: selected.motionMode == .camera,
                                           select: setMotionMode)
                        .disabled(selected.isLocked == true)
                    }
                    Menu {
                        Button("Layer style", systemImage: "slider.horizontal.3") { showProperties = true }
                        Button("Duplicate", systemImage: "plus.square.on.square", action: duplicate)
                        if clip.freezeDuration == nil {
                            Button(clip.trackingLibrary?.camera(at: time) == nil ? "Track camera (beta)" : "Use saved camera track", systemImage: "video.badge.waveform") { beginCameraTracking() }
                                .disabled(selected.isLocked == true)
                            Button("Start camera track here", systemImage: "video") { beginCameraTracking(force: true) }
                                .disabled(selected.isLocked == true)
                        }
                        Button(selected.isLocked == true ? "Unlock layer" : "Lock layer", systemImage: "lock") { toggleLayerLocked(selected.id) }
                        Button("Delete layer", systemImage: "trash", role: .destructive) {
                            checkpoint(); clip.annotations.removeAll { $0.id == selected.id }; selectedID = nil
                        }.disabled(selected.isLocked == true)
                    } label: {
                        Label("Layer actions", systemImage: "ellipsis")
                            .labelStyle(.iconOnly).modifier(AnalysisControlSurface())
                    }.buttonStyle(.plain).accessibilityIdentifier("analysis-layer-options")
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
                } else if selected.motionMode == .player || selected.motionMode == .camera || correctingPlayer {
                    HStack {
                        Text(correctingPlayer ? "Tap or draw around the player" : selected.motionMode == .camera ? "Camera lock · check alignment before saving" : "Blue = tracked · orange = needs correction")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if selected.linkedPlayers != nil, !correctingPlayer {
                            Menu {
                                ForEach(connectionAnchors) { anchor in
                                    Button(anchor.title + (anchor.isMissing ? " · Lost" : "")) {
                                        correctingAnchor = anchor.id; correctingPlayer = true; tool = .select; playback.pause(); detect(motion: false)
                                    }
                                    .accessibilityIdentifier("analysis-correct-anchor-\(anchor.id)")
                                }
                            } label: {
                                Label("Correct", systemImage: "scope").modifier(AnalysisControlSurface())
                            }.buttonStyle(.plain).disabled(selected.isLocked == true).accessibilityIdentifier("analysis-correct-connection")
                        } else {
                            Button(correctingPlayer ? "Cancel pick" : "Correct") {
                                if selected.motionMode == .camera { beginCameraTracking(force: true) }
                                else {
                                    correctingPlayer.toggle(); tool = .select; playback.pause()
                                    if correctingPlayer { detect(motion: false) } else { session.cancel() }
                                }
                            }.buttonStyle(AnalysisControlStyle()).disabled(selected.isLocked == true)
                                .accessibilityIdentifier("analysis-correct-tracking")
                        }
                    }
                }
            }.padding(.horizontal, 10).padding(.vertical, 6).background(Theme.inkPanel).disabled(trackingID != nil)
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
                        wallOpacity: { value in updateSelected(recordUndo: false) { $0.wallOpacity = value } }, beginEdit: checkpoint)
                }
            }
            if selected.playerMotion != nil || selected.linkedPlayers != nil {
                Section("Tracking") {
                    AnalysisTrackingSmoothingControls(mark: selected, amount: setTrackingSmoothing, beginEdit: checkpoint)
                }
            }
        } else {
            Section("Players") { detectionControls }
            freezeControls
        }
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
                                      start: min(time, clip.annotationEnd - 0.05), end: min(clip.annotationEnd, time + 6))
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
            canvasTouch = (location, location, frame); canvasDragging = false
        case .moveCorner(let location):
            guard let touch = canvasTouch else { return }
            canvasTouch?.current = location
            if hypot(location.x - touch.start.x, location.y - touch.start.y) >= 3 { canvasDragging = true }
            if canvasDragging { changeCanvasDrawing(startLocation: touch.start, location: location, frame: touch.frame) }
        case .endCorner:
            if let touch = canvasTouch {
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
                preview.points = preview.reshaped(at: time, handle: dragVertex, delta: CGSize(width: point.x - start.x, height: point.y - start.y))
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
            let seed = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard seed.width > 0.003, seed.height > 0.01 else { return }
            trackIndependentPlayer(seed: seed)
            return
        }
        if correctingPlayer, let id = selectedID {
            let seed = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard seed.width > 0.003, seed.height > 0.01 else { return }
            if selected?.linkedPlayers != nil { selectPlayer(seed); return }
            checkpoint(); correctingPlayer = false; selectedPlayer = .init(time: time, box: seed)
            beginTracking(id: id, seed: seed, from: time)
            return
        }
        if tool == .select, let original = dragOriginal {
            let dx = end.x - start.x, dy = end.y - start.y
            guard abs(dx) + abs(dy) > 0.002 else { return }
            updateSelected { mark in
                let moved = original.reshaped(at: time, handle: dragVertex, delta: CGSize(width: dx, height: dy))
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
        return mark.editHandles(at: time).enumerated().map { index, handle in
            (index, hypot(frame.minX + handle.x * frame.width - point.x, frame.minY + handle.y * frame.height - point.y))
        }.min { $0.1 < $1.1 }.flatMap { $0.1 <= 22 ? $0.0 : nil }
    }
    private func tapCanvas(_ location: CGPoint, frame: CGRect) {
        guard initialised, trackingID == nil, frame.contains(location) || editsOffscreenField else { return }
        playback.pause()
        let point = normalise(location, frame: frame)
        if pickingPlayerTrack {
            if let box = player(at: point) { trackIndependentPlayer(seed: box) }
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
            let points = mark.points(at: time)
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
    private func undoEdit() { guard let previous = undo.popLast() else { return }; redo.append(clip); clip = previous; selectedID = nil }
    private func redoEdit() { guard let next = redo.popLast() else { return }; undo.append(clip); clip = next; selectedID = nil }
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
            correctingPlayer = true
            if time < mark.start || time >= mark.end { seek(mark.start) }
            detect(motion: false)
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
        detections.filter { $0.rect.insetBy(dx: -0.014, dy: -0.014).contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.rect
    }
    private func selectPlayer(_ box: CGRect) {
        if pickingPlayerTrack { trackIndependentPlayer(seed: box); return }
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
            else { beginTracking(id: id, seed: box, from: time) }
        } else if let mark = hit(CGPoint(x: box.midX, y: box.midY)) {
            selectedID = mark.id
        } else { selectedID = nil }
    }
    private func chooseTool(_ item: AnalysisDrawingTool) {
        playback.pause()
        pickingPlayerTrack = false; correctingTrackID = nil
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
        } else { beginTracking(id: id, seed: seed, from: time) }
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

    private func renamePlayerTrack(_ id: UUID, name: String) {
        guard let index = clip.trackingLibrary?.players.firstIndex(where: { $0.id == id }),
              clip.trackingLibrary?.players[index].name != name else { return }
        checkpoint(); clip.trackingLibrary?.players[index].name = name
    }

    private func pickPlayerTrack(correcting id: UUID? = nil) {
        guard clip.freezeDuration == nil, trackingID == nil else { return }
        playback.pause(); selectedID = nil; selectedPlayer = nil; selectedPlayerTrackID = nil
        tool = .select; correctingPlayer = false; constructionPoints = []; constructionPlayers = []
        canvasNavigation = nil; showsPlayers = true
        correctingTrackID = id; pickingPlayerTrack = true
        detect(motion: false)
    }

    /// Saves source motion directly; creating or correcting a player never needs
    /// a temporary drawing and never replaces another player's identity.
    private func trackIndependentPlayer(seed: CGRect, effects: AnalysisPlayerEffects? = nil) {
        let start = time, end = clip.endSeconds
        guard trackingID == nil, clip.freezeDuration == nil, end - start > 0.05 else { return }
        let previous = clip.trackingLibrary?.players.first(where: { $0.id == correctingTrackID })?.motion
        let id = previous?.trackID ?? UUID(), job = UUID(), url = request.recording.fileURL
        pickingPlayerTrack = false; correctingTrackID = nil
        session.cancel(); playback.pause()
        selectedPlayer = .init(time: start, box: seed)
        trackingID = id; trackingJob = job; trackingProgress = 0
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await SelectedPlayerTracking.track(url: url, seed: seed, from: start, to: end, prior: previous) { fraction in
                        Task { @MainActor in if trackingJob == job { trackingProgress = fraction } }
                    }
                }
                let motion = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard trackingJob == job else { return }
                var combined = previous?.continuing(with: motion, from: start) ?? motion
                combined.trackID = id
                checkpoint(); clip.storePlayerTrack(combined); selectedPlayerTrackID = id
                if let effects {
                    selectedID = clip.applyPlayerEffects(effects, replacing: [], box: seed, motion: combined, at: start)
                    tool = .select
                }
                if let lost = motion.lostAt {
                    seek(motion.correctionTime ?? lost)
                    error = "Tracking stopped at \(timelineTimecode(lost - clip.startSeconds, includesTenths: true)). Paused at the last tracked frame. Use Correct to select this player and continue."
                }
            } catch is CancellationError {
                selectedPlayer = nil
            } catch { selectedPlayer = nil; self.error = error.localizedDescription }
        }
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
                              annotationTime: reference, existing: existing, isStill: clip.freezeDuration != nil)
    }

    private func applyGroundCalibration(_ value: GroundCalibration?) {
        checkpoint(); playback.pause(); clip.groundCalibration = value
        guard var calibration = value, calibration.valid, !calibration.fixedCamera, clip.freezeDuration == nil else { return }
        let start = calibration.referenceTime, end = clip.endSeconds
        if let camera = clip.trackingLibrary?.camera(at: calibration.referenceTime),
           (camera.samples.first?.time ?? .infinity) <= start,
           (camera.samples.last?.time ?? -.infinity) >= start,
           (camera.samples.last?.time ?? 0) >= end - 0.15, camera.lostAt == nil {
            calibration.cameraMotion = camera; clip.groundCalibration = calibration; return
        }
        let job = UUID(), url = request.recording.fileURL
        session.cancel(); trackingID = job; trackingJob = job; trackingProgress = 0
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await CameraMotionTracking.track(url: url, from: start, to: end) { fraction in
                        Task { @MainActor in if trackingJob == job { trackingProgress = fraction } }
                    }
                }
                var camera = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); guard trackingJob == job else { return }
                camera.trackID = UUID(); clip.storeCameraTrack(camera)
                clip.groundCalibration?.cameraMotion = camera
                if let lost = camera.lostAt {
                    seek(lost)
                    error = "Ground motion stopped here. Measurements are hidden outside camera coverage. At a clear frame, choose New ground reference here in Clip tracks to recalibrate."
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func beginTracking(id: UUID, seed: CGRect, from start: Double) {
        guard clip.freezeDuration == nil, seed.width > 0.002, seed.height > 0.005,
              let index = clip.annotations.firstIndex(where: { $0.id == id }), clip.annotations[index].end > start else { return }
        trackingTask?.cancel(); session.cancel(); playback.pause()
        let original = clip.annotations[index]
        let trackID = original.playerMotion?.trackID ?? UUID()
        // Switching an authored animation to follow starts from the pose the
        // user is looking at, not the drawing's original unanimated position.
        if original.playerMotion == nil { clip.annotations[index].points = original.points(at: start) }
        let placeholder = PlayerMotion(samples: [.init(time: start, box: seed)], lostAt: start + 0.1)
        clip.annotations[index].playerMotion = original.playerMotion?.continuing(with: placeholder, from: start) ?? placeholder
        let job = UUID()
        trackingID = id; trackingJob = job; trackingProgress = 0
        let url = request.recording.fileURL, end = clip.endSeconds
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await SelectedPlayerTracking.track(url: url, seed: seed, from: start, to: end, prior: original.playerMotion) { fraction in
                        Task { @MainActor in if trackingJob == job { trackingProgress = fraction } }
                    }
                }
                let motion = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard trackingJob == job, let index = clip.annotations.firstIndex(where: { $0.id == id }) else { return }
                var combined = original.playerMotion?.continuing(with: motion, from: start) ?? motion
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
        let initial = original.linkedPlayers ?? seeds.map { seed in
            clip.trackingLibrary?.player(matching: seed.box, at: seed.time)?.motion.bound(at: seed.time)
                ?? PlayerMotion(samples: [seed], trackID: UUID(), referenceBox: seed.box)
        }
        checkpoint(); trackingTask?.cancel(); session.cancel(); playback.pause()
        let job = UUID(); trackingID = id; trackingJob = job; trackingProgress = 0
        let url = request.recording.fileURL
        let end = clip.endSeconds
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    var motions = initial
                    for (offset, seed) in seeds.enumerated() {
                        try Task.checkCancellation()
                        let target = replacing ?? offset
                        guard motions.indices.contains(target), seed.time < end else { continue }
                        let old = motions[target]
                        if replacing == nil, (old.samples.last?.time ?? 0) >= end - 0.12 || old.lostAt != nil { continue }
                        let trackingSeed = replacing == nil && old.samples.count > 1 ? old.samples.last ?? seed : seed
                        let motion = try await SelectedPlayerTracking.track(url: url, seed: trackingSeed.box, from: trackingSeed.time, to: end, prior: old) { fraction in
                            Task { @MainActor in if trackingJob == job { trackingProgress = (Double(offset) + fraction) / Double(seeds.count) } }
                        }
                        motions[target] = old.continuing(with: motion, from: trackingSeed.time)
                        motions[target].trackID = old.trackID ?? UUID()
                        motions[target].referenceBox = old.reference
                    }
                    return motions
                }
                let motions = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard trackingJob == job, let index = clip.annotations.firstIndex(where: { $0.id == id }) else { return }
                clip.annotations[index].linkedPlayers = motions
                clip.annotations[index].playerMotion = nil; clip.annotations[index].cameraMotion = nil; clip.annotations[index].keyframes = []
                for motion in motions { clip.storePlayerTrack(motion) }
                if let failed = motions.enumerated().filter({ $0.element.lostAt != nil }).min(by: { ($0.element.lostAt ?? .infinity) < ($1.element.lostAt ?? .infinity) }),
                   let lost = failed.element.lostAt {
                    correctingAnchor = failed.offset
                    seek(failed.element.correctionTime ?? lost)
                    let name = clip.annotations[index].connectionAnchors(at: time, library: clip.trackingLibrary).first { $0.id == failed.offset }?.title ?? "Endpoint \(failed.offset + 1)"
                    error = "\(name) was lost at \(timelineTimecode(lost - clip.startSeconds, includesTenths: true)). Paused at its last confirmed frame. Use Correct and choose the matching numbered endpoint to reselect the same player."
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func beginCameraTracking(fromCurrentFrame: Bool = true, force: Bool = false) {
        guard var mark = selected, mark.isLocked != true, clip.freezeDuration == nil else { return }
        let bindTime = fromCurrentFrame ? min(mark.end - 0.05, max(mark.start, time)) : mark.start
        if mark.tool != .trajectory { mark.makeStatic(at: bindTime) }
        if !force, var saved = clip.trackingLibrary?.camera(at: bindTime) {
            checkpoint(); saved.referenceTime = bindTime
            if mark.tool == .trajectory { mark.trajectoryCameraMotion = saved }
            else { mark.cameraMotion = saved }
            if let index = clip.annotations.firstIndex(where: { $0.id == mark.id }) { clip.annotations[index] = mark }
            return
        }
        let existing = (mark.tool == .trajectory ? mark.trajectoryCameraMotion : selected?.cameraMotion)?.trackID.flatMap { id in clip.trackingLibrary?.cameras.first { $0.trackID == id } }
        let reference = force ? existing?.transform(at: bindTime) : nil
        let start = force ? bindTime : clip.startSeconds
        let trackID = reference != nil ? existing?.trackID ?? UUID() : UUID()
        let pending = mark
        checkpoint(); trackingTask?.cancel(); session.cancel(); playback.pause()
        let job = UUID(); trackingID = mark.id; trackingJob = job; trackingProgress = 0
        let url = request.recording.fileURL
        let end = clip.endSeconds
        trackingTask = Task { @MainActor in
            defer { if trackingJob == job { trackingID = nil; trackingTask = nil; trackingJob = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await CameraMotionTracking.track(url: url, from: start, to: end) { fraction in
                        Task { @MainActor in if trackingJob == job { trackingProgress = fraction } }
                    }
                }
                let motion = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard trackingJob == job, let index = clip.annotations.firstIndex(where: { $0.id == pending.id }) else { return }
                var shared = motion; shared.trackID = trackID
                if let reference, let existing {
                    shared.samples = existing.samples.filter { $0.time < start } + motion.samples.map {
                        .init(time: $0.time, transform: CameraTransform($0.transform.matrix * reference.matrix))
                    }
                }
                clip.storeCameraTrack(shared)
                if shared.transform(at: bindTime) != nil {
                    shared.referenceTime = bindTime
                    var tracked = pending
                    if tracked.tool == .trajectory { tracked.trajectoryCameraMotion = shared }
                    else { tracked.cameraMotion = shared }
                    clip.annotations[index] = tracked
                }
                if let lost = motion.lostAt { seek(motion.samples.last?.time ?? lost); error = "Camera track saved up to \(timelineTimecode(lost - clip.startSeconds, includesTenths: true)). Paused at the last tracked frame. Check field alignment, then use Correct to continue from a clear frame." }
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
                for point in selected.editHandles(at: content.time) {
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
