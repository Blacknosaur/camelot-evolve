import SwiftData
import SwiftUI

// MARK: - Tools

enum BoardTool: String, CaseIterable, Identifiable {
    case select, home, away, keeper, opponent, ball, cone, marker, miniGoal, mannequin
    case line, polyline, zoneRect, zoneEllipse, polygon, text
    case tallCone, domeCone, pole, hurdle, ladder, ring, wall, goal, popUpGoal, rebounder, flag, ballCart, coach, referee, stepMarker
    /// Places `TacticalBoardView.template` (a squad player picked in the library).
    case template

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .home: "Home"
        case .away: "Away"
        case .keeper: "Keeper"
        case .opponent: "Opp."
        case .ball: "Ball"
        case .cone: "Cone"
        case .marker: "Marker"
        case .miniGoal: "Goal"
        case .mannequin: "Dummy"
        case .line: "Line"
        case .polyline: "Polyline"
        case .zoneRect: "Zone"
        case .zoneEllipse: "Ellipse"
        case .polygon: "Shape"
        case .text: "Text"
        case .tallCone: "Tall cone"
        case .domeCone: "Dome"
        case .pole: "Pole"
        case .hurdle: "Hurdle"
        case .ladder: "Ladder"
        case .ring: "Ring"
        case .wall: "Wall"
        case .goal: "Full goal"
        case .popUpGoal: "Pop-up"
        case .rebounder: "Rebounder"
        case .flag: "Flag"
        case .ballCart: "Ball bag"
        case .coach: "Coach"
        case .referee: "Referee"
        case .stepMarker: "Step"
        case .template: "Squad"
        }
    }

    var symbol: String {
        switch self {
        case .select: "arrow.up.left"
        case .home, .away: "person.fill"
        case .keeper: "hand.raised.fill"
        case .opponent: "person"
        case .ball: "soccerball"
        case .cone: "cone.fill"
        case .marker: "smallcircle.filled.circle"
        case .miniGoal: "sportscourt"
        case .mannequin: "figure.stand"
        case .line: "arrow.up.right"
        case .polyline: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .zoneRect: "rectangle.dashed"
        case .zoneEllipse: "circle.dashed"
        case .polygon: "pentagon"
        case .text: "textformat"
        case .tallCone: "cone"
        case .domeCone: "circle.bottomhalf.filled"
        case .pole: "mappin"
        case .hurdle: "rectangle.split.3x1"
        case .ladder: "stairs"
        case .ring: "circle"
        case .wall: "person.3.fill"
        case .goal: "rectangle.portrait.on.rectangle.portrait"
        case .popUpGoal: "tent"
        case .rebounder: "square.grid.3x3"
        case .flag: "flag.fill"
        case .ballCart: "bag.fill"
        case .coach: "person.crop.circle.badge.checkmark"
        case .referee: "person.crop.circle.badge.exclamationmark"
        case .stepMarker: "1.circle.fill"
        case .template: "person.crop.square"
        }
    }

    /// Element kind placed by a single-point tool.
    var pointKind: BoardElementKind? {
        switch self {
        case .tallCone: .tallCone
        case .domeCone: .domeCone
        case .pole: .pole
        case .hurdle: .hurdle
        case .ladder: .ladder
        case .ring: .ring
        case .wall: .wall
        case .goal: .goal
        case .popUpGoal: .popUpGoal
        case .rebounder: .rebounder
        case .flag: .flag
        case .ballCart: .ballCart
        case .coach: .coach
        case .referee: .referee
        case .stepMarker: .stepMarker
        case .home, .away: .player
        case .keeper: .goalkeeper
        case .opponent: .opponent
        case .ball: .ball
        case .cone: .cone
        case .marker: .marker
        case .miniGoal: .miniGoal
        case .mannequin: .mannequin
        default: nil
        }
    }

    /// Always-visible palette groups, separated by dividers. Everything else lives in the library.
    static let groups: [[BoardTool]] = [
        [.select], [.home, .away, .keeper, .opponent], [.ball, .cone], [.line, .polyline, .zoneRect], [.text],
    ]
    static var fixed: Set<BoardTool> { Set(groups.flatMap { $0 }) }

    var placesByDragging: Bool { [.line, .zoneRect, .zoneEllipse].contains(self) }
    var placesByTapping: Bool { [.polyline, .polygon].contains(self) }
}

/// Pinch-zoom and pan of the board inside its canvas.
struct BoardViewport: Equatable {
    static let scaleRange: ClosedRange<CGFloat> = 1...5
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    func transform(in size: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }

    /// Scales `base` by `magnification` so the board point `content` sits under `screen` (the centre
    /// between two fingers). Moving both fingers therefore pans at the same time.
    static func zoomed(from base: BoardViewport, anchor content: CGPoint, to screen: CGPoint, magnification: CGFloat, in size: CGSize) -> BoardViewport {
        let scale = min(scaleRange.upperBound, max(scaleRange.lowerBound, base.scale * magnification))
        guard scale > 1.001 else { return BoardViewport() }
        var offset = CGSize(width: screen.x - size.width / 2 - scale * (content.x - size.width / 2),
                            height: screen.y - size.height / 2 - scale * (content.y - size.height / 2))
        // Keep part of the board on screen.
        let limitX = size.width * (scale - 1) / 2 + size.width * 0.25, limitY = size.height * (scale - 1) / 2 + size.height * 0.25
        offset.width = min(limitX, max(-limitX, offset.width))
        offset.height = min(limitY, max(-limitY, offset.height))
        return BoardViewport(scale: scale, offset: offset)
    }
}

// MARK: - Editor

struct TacticalBoardView: View {
    let board: TacticalBoard
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayScale) private var displayScale
    @State private var document: BoardDocument
    @State private var name: String
    @State private var history = BoardHistory()
    @State private var tool: BoardTool = .select
    @State private var selectedID: UUID?
    @State private var viewport = BoardViewport()
    @State private var interaction: Interaction = .idle
    @State private var dragOrigin: CGPoint = .zero
    @State private var dragStartDocument: BoardDocument?
    @State private var draft: BoardElement?
    @State private var pathPoints: [BoardPoint] = []
    @State private var pathAttachments: [UUID?] = []
    @State private var snapTargetID: UUID?
    @State private var lastSnapAngle: Double?
    @State private var lastTap: (date: Date, target: String)?
    @State private var longPressTask: Task<Void, Never>?
    @State private var contextTargetID: UUID?
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var promptNumber = ""
    @State private var renaming = false
    @State private var showingExport = false
    @State private var showingColors = false
    @State private var liveStart: BoardDocument?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    /// Squad player picked in the library, placed by the `.template` tool.
    @State private var template: BoardElement?
    @State private var showingLibrary = false
    @State private var inspectorCollapsed = false
    /// Element waiting for the user to tap the line or shape it should follow.
    @State private var pickingPathFor: UUID?
    @State private var cardTab: CardTab = .style
    /// Card shown at the top of the stage because the selection sits under its usual place.
    @State private var cardAtTop = false
    @FocusState private var cardFieldFocused: Bool
    /// Progress percentage shown while sliding an element along its path.
    @State private var pathDragBadge: Int?
    @State private var lastPathQuarter: Int?
    // Animation dock
    @State private var loopsPlayback = true
    /// Unsaved 3D view on a stage without a camera key while other stages have keys.
    @State private var liveCamera: BoardCamera?
    @State private var cameraEditStart: BoardDocument?
    @State private var cameraEditTask: Task<Void, Never>?
    @State private var cameraHintShown = false
    @State private var playbackSpeed = 1.0
    @State private var stageThumbnails: [UUID: UIImage] = [:]
    @State private var thumbnailTask: Task<Void, Never>?
    @State private var inspectorAutoCollapsed = false
    /// Recently used placeable items, newest first, shared by every board.
    @AppStorage("tacticalBoard.recentItems") private var recentToolsRaw = ""
    /// Style drawn by the Draw banner's line items (Pass, Run, Dribble).
    @State private var drawLineStyle = BoardLineStyle.pass
    @State private var showingLineup = false
    /// A recents slot being dragged onto the board (location in `editorSpace`).
    @State private var dragPlacement: (tool: BoardTool, location: CGPoint)?
    @State private var canvasFrame: CGRect = .zero
    /// Briefly highlights an element just placed with an armed tool (it is not left selected).
    @State private var flashID: UUID?
    // Animation
    @State private var showsFrames: Bool
    @State private var currentFrame = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    /// The playback clock lives in its own observable box: it ticks every 16 ms, and only the three small
    /// views that read it (the board canvas, the scrubber and the stage playhead) rebuild with it.
    @State private var clock = BoardPlaybackClock()
    @State private var playbackTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var thumbnailIsStale = false
    /// Bumped when a squad photo finishes decoding in the background, so the canvas redraws with it.
    @State private var photoGeneration = 0
    /// What is on disk (frame 0 applied), so saving never has to decode the stored board again.
    @State private var savedDocument: BoardDocument
    /// Set when the board's stored bytes could not be read: the editor shows a message and saves nothing.
    @State private var loadError: BoardLoadError?

    private enum Interaction: Equatable {
        case idle
        case pending(hit: UUID?, handle: BoardHandle?)
        case moving(id: UUID, start: BoardPose, origin: BoardPoint)
        case vertex(id: UUID, index: Int)
        case bending(id: UUID)
        case rotating(id: UUID, start: BoardElement, startAngle: CGFloat)
        case resizing(id: UUID, start: BoardElement, startDistance: CGFloat)
        case panning(start: CGSize, touch: CGPoint)
        case placing
        case pinchZoom(base: BoardViewport, anchor: CGPoint)
        case pinchTransform(id: UUID, start: BoardElement)
        case cancelled

        /// Gestures that change the document continuously; saving waits until they end.
        var isEditing: Bool {
            switch self {
            case .moving, .vertex, .bending, .rotating, .resizing, .placing, .pinchTransform: true
            default: false
            }
        }
    }

    private enum Prompt: Identifiable {
        case newText(BoardPoint)
        case editElement(UUID)
        var id: String {
            switch self { case .newText: "new"; case .editElement(let id): id.uuidString }
        }
    }

    /// Screen distance within which a line end connects to an element.
    private let snapDistance: CGFloat = 28

    init(board: TacticalBoard) {
        self.board = board
        var document = BoardDocument()
        var failure: BoardLoadError?
        do {
            document = try board.load()
            document.showFrame(0)
        } catch {
            failure = error as? BoardLoadError ?? .unreadable
        }
        _document = State(initialValue: document)
        _savedDocument = State(initialValue: document)
        _loadError = State(initialValue: failure)
        _name = State(initialValue: board.name)
        _showsFrames = State(initialValue: document.isAnimated)
    }

    var body: some View {
        if let loadError {
            unopenableBoard(loadError)
        } else {
            editor
        }
    }

    /// A board whose stored data cannot be read is never opened for editing, so nothing can overwrite it.
    private func unopenableBoard(_ error: BoardLoadError) -> some View {
        ContentUnavailableView {
            Label("Can't open this board", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("\(error.message) Its saved data is left untouched.")
        } actions: {
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("board-close")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("board-unopenable")
    }

    private var editor: some View {
        AdaptiveLayout { layout in
            // The stage has a fixed frame; inspector and frame bar float over it.
            Group {
                if layout.isLandscape && layout.isShort {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            topBar
                            stage
                        }
                        bottomSlot(vertical: true)
                    }
                } else {
                    VStack(spacing: 0) {
                        topBar
                        stage
                        // Tools and the animation transport share one fixed-size slot, so the stage never resizes.
                        bottomSlot(vertical: false)
                    }
                }
            }
            .coordinateSpace(name: Self.editorSpace)
            .overlay { dragPlacementPreview }
        }
        .background(Theme.ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: document) { scheduleSave(); refreshStageThumbnails() }
        .onChange(of: showsFrames) { refreshStageThumbnails() }
        .onChange(of: name) { scheduleSave() }
        // Photos are never decoded inside a draw; the canvas redraws once a warmed one is available.
        .onReceive(NotificationCenter.default.publisher(for: SquadPhotoStore.didWarmPhoto)) { _ in photoGeneration &+= 1 }
        .onDisappear { playbackTask?.cancel(); saveTask?.cancel(); save(writesThumbnail: true) }
        .task { refreshSquadLinks() }
        .sheet(isPresented: $showingExport) { TacticalBoardExportSheet(document: document, name: name) }
        .sheet(isPresented: $showingLibrary) {
            TacticalBoardLibrarySheet(document: document, recents: recentTools, onPick: { pick($0) }, onPickTemplate: { element in
                template = element
                pick(.template)
            }, onLineup: { elements, summary in placeLineup(elements, summary: summary) })
        }
        .sheet(isPresented: $showingLineup) {
            SquadLineupSheet(document: document) { elements, summary in placeLineup(elements, summary: summary) }
        }
        .alert("Rename board", isPresented: $renaming) {
            TextField("Board name", text: $promptText)
            Button("Save") { let trimmed = promptText.trimmingCharacters(in: .whitespaces); if !trimmed.isEmpty { name = trimmed } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { prompt in
            if promptEditsPerson {
                TextField("Number", text: $promptNumber).keyboardType(.numberPad)
            }
            TextField(promptEditsPerson ? "Label (optional)" : "Text", text: $promptText)
            Button("Save") { applyPrompt(prompt) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Element", isPresented: Binding(get: { contextTargetID != nil }, set: { if !$0 { contextTargetID = nil } }), titleVisibility: .hidden, presenting: contextTargetID.flatMap { id in document.elements.first { $0.id == id } }) { element in
            if element.kind.isPerson || element.kind == .text {
                Button(element.kind == .text ? "Edit text" : "Edit number & label", systemImage: "pencil") { beginEditing(element) }
            }
            if element.kind.isPerson {
                Button("Flip team", systemImage: "arrow.left.arrow.right") {
                    let home = document.homeColorHex, away = document.awayColorHex
                    commit { doc in doc.update(element.id) { $0.colorHex = $0.colorHex == home ? away : home } }
                }
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(element) }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(element.id) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Space.sm) {
            barButton("xmark", label: "Close", id: "board-close") { close() }
            Button {
                promptText = name; renaming = true
            } label: {
                HStack(spacing: 4) {
                    Text(name).font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.bold()).foregroundStyle(.secondary)
                }
                .frame(minHeight: Theme.tapTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("board-name")
            Spacer(minLength: 0)
            Menu {
                Picker("View", selection: Binding(get: { document.viewAngle }, set: { setViewAngle($0) })) {
                    ForEach(BoardViewAngle.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
                if document.viewAngle.is3D {
                    Section("Camera") {
                        Button { setCameraMode(.orbit) } label: {
                            Label("Orbit", systemImage: displayedCamera.resolvedMode == .orbit ? "checkmark" : "rotate.3d")
                        }
                        .accessibilityIdentifier("board-camera-orbit")
                        Button { setCameraMode(.free) } label: {
                            Label("Free look", systemImage: displayedCamera.resolvedMode == .free ? "checkmark" : "move.3d")
                        }
                        .accessibilityIdentifier("board-camera-free")
                        Button("Reset camera", systemImage: "camera.metering.center.weighted") { resetCamera() }
                    }
                }
                Picker("Style", selection: Binding(get: { document.fieldStyle }, set: { value in commit { $0.fieldStyle = value } })) {
                    ForEach(BoardFieldStyle.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Field", selection: Binding(get: { document.fieldType }, set: { value in commit { $0.fieldType = value } })) {
                    ForEach(BoardFieldType.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.menu)
            } label: {
                Image(systemName: document.viewAngle.is3D ? "view.3d" : "sportscourt")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.08), in: .circle)
                    .frame(width: Theme.tapTarget, height: Theme.tapTarget)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Field and view")
            .accessibilityValue(document.viewAngle.is3D ? "\(document.viewAngle.title), \(Self.cameraModeTitle(displayedCamera.resolvedMode))" : document.viewAngle.title)
            .accessibilityIdentifier("board-view")
            barButton("arrow.uturn.backward", label: "Undo", id: "board-undo", disabled: !history.canUndo) { undo() }
            barButton("arrow.uturn.forward", label: "Redo", id: "board-redo", disabled: !history.canRedo) { redo() }
            barButton("square.and.arrow.up", label: "Export", id: "board-export", prominent: true) { stopPlayback(); showingExport = true }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        // Six glyph buttons and a name on one row: past xxLarge they would overlap, so the bar stops there.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func barButton(_ symbol: String, label: String, id: String, disabled: Bool = false, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(prominent ? .black : .white)
                .frame(width: 40, height: 40)
                .background(prominent ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.white.opacity(0.08)), in: .circle)
                // The circle stays 40 pt; the target around it is a full 44.
                .frame(width: Theme.tapTarget, height: Theme.tapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func setViewAngle(_ angle: BoardViewAngle) {
        guard angle != document.viewAngle else { return }
        cancelPath()
        if angle.is3D { tool = .select; viewport = BoardViewport() }
        commit { $0.viewAngle = angle; $0.camera = nil }
    }

    // MARK: Stage

    private var stage: some View {
        GeometryReader { proxy in
            let trailing = Self.usesTrailingPanels(proxy.size)
            ZStack(alignment: trailing ? .bottomTrailing : .bottom) {
                stageContent
                    .frame(width: proxy.size.width, height: proxy.size.height)
                panels(trailing: trailing, stageSize: proxy.size)
            }
            .onChange(of: selectedID) { collapseInspectorIfCovering(stageSize: proxy.size) }
            // The selection can move under the card when the stage changes or after a drag: re-place the card.
            .onChange(of: currentFrame) { collapseInspectorIfCovering(stageSize: proxy.size) }
            .onChange(of: interaction == .idle) { _, idle in if idle { collapseInspectorIfCovering(stageSize: proxy.size) } }
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.6), in: .capsule)
                    .padding(.top, Theme.Space.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("board-toast")
            }
        }
        .clipped()
    }

    private var stageContent: some View {
        ZStack {
            if document.viewAngle.is3D {
                Board3DStage(clock: clock, document: renderedDocument, isLive: showsPlayback, baseCamera: displayedCamera,
                             selectedID: selectedID,
                             onionFrame: showsFrames && !isPlaying && document.showsOnionSkin == true ? currentFrame : nil,
                             onCamera: { cameraChanged($0) },
                             onSelect: { id in selectedID = id; if id != nil { selectionFeedback() } },
                             onMove: { id, position, ended in move3D(id, to: position, ended: ended) })
            } else {
                canvas
            }
        }
    }

    private var renderedDocument: BoardDocument {
        var copy = document
        if let draft { copy.elements.append(draft) }
        if !pathPoints.isEmpty {
            let closing = tool == .polygon && pathPoints.count >= 3
            var preview = BoardElement(kind: closing ? .polygon : .polyline, position: pathPoints[0], colorHex: tool == .polygon ? BoardPalette.keeper : BoardPalette.white)
            preview.points = pathPoints.count == 1 ? [pathPoints[0].offset(dx: 0.001, dy: 0)] : Array(pathPoints.dropFirst())
            preview.opacity = 0.25
            preview.lineStyle = tool == .polyline ? BoardLineStyle() : BoardLineStyle(pattern: .dashed, endCap: .none)
            preview.startAttachment = pathAttachments.first ?? nil
            copy.elements.append(preview)
        }
        return copy
    }

    private var showsPlayback: Bool { isPlaying || isScrubbing }

    /// Renderer for hit testing the editable document at the current zoom.
    private func hitRenderer(_ size: CGSize) -> BoardRenderer {
        BoardRenderer(document: document, inset: 10, chromeScale: 1 / viewport.scale, reserved: Self.reservedStrip(for: size), animationFrame: showsFrames ? currentFrame : nil)
    }

    /// Floating panels sit on the trailing edge of wide, short stages (phone landscape), else at the bottom.
    static func usesTrailingPanels(_ size: CGSize) -> Bool { size.width > size.height && size.height < 500 }

    /// Permanent strip kept clear for a collapsed panel so the pitch never has to move.
    static func reservedStrip(for size: CGSize) -> CGSize {
        usesTrailingPanels(size) ? CGSize(width: 56, height: 0) : CGSize(width: 0, height: 52)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // The field never changes during playback, so it sits behind the canvas as a plain image the
            // compositor keeps; the canvas then redraws only elements. Nil when zoomed far enough in that a
            // screen-sized bitmap would be soft, and the renderer draws the field itself again.
            let surface = BoardSurfaceCache.shared.canvas(field: document.fieldType, style: document.fieldStyle, size: size, inset: 10,
                                                          reserved: Self.reservedStrip(for: size), scale: displayScale * viewport.scale)
            let rendered = renderedDocument
            let makeRenderer: (Double?) -> BoardRenderer = { time in
                BoardRenderer(document: rendered, time: time, selectedID: time == nil ? selectedID : nil,
                              showsHandles: tool == .select, inset: 10, highlightedID: snapTargetID ?? flashID, chromeScale: 1 / viewport.scale,
                              reserved: Self.reservedStrip(for: size), drawsSurface: surface == nil,
                              animationFrame: showsFrames && time == nil ? currentFrame : nil,
                              onionFrame: showsFrames && !isPlaying && rendered.showsOnionSkin == true ? currentFrame : nil,
                              highlightedPathIDs: pickingPathFor == nil ? [] : pathCandidateIDs)
            }
            BoardPlaybackCanvas(clock: clock, isLive: showsPlayback, viewport: viewport, size: size, makeRenderer: makeRenderer)
            .background(alignment: .topLeading) {
                if let surface {
                    Image(decorative: surface, scale: displayScale)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(viewport.scale)
                        .offset(viewport.offset)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .clipped()
                }
            }
            .overlay {
                BoardTouchSurface(accessibilityValue: canvasAccessibilityValue, actions: canvasActions) { event in handle(event, size: size) }
            }
            .onAppear { canvasFrame = proxy.frame(in: .named(Self.editorSpace)) }
            .onChange(of: proxy.frame(in: .named(Self.editorSpace))) { _, frame in canvasFrame = frame }
            .overlay(alignment: .topLeading) {
                if !pathPoints.isEmpty {
                    HStack(spacing: Theme.Space.sm) {
                        Button("Cancel") { cancelPath() }.buttonStyle(DarkPillButtonStyle())
                        Button("Done") { finishPath() }.buttonStyle(DarkPillButtonStyle(isProminent: true))
                            .disabled(pathPoints.count < (tool == .polygon ? 3 : 2))
                            .accessibilityIdentifier("board-path-done")
                    }
                    .padding(Theme.Space.sm)
                } else if tool != .select, !isPlaying {
                    modeBanner
                } else if let hint = toolHint {
                    Text(hint).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(Theme.Space.sm)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("board-hint")
                }
            }
            .overlay { if showsStarter { starterCard } }
            .overlay(alignment: .topTrailing) {
                if viewport.scale > 1.01 {
                    Button { withAnimation(.snappy) { viewport = BoardViewport() } } label: {
                        Label("\(Int(viewport.scale * 100))%", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption.bold()).padding(.horizontal, 10).frame(minHeight: 32)
                            .background(.black.opacity(0.5), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(Theme.Space.sm)
                }
            }
        }
    }

    private var canvasAccessibilityValue: String {
        let count = document.elements.count
        let links = document.elements.reduce(0) { $0 + ($1.startAttachment == nil ? 0 : 1) + ($1.endAttachment == nil ? 0 : 1) }
        let selected = selectedElement.map { ", \(Self.title(of: $0)) selected" } ?? ""
        return (count == 1 ? "1 element" : "\(count) elements") + (links > 0 ? ", \(links) connected" : "") + selected
    }

    /// One nudge of a VoiceOver move action: a fiftieth of the field, fine enough to place a player.
    static let nudgeStep = 0.02

    /// The board is one direct-interaction element, so dragging is out of reach for VoiceOver.
    /// These custom actions are the way to select, move and delete without it.
    private var canvasActions: [BoardTouchSurface.Action] {
        var actions = [BoardTouchSurface.Action(name: "Next element") { stepSelection(by: 1) },
                       BoardTouchSurface.Action(name: "Previous element") { stepSelection(by: -1) }]
        guard let id = selectedID else { return actions }
        let step = Self.nudgeStep
        for (name, dx, dy) in [("up", 0.0, -step), ("down", 0.0, step), ("left", -step, 0.0), ("right", step, 0.0)] {
            actions.append(BoardTouchSurface.Action(name: "Move selected \(name)") { nudgeSelection(dx: dx, dy: dy) })
        }
        actions.append(BoardTouchSurface.Action(name: "Delete selected") { delete(id) })
        return actions
    }

    /// The element `step` places on in document order, wrapping; the first (or last) when nothing is selected.
    static func neighbourID(after id: UUID?, in elements: [BoardElement], step: Int) -> UUID? {
        guard !elements.isEmpty else { return nil }
        guard let id, let index = elements.firstIndex(where: { $0.id == id }) else {
            return step >= 0 ? elements[0].id : elements[elements.count - 1].id
        }
        return elements[((index + step) % elements.count + elements.count) % elements.count].id
    }

    private func stepSelection(by step: Int) {
        guard let id = Self.neighbourID(after: selectedID, in: document.elements, step: step),
              let element = document.elements.first(where: { $0.id == id }) else { return }
        selectedID = id
        selectionFeedback()
        UIAccessibility.post(notification: .announcement, argument: Self.title(of: element))
    }

    private func nudgeSelection(dx: Double, dy: Double) {
        guard let id = selectedID else { return }
        commit(recording: id) { document in
            document.update(id) { element in
                element.pose = element.pose.translated(dx: dx, dy: dy)
                if element.kind.isPoint { element.position = element.position.clamped() }
            }
        }
    }

    private var toolHint: String? {
        if isPlaying { return nil }
        switch tool {
        case .select:
            return pickingPathFor != nil ? "Tap the line or shape to move along" : nil
        case .polygon: return "Tap each corner, then Done"
        case .polyline: return "Tap points along the path, then Done"
        case .line: return "Drag to draw a \(armedLineTitle.lowercased())"
        case .zoneRect, .zoneEllipse: return "Drag to mark an area"
        case .text: return "Tap where the text goes"
        case .home, .away: return "Tap the pitch to add \(armedTitle) players"
        case .template: return "Tap the pitch to place \(armedTitle)"
        default: return "Tap the pitch to add a \(armedTitle.lowercased())"
        }
    }

    private var armedTitle: String {
        switch tool {
        case .opponent: "Opponent"
        case .template: template?.label.isEmpty == false ? template!.label : "the player"
        default: tool.title
        }
    }

    private var armedLineTitle: String {
        BoardPaletteItem.drawItems.first { $0.lineStyle == drawLineStyle }?.title ?? "line"
    }

    private var isDrawing: Bool { BoardPaletteItem.drawTools.contains(tool) }

    /// While placing or drawing, one banner at the top of the pitch says what the next touch
    /// does and how to stop. In Draw it also holds the line types.
    private var modeBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Theme.Space.sm) {
                if isDrawing {
                    Image(systemName: "pencil.tip").font(.headline).foregroundStyle(Theme.signal)
                } else {
                    BoardLibraryPreview(element: tool == .template ? (template ?? TacticalBoardLibrarySheet.sample(for: .home, document: document))
                                            : TacticalBoardLibrarySheet.sample(for: tool, document: document),
                                        field: document.fieldType, style: document.fieldStyle)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                Text(toolHint ?? "").font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("board-hint")
                Button("Done") { disarm() }
                    .buttonStyle(DarkPillButtonStyle(isProminent: true))
                    .accessibilityLabel("Finish placing")
                    .accessibilityIdentifier("board-disarm")
            }
            if isDrawing {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(BoardPaletteItem.drawItems) { item in drawChip(item) }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .glassPanel()
        .padding(Theme.Space.sm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-mode-banner")
    }

    private func drawChip(_ item: BoardPaletteItem) -> some View {
        let isOn = tool == item.tool && (item.lineStyle == nil || item.lineStyle == drawLineStyle)
        return Button {
            if let style = item.lineStyle { drawLineStyle = style }
            arm(item.tool)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let style = item.lineStyle { BoardLineGlyph(style: style) } else { Image(systemName: item.tool.symbol).font(.system(size: 18, weight: .semibold)) }
                }
                .frame(width: 40, height: 24)
                Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .frame(minWidth: 64, minHeight: 54)
            .padding(.horizontal, 4)
            .foregroundStyle(isOn ? .black : .white)
            .background(isOn ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.white.opacity(0.1)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(item.identifier)
    }

    /// An empty board offers the two ways coaches start: a team shape or single items.
    private var showsStarter: Bool {
        document.elements.isEmpty && !showsFrames && tool == .select && pathPoints.isEmpty
    }

    private var starterCard: some View {
        VStack(spacing: Theme.Space.md) {
            VStack(spacing: 4) {
                Text("Start your board").font(.headline)
                Text("Put a team shape on the pitch, or add players and equipment one by one.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: Theme.Space.sm) {
                Button { showingLineup = true } label: {
                    Label("Add a lineup", systemImage: "person.3.sequence.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(DarkPillButtonStyle(isProminent: true))
                .accessibilityIdentifier("board-start-lineup")
                Button { arm(.home) } label: {
                    Label("Add players", systemImage: "person.2.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(DarkPillButtonStyle())
                .accessibilityIdentifier("board-start-players")
            }
        }
        .foregroundStyle(.white)
        .padding(Theme.Space.lg)
        .frame(maxWidth: 300)
        .glassPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-starter")
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = message }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { toast = nil }
        }
    }

    // MARK: Touch handling

    private func boardPoint(_ screen: CGPoint, size: CGSize) -> CGPoint {
        screen.applying(viewport.transform(in: size).inverted())
    }

    private func fieldPoint(_ board: CGPoint, size: CGSize) -> BoardPoint {
        hitRenderer(size).projection(size: size).unproject(board)
    }

    private func handle(_ event: BoardTouchTracker.Event, size: CGSize) {
        switch event {
        case .began(let location): touchBegan(location, size: size)
        case .moved(let location): touchMoved(location, size: size)
        case .ended(let location): touchEnded(location, size: size)
        case .cancelled: cancelElementInteraction(); interaction = .idle
        case .pinchBegan(let centroid): pinchBegan(centroid, size: size)
        case .pinchChanged(let centroid, let scale, let rotation): pinchChanged(centroid, scale: scale, rotation: rotation, size: size)
        case .pinchEnded: pinchEnded()
        }
    }

    private func touchBegan(_ location: CGPoint, size: CGSize) {
        let point = boardPoint(location, size: size)
        dragOrigin = point
        if isPlaying { stopPlayback(); interaction = .cancelled; return }
        let renderer = hitRenderer(size)
        switch tool {
        case .select:
            var handle: BoardHandle?
            if let selected = selectedElement { handle = renderer.handle(at: point, of: selected, size: size) }
            let hit = handle != nil ? selectedID : renderer.hitTest(point, size: size)
            interaction = .pending(hit: hit, handle: handle)
            if let hit {
                if case .vertex(let index) = handle { scheduleLongPress(for: hit, vertex: index) } else if handle == nil { scheduleLongPress(for: hit, vertex: nil) }
            }
        case .polygon, .polyline, .text:
            interaction = .pending(hit: nil, handle: nil)
        default:
            // An armed item: touching an existing element selects or moves it instead and finishes placing.
            // Drawing from an element starts a connected line instead.
            if tool == .template || tool.pointKind != nil, let hit = renderer.hitTest(point, size: size) {
                disarm()
                interaction = .pending(hit: hit, handle: nil)
                scheduleLongPress(for: hit, vertex: nil)
                return
            }
            var element = newElement(for: tool, at: fieldPoint(point, size: size).clamped())
            if element.isLineLike, let target = snapTarget(near: point, size: size, excluding: nil) {
                element.position = target.position
                element.points = [target.position]
                element.startAttachment = target.id
            }
            draft = element
            interaction = .placing
        }
    }

    private func touchMoved(_ location: CGPoint, size: CGSize) {
        let point = boardPoint(location, size: size)
        let field = fieldPoint(point, size: size)
        let renderer = hitRenderer(size)
        let projection = renderer.projection(size: size)
        switch interaction {
        case .pending(let hit, let handle):
            guard hypot(point.x - dragOrigin.x, point.y - dragOrigin.y) > 6 / viewport.scale else { return }
            longPressTask?.cancel()
            if pickingPathFor != nil { interaction = .cancelled; return }
            guard let hit, let element = document.elements.first(where: { $0.id == hit }) else {
                interaction = viewport.scale > 1.01 && tool == .select ? .panning(start: viewport.offset, touch: location) : .cancelled
                return
            }
            dragStartDocument = document
            switch handle {
            case .vertex(let index):
                if element.isLineLike, index == 0 || index == element.lineVertices.count - 1 {
                    // Grabbing an end detaches it; releasing near an element connects again.
                    document.settleAttachments()
                    document.update(hit) { if index == 0 { $0.startAttachment = nil } else { $0.endAttachment = nil } }
                }
                interaction = .vertex(id: hit, index: index)
            case .bend:
                document.settleAttachments()
                interaction = .bending(id: hit)
            case .insert(let index):
                document.insertVertex(in: hit, after: index)
                interaction = .vertex(id: hit, index: index + 1)
            case .rotate:
                let center = renderer.transformCenter(element, projection: projection)
                interaction = .rotating(id: hit, start: element, startAngle: atan2(dragOrigin.y - center.y, dragOrigin.x - center.x))
            case .resize:
                let center = renderer.transformCenter(element, projection: projection)
                interaction = .resizing(id: hit, start: element, startDistance: max(8, hypot(dragOrigin.x - center.x, dragOrigin.y - center.y)))
            case nil:
                selectedID = hit
                interaction = .moving(id: hit, start: element.pose, origin: projection.unproject(dragOrigin))
            }
            touchMoved(location, size: size)
        case .moving(let id, let start, let origin):
            let target = start.translated(dx: field.x - origin.x, dy: field.y - origin.y)
            if showsFrames, let pose = document.pathPose(of: id, atFrame: currentFrame), let pathID = pose.pathID {
                slideAlongPath(id, pathID: pathID, pose: pose, to: target.position, projection: projection)
            } else {
                document.update(id) { $0.pose = target }
            }
        case .vertex(let id, let index):
            guard let element = document.elements.first(where: { $0.id == id }) else { return }
            if element.isLineLike {
                let isEnd = index == 0 || index == element.lineVertices.count - 1
                snapTargetID = isEnd ? snapTarget(near: point, size: size, excluding: nil)?.id : nil
                moveLineVertex(id, index: index, to: field.clamped())
            } else if element.kind == .zone {
                moveZoneCorner(id, index: index, to: field.clamped())
            } else {
                document.update(id) { if index == 0 { $0.position = field.clamped() } else if $0.points.indices.contains(index - 1) { $0.points[index - 1] = field.clamped() } }
            }
        case .bending(let id):
            guard let element = document.elements.first(where: { $0.id == id }) else { return }
            let start = element.position, end = element.arrowEnd
            let control = BoardPoint(2 * field.x - (start.x + end.x) / 2, 2 * field.y - (start.y + end.y) / 2)
            document.update(id) { $0.isCurved = true; $0.points = [$0.arrowEnd, control] }
        case .rotating(let id, let start, let startAngle):
            let center = renderer.transformCenter(start, projection: projection)
            let angle = atan2(point.y - center.y, point.x - center.x)
            var delta = angle - startAngle
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            applyTransform(id, start: start, rotation: Double(delta * 180 / .pi), scale: 1)
        case .resizing(let id, let start, let startDistance):
            let center = renderer.transformCenter(start, projection: projection)
            applyTransform(id, start: start, rotation: 0, scale: Double(hypot(point.x - center.x, point.y - center.y) / startDistance))
        case .panning(let start, let touch):
            viewport.offset = CGSize(width: start.width + location.x - touch.x, height: start.height + location.y - touch.y)
        case .placing:
            updateDraft(to: field.clamped(), board: point, size: size)
        case .idle, .cancelled, .pinchZoom, .pinchTransform:
            break
        }
    }

    private func touchEnded(_ location: CGPoint, size: CGSize) {
        longPressTask?.cancel()
        let point = boardPoint(location, size: size)
        defer { interaction = .idle; draft = nil; dragStartDocument = nil; snapTargetID = nil; lastSnapAngle = nil }
        switch interaction {
        case .pending(let hit, let handle):
            tapped(hit: hit, handle: handle, at: point, size: size)
        case .moving(let id, _, _):
            pathDragBadge = nil
            lastPathQuarter = nil
            document.update(id) { element in
                if element.kind.isPoint { element.position = element.position.clamped() }
            }
            finishEdit(recording: id)
        case .vertex(let id, let index):
            if let element = document.elements.first(where: { $0.id == id }), element.isLineLike, index == 0 || index == element.lineVertices.count - 1,
               let target = snapTarget(near: point, size: size, excluding: nil) {
                moveLineVertex(id, index: index, to: target.position)
                document.update(id) { if index == 0 { $0.startAttachment = target.id } else { $0.endAttachment = target.id } }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            finishEdit(recording: id)
        case .bending(let id):
            if let control = document.elements.first(where: { $0.id == id })?.curveControl, var next = dragStartDocument {
                // Re-apply from the pre-drag document so every keyframe gets the same bend.
                next.settleAttachments()
                next.setCurveControl(of: id, to: control)
                document = next
            }
            finishEdit(recording: id)
        case .rotating(let id, _, _), .resizing(let id, _, _):
            document.update(id) { $0.rotation = Self.normalized($0.rotation) }
            finishEdit(recording: id)
        case .placing:
            if var element = draft {
                if element.isLineLike, let target = snapTarget(near: point, size: size, excluding: element.startAttachment) {
                    element.setEndpoint(start: false, to: target.position)
                    element.endAttachment = target.id
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                place(element)
            }
        case .panning, .idle, .cancelled, .pinchZoom, .pinchTransform:
            break
        }
    }

    private func tapped(hit: UUID?, handle: BoardHandle?, at point: CGPoint, size: CGSize) {
        let field = fieldPoint(point, size: size).clamped()
        if let mover = pickingPathFor {
            pickingPathFor = nil
            if let hit, pathCandidateIDs.contains(hit) { followPath(mover, along: hit) }
            return
        }
        switch tool {
        case .polygon, .polyline:
            var attachment: UUID?
            if tool == .polyline, let target = snapTarget(near: point, size: size, excluding: nil) {
                attachment = target.id
                pathPoints.append(target.position)
            } else {
                pathPoints.append(field)
            }
            pathAttachments.append(attachment)
            selectionFeedback()
        case .text:
            promptText = ""
            prompt = .newText(field)
        default:
            let key = "\(hit?.uuidString ?? "none")-\(String(describing: handle))"
            let isDoubleTap = lastTap.map { Date().timeIntervalSince($0.date) < 0.4 && $0.target == key } ?? false
            lastTap = (Date(), key)
            if let hit, case .insert(let index) = handle {
                commit(recording: hit) { $0.insertVertex(in: hit, after: index) }
                selectionFeedback()
            } else if let hit, handle == .bend {
                if isDoubleTap, document.elements.first(where: { $0.id == hit })?.curveControl != nil {
                    commit(recording: hit) { $0.setCurveControl(of: hit, to: nil) }
                    selectionFeedback()
                }
            } else if let hit {
                selectedID = hit
                selectionFeedback()
                if isDoubleTap, handle == nil, let element = document.elements.first(where: { $0.id == hit }), element.kind.isPerson || element.kind == .text { beginEditing(element) }
            } else {
                selectedID = nil
                if isDoubleTap { withAnimation(.snappy) { viewport = BoardViewport() } }
            }
        }
    }

    private func pinchBegan(_ centroid: CGPoint, size: CGSize) {
        let anchor = boardPoint(centroid, size: size)
        let renderer = hitRenderer(size)
        // A pinch that starts on the selected element (first finger or centre) rotates and scales it.
        var target: UUID?
        if tool == .select, !isPlaying, let selected = selectedElement {
            switch interaction {
            case .pending(let hit, _) where hit == selected.id: target = hit
            case .moving(let id, _, _) where id == selected.id: target = id
            default:
                let projection = renderer.projection(size: size)
                let center = renderer.transformCenter(selected, projection: projection)
                let reach = (selected.kind.isPoint ? renderer.pointRadius(selected, projection: projection) : 0) + 40 / viewport.scale
                if renderer.hitTest(anchor, size: size) == selected.id || hypot(anchor.x - center.x, anchor.y - center.y) <= reach { target = selected.id }
            }
        }
        // Undo any move the first finger started: a pinch never moves the element under it.
        cancelElementInteraction()
        if let target, let element = document.elements.first(where: { $0.id == target }) {
            dragStartDocument = document
            interaction = .pinchTransform(id: target, start: element)
        } else {
            interaction = .pinchZoom(base: viewport, anchor: anchor)
        }
    }

    private func pinchChanged(_ centroid: CGPoint, scale: CGFloat, rotation: CGFloat, size: CGSize) {
        switch interaction {
        case .pinchZoom(let base, let anchor):
            viewport = BoardViewport.zoomed(from: base, anchor: anchor, to: centroid, magnification: scale, in: size)
        case .pinchTransform(let id, let start):
            applyTransform(id, start: start, rotation: Double(rotation * 180 / .pi), scale: Double(scale))
        default:
            break
        }
    }

    private func pinchEnded() {
        if case .pinchTransform(let id, _) = interaction {
            document.update(id) { $0.rotation = Self.normalized($0.rotation) }
            finishEdit(recording: id)
        }
        // The remaining finger does nothing until every finger lifts.
        interaction = .cancelled
        dragStartDocument = nil
        lastSnapAngle = nil
    }

    private func cancelElementInteraction() {
        longPressTask?.cancel()
        switch interaction {
        case .moving, .vertex, .bending, .rotating, .resizing, .pinchTransform:
            if let before = dragStartDocument { document = before }
        default:
            break
        }
        interaction = .cancelled
        draft = nil; dragStartDocument = nil; snapTargetID = nil
    }

    /// Rotates by `rotation` degrees (with gentle 15° snapping) and scales relative to `start`.
    private func applyTransform(_ id: UUID, start: BoardElement, rotation: Double, scale: Double) {
        var target = start.rotation + rotation
        let nearest = (target / 15).rounded() * 15
        if rotation != 0, abs(target - nearest) < 4 {
            target = nearest
            if lastSnapAngle != nearest { selectionFeedback() }
            lastSnapAngle = nearest
        } else {
            lastSnapAngle = nil
        }
        let factor = start.kind.isPoint ? scale : min(4, max(0.25, scale))
        let field = document.fieldType
        document.update(id) { $0 = start.transformed(rotation: target, scale: factor, field: field) }
    }

    static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value > 180 ? value - 360 : value <= -180 ? value + 360 : value
    }

    /// Records one history step for a finished gesture and stores the pose in the current frame.
    private func finishEdit(recording id: UUID) {
        guard let before = dragStartDocument, before != document else { return }
        history.record(before)
        if document.isAnimated { document.recordPoses(in: currentFrame, only: id) }
    }

    /// Nearest point element whose centre is within the snap distance of a board point.
    private func snapTarget(near point: CGPoint, size: CGSize, excluding excluded: UUID?) -> BoardElement? {
        let projection = hitRenderer(size).projection(size: size)
        let radius = snapDistance / viewport.scale
        let field = document.fieldType
        return document.elements(at: nil)
            .filter { $0.kind.isPoint && $0.id != excluded }
            .map { element -> (BoardElement, CGFloat) in
                let center = projection.point(element.position)
                return (element, hypot(center.x - point.x, center.y - point.y) - CGFloat(element.visualRadiusMeters(field: field)) * projection.pixelsPerMeter * 0.5)
            }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    private func moveLineVertex(_ id: UUID, index: Int, to point: BoardPoint) {
        document.update(id) { element in
            let last = element.lineVertices.count - 1
            if index == 0 { element.setEndpoint(start: true, to: point) }
            else if index == last { element.setEndpoint(start: false, to: point) }
            else if element.points.indices.contains(index - 1) { element.points[index - 1] = point }
        }
    }

    /// Moves one stored corner of a (possibly rotated) zone so the other corner stays put on screen.
    private func moveZoneCorner(_ id: UUID, index: Int, to finger: BoardPoint) {
        guard let element = document.elements.first(where: { $0.id == id }) else { return }
        let w = Double(document.fieldType.meters.width), h = Double(document.fieldType.meters.height)
        let angle = element.rotation * .pi / 180
        func rotate(_ p: BoardPoint, around c: BoardPoint, by a: Double) -> BoardPoint {
            let dx = (p.x - c.x) * w, dy = (p.y - c.y) * h
            return BoardPoint(c.x + (dx * cos(a) - dy * sin(a)) / w, c.y + (dx * sin(a) + dy * cos(a)) / h)
        }
        let center = element.position.lerp(to: element.opposite, 0.5)
        let fixedStored = index == 0 ? element.opposite : element.position
        let fixedWorld = rotate(fixedStored, around: center, by: angle)
        let newCenter = fixedWorld.lerp(to: finger, 0.5)
        let fixedLocal = rotate(fixedWorld, around: newCenter, by: -angle)
        let movedLocal = rotate(finger, around: newCenter, by: -angle)
        document.update(id) { zone in
            if index == 0 { zone.position = movedLocal; zone.points = [fixedLocal] } else { zone.position = fixedLocal; zone.points = [movedLocal] }
        }
    }

    private func scheduleLongPress(for id: UUID, vertex: Int?) {
        longPressTask?.cancel()
        longPressTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, case .pending(let hit, _) = interaction, hit == id else { return }
            if let vertex {
                guard let element = document.elements.first(where: { $0.id == id }) else { return }
                let canRemove = element.kind == .polygon ? element.allPoints.count > 3 : (element.isLineLike && element.lineVertices.count > 2)
                guard canRemove else { return }
                interaction = .cancelled
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if element.kind == .polygon {
                    commit(recording: id) { doc in doc.update(id) { poly in var all = poly.allPoints; all.remove(at: vertex); poly.position = all[0]; poly.points = Array(all.dropFirst()) } }
                } else {
                    commit(recording: id) { $0.removeVertex(in: id, at: vertex) }
                }
            } else {
                interaction = .cancelled
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                selectedID = id
                contextTargetID = id
            }
        }
    }

    // MARK: 3D

    private func move3D(_ id: UUID, to position: BoardPoint, ended: Bool) {
        guard let element = document.elements.first(where: { $0.id == id }) else { return }
        if dragStartDocument == nil { dragStartDocument = document }
        let target = position.clamped()
        document.update(id) { $0.pose = element.pose.translated(dx: target.x - element.position.x, dy: target.y - element.position.y) }
        selectedID = id
        guard ended else { return }
        finishEdit(recording: id)
        dragStartDocument = nil
    }

    // MARK: Placement

    private func newElement(for tool: BoardTool, at point: BoardPoint) -> BoardElement {
        switch tool {
        case .home: return BoardElement(kind: .player, position: point, colorHex: document.homeColorHex, number: document.nextNumber(for: .player, colorHex: document.homeColorHex))
        case .away: return BoardElement(kind: .player, position: point, colorHex: document.awayColorHex, number: document.nextNumber(for: .player, colorHex: document.awayColorHex))
        case .keeper: return BoardElement(kind: .goalkeeper, position: point, colorHex: BoardPalette.keeper, number: document.nextNumber(for: .goalkeeper, colorHex: BoardPalette.keeper))
        case .opponent: return BoardElement(kind: .opponent, position: point, colorHex: document.awayColorHex)
        case .ball: return BoardElement(kind: .ball, position: point)
        case .cone: return BoardElement(kind: .cone, position: point, colorHex: BoardPalette.orange)
        case .marker: return BoardElement(kind: .marker, position: point, colorHex: BoardPalette.keeper)
        case .miniGoal: return BoardElement(kind: .miniGoal, position: point)
        case .mannequin: return BoardElement(kind: .mannequin, position: point, colorHex: "9A9AA0")
        case .line:
            var element = BoardElement(kind: .line, position: point, points: [point])
            element.lineStyle = drawLineStyle
            return element
        case .zoneRect, .zoneEllipse:
            var element = BoardElement(kind: .zone, position: point, points: [point], colorHex: BoardPalette.keeper)
            element.zoneShape = tool == .zoneEllipse ? .ellipse : .rectangle
            return element
        case .template:
            var element = template ?? BoardElement(kind: .player, position: point, colorHex: document.homeColorHex)
            element.id = UUID()
            element.position = point
            return element
        case .stepMarker:
            let next = (document.elements.filter { $0.kind == .stepMarker }.compactMap(\.number).max() ?? 0) + 1
            return BoardElement(kind: .stepMarker, position: point, colorHex: BoardRenderer.defaultColor(for: .stepMarker, document: document), number: next)
        case .wall:
            var element = BoardElement(kind: .wall, position: point, colorHex: BoardRenderer.defaultColor(for: .wall, document: document))
            element.count = 4
            return element
        case .tallCone, .domeCone, .pole, .hurdle, .ladder, .ring, .goal, .popUpGoal, .rebounder, .flag, .ballCart, .coach, .referee:
            let kind = tool.pointKind ?? .cone
            return BoardElement(kind: kind, position: point, colorHex: BoardRenderer.defaultColor(for: kind, document: document))
        case .polyline, .polygon, .text, .select: return BoardElement(kind: .text, position: point, label: "Text")
        }
    }

    private func updateDraft(to point: BoardPoint, board: CGPoint, size: CGSize) {
        guard var element = draft else { return }
        switch element.kind {
        case .line:
            element.setEndpoint(start: false, to: point)
            snapTargetID = snapTarget(near: board, size: size, excluding: element.startAttachment)?.id
        case .zone:
            element.points = [point]
        default:
            element.position = point
        }
        draft = element
    }

    private func place(_ candidate: BoardElement) {
        var element = candidate
        switch element.kind {
        case .line:
            let end = element.arrowEnd
            if hypot(end.x - element.position.x, end.y - element.position.y) < 0.02 {
                element.points = [element.position.offset(dx: 0.14, dy: 0).clamped()]
                element.endAttachment = nil
            }
        case .zone:
            let corner = element.opposite
            if abs(corner.x - element.position.x) < 0.02 || abs(corner.y - element.position.y) < 0.02 {
                element.points = [element.position.offset(dx: 0.18, dy: 0.16).clamped()]
            }
        default:
            break
        }
        commit(recording: element.id) { $0.elements.append(element) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if keepsArmedAfterPlacing(tool) {
            // Stay armed to drop several quickly; flash the new element instead of selecting it.
            selectedID = nil
            flash(element.id)
        } else {
            // A drawn shape is usually styled next: finish drawing and select it.
            tool = .select
            selectedID = element.id
        }
    }

    /// Items and drawings both stay armed so several can be added in a row; the banner's Done ends it.
    private func keepsArmedAfterPlacing(_ tool: BoardTool) -> Bool {
        tool == .template || tool.pointKind != nil || BoardPaletteItem.drawTools.contains(tool)
    }

    private func flash(_ id: UUID) {
        flashID = id
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if flashID == id { flashID = nil }
        }
    }

    private func cancelPath() {
        pathPoints = []
        pathAttachments = []
    }

    private func finishPath() {
        guard pathPoints.count >= (tool == .polygon ? 3 : 2) else { return }
        var element: BoardElement
        if tool == .polygon {
            element = BoardElement(kind: .polygon, position: pathPoints[0], colorHex: BoardPalette.keeper)
        } else {
            element = BoardElement(kind: .polyline, position: pathPoints[0])
            element.lineStyle = BoardLineStyle()
            element.startAttachment = pathAttachments.first ?? nil
            element.endAttachment = pathAttachments.last ?? nil
        }
        element.points = Array(pathPoints.dropFirst())
        cancelPath()
        commit(recording: element.id) { $0.elements.append(element) }
        flash(element.id)
    }

    // MARK: Editing

    private var selectedElement: BoardElement? {
        selectedID.flatMap { id in document.elements.first { $0.id == id } }
    }

    /// Applies a change, records history and stores the changed element's pose in the current frame.
    private func commit(recording id: UUID? = nil, _ change: (inout BoardDocument) -> Void) {
        var next = document
        change(&next)
        if let id, next.isAnimated { next.recordPoses(in: currentFrame, only: id) }
        guard next != document else { return }
        history.record(document)
        document = next
    }

    private func undo() {
        guard let previous = history.undo(current: document) else { return }
        document = previous
        resyncFrame()
    }

    private func redo() {
        guard let next = history.redo(current: document) else { return }
        document = next
        resyncFrame()
    }

    private func resyncFrame() {
        if document.isAnimated {
            currentFrame = min(currentFrame, document.keyframes.count - 1)
            applyFrame(currentFrame)
        } else {
            showsFrames = false
        }
        if let selectedID, !document.elements.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    private func delete(_ id: UUID) {
        commit { $0.removeElement(id) }
        if selectedID == id { selectedID = nil }
    }

    // MARK: Squad

    /// Places squad players in a formation as one undoable change and closes the library.
    private func placeLineup(_ added: [BoardElement], summary: String) {
        guard !added.isEmpty else { return }
        let frame = currentFrame
        commit { $0.insertElements(added, recordingFrame: frame) }
        showingLibrary = false
        selectedID = nil
        tool = .select
        showToast(summary)
    }

    /// Copies edited squad data (number, name, position) into linked elements; not an undo step.
    /// The refresh rides along with the user's next real edit instead of being saved on its own, so
    /// simply opening a board does not bump `updatedAt` and shuffle it to the top of the list.
    private func refreshSquadLinks() {
        let players = modelContext.squadSnapshots()
        guard !players.isEmpty else { return }
        var next = document
        guard next.refreshSquadLinks(players) else { return }
        document = next
        if next.isAnimated { next.showFrame(0) }
        savedDocument = next
    }

    private func duplicate(_ element: BoardElement) {
        var copy = document.elements(at: nil).first { $0.id == element.id } ?? element
        copy.id = UUID()
        copy.startAttachment = nil
        copy.endAttachment = nil
        copy.pose = copy.pose.translated(dx: 0.04, dy: 0.04)
        copy.position = copy.position.clamped(); copy.points = copy.points.map { $0.clamped() }
        if copy.kind.isPerson, copy.number != nil { copy.number = document.nextNumber(for: copy.kind, colorHex: copy.colorHex) }
        let added = copy
        commit(recording: added.id) { $0.elements.append(added) }
        selectedID = added.id
    }

    private func beginEditing(_ element: BoardElement) {
        promptText = element.label
        promptNumber = element.number.map(String.init) ?? ""
        prompt = .editElement(element.id)
    }

    private var promptTitle: String {
        switch prompt {
        case .newText: "Add text"
        case .editElement(let id): document.elements.first { $0.id == id }?.kind == .text ? "Edit text" : "Player"
        case nil: ""
        }
    }

    private var promptEditsPerson: Bool {
        if case .editElement(let id) = prompt { return document.elements.first { $0.id == id }?.kind.isPerson == true }
        return false
    }

    private func applyPrompt(_ prompt: Prompt) {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt {
        case .newText(let point):
            guard !text.isEmpty else { return }
            let element = BoardElement(kind: .text, position: point, label: text)
            commit(recording: element.id) { $0.elements.append(element) }
            flash(element.id)
        case .editElement(let id):
            let number = Int(promptNumber.trimmingCharacters(in: .whitespaces))
            commit { doc in
                doc.update(id) { element in
                    if element.kind == .text { if !text.isEmpty { element.label = text } } else { element.label = text; element.number = number }
                }
            }
        }
    }

    // MARK: Live edits (sliders)

    /// Applies a slider change: continuous while dragging (one history step at the end), else a single commit.
    private func liveEdit(_ id: UUID, _ change: @escaping (_ start: BoardElement, _ element: inout BoardElement) -> Void) {
        guard let start = (liveStart ?? document).elements.first(where: { $0.id == id }) else { return }
        if liveStart != nil {
            document.update(id) { change(start, &$0) }
        } else {
            commit(recording: id) { $0.update(id) { change(start, &$0) } }
        }
    }

    private func editingChanged(_ id: UUID) -> (Bool) -> Void {
        { editing in
            if editing {
                if liveStart == nil { liveStart = document }
                return
            }
            guard let before = liveStart else { return }
            liveStart = nil
            guard before != document else { return }
            history.record(before)
            if document.isAnimated { document.recordPoses(in: currentFrame, only: id) }
        }
    }

    // MARK: Follow paths

    /// Dragging an element that sits on a path slides it along the path (progress follows the finger);
    /// pulling it more than ~40 pt away detaches it in this stage.
    private func slideAlongPath(_ id: UUID, pathID: UUID, pose: BoardPose, to target: BoardPoint, projection: BoardProjection) {
        let layout = document.layout(atFrame: currentFrame)
        guard let projected = BoardDocument.projectOntoPath(pathID: pathID, point: target, in: layout, field: document.fieldType) else { return }
        let distancePoints = CGFloat(projected.distanceMeters) * projection.pixelsPerMeter * viewport.scale
        if distancePoints > 40 {
            document.detachFromPath(id, inFrame: currentFrame)
            document.update(id) { $0.position = target }
            pathDragBadge = nil
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showToast("Detached from path in this stage")
            return
        }
        var progress = projected.progress
        if BoardDocument.isClosedPath(pathID, in: layout), let old = pose.pathProgress {
            // Keep the lap count: pick the wrap of the projection nearest the old progress.
            let base = floor(old)
            progress = [base - 1, base, base + 1].map { $0 + projected.progress }.min { abs($0 - old) < abs($1 - old) } ?? progress
        }
        document.setPathProgress(progress, for: id, inFrame: currentFrame)
        document.showFrame(currentFrame)
        let percent = Int((progress * 100).rounded())
        pathDragBadge = percent
        let quarter = Int((progress * 4).rounded())
        if abs(progress * 4 - Double(quarter)) < 0.03, lastPathQuarter != quarter {
            lastPathQuarter = quarter
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// Lines and shapes the element being picked for can follow.
    private var pathCandidateIDs: Set<UUID> {
        Set(document.elements.filter { $0.id != pickingPathFor && ($0.isLineLike || $0.kind.isArea) }.map(\.id))
    }

    /// Puts the element on a path from the current stage onwards, progress spread evenly.
    private func followPath(_ id: UUID, along pathID: UUID) {
        var next = document
        let count = next.attachToPath(id, pathID: pathID, fromFrame: currentFrame)
        guard count > 0 else { return }
        next.showFrame(currentFrame)
        history.record(document)
        document = next
        selectedID = id
        cardTab = .motion
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast(count == 1 ? "Follows path in this stage" : "Follows path over \(count) stages")
    }

    /// Applies a path edit as one undo step and refreshes the stage layout.
    private func editPath(_ change: (inout BoardDocument) -> Void) {
        var next = document
        change(&next)
        next.showFrame(currentFrame)
        guard next != document else { return }
        history.record(document)
        document = next
    }

    private var selectedPathPose: BoardPose? {
        guard showsFrames, let selectedID else { return nil }
        return document.pathPose(of: selectedID, atFrame: currentFrame)
    }

    /// Accessibility summary for UI tests: the selected element's progress in every stage ("0%, 50%, 100%").
    private var followState: String {
        guard let selectedID, document.isAnimated else { return "no path" }
        let values = document.keyframes.indices.map { index -> String in
            guard let progress = document.pathPose(of: selectedID, atFrame: index)?.pathProgress else { return "–" }
            return "\(Int((progress * 100).rounded()))%"
        }
        return values.allSatisfy { $0 == "–" } ? "no path" : values.joined(separator: ", ")
    }

    // MARK: Floating panels

    /// The element card and the stage strip float over the stage as glass panels, so the board never moves.
    /// Bottom-anchored normally, trailing in short landscape.
    @ViewBuilder
    private func panels(trailing: Bool, stageSize: CGSize) -> some View {
        let width = trailing ? min(350, stageSize.width * 0.5) : min(stageSize.width - 16, 520)
        let atTop = cardAtTop && !trailing
        ZStack {
          if trailing && showsFrames {
            // Short landscape: not enough height to stack; the strip runs along the bottom beside the card.
            HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                stageStrip
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .offset(y: 10)))
                cardView(width: min(330, stageSize.width * 0.44))
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
          } else {
            VStack(alignment: trailing ? .trailing : .center, spacing: Theme.Space.sm) {
                if !atTop { cardView(width: width) }
                if showsFrames {
                    stageStrip
                        .frame(width: width)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            if atTop {
                // The selection is low on the board: show its card at the top instead of covering it.
                cardView(width: width)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
          }
        }
        .padding(Theme.Space.sm)
        .frame(maxHeight: stageSize.height, alignment: .bottom)
        // The card floats over the board: it may grow, but not until it hides what is being edited.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .overlay(alignment: .top) { pathDragBadgeView }
        .animation(.snappy(duration: 0.22), value: selectedID)
        .animation(.snappy(duration: 0.22), value: showsFrames)
        .animation(.snappy(duration: 0.22), value: inspectorCollapsed)
        .animation(.snappy(duration: 0.22), value: cardAtTop)
    }

    @ViewBuilder
    private func cardView(width: CGFloat) -> some View {
        // While picking a path the card steps aside so it never covers the line or shape to tap.
        if let element = selectedElement, !isPlaying, pickingPathFor == nil {
            if inspectorCollapsed {
                collapsedCard(element)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            } else {
                elementCard(element)
                    .frame(width: width)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
    }

    @ViewBuilder
    private var pathDragBadgeView: some View {
        if let pathDragBadge {
            Text("\(pathDragBadge)%")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 14).frame(minHeight: 34)
                .background(Theme.signal, in: .capsule)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .padding(.top, Theme.Space.md)
                .allowsHitTesting(false)
                .accessibilityIdentifier("board-path-badge")
        }
    }

    enum CardTab: String, CaseIterable, Identifiable {
        case style, label, motion, squad
        var id: String { rawValue }
        var title: String {
            switch self {
            case .style: "Look"
            case .label: "Label"
            case .motion: "Motion"
            case .squad: "Squad"
            }
        }
    }

    private func cardTabs(for element: BoardElement) -> [CardTab] {
        var tabs: [CardTab] = [.style]
        if showsFrames && element.kind.isPoint { tabs.append(.motion) }
        if element.kind == .player || element.kind == .goalkeeper { tabs.append(.squad) }
        return tabs
    }

    /// Element details: header with preview and actions, tabs, and the tab's controls.
    private func elementCard(_ element: BoardElement) -> some View {
        let tabs = cardTabs(for: element)
        let tab = tabs.contains(cardTab) ? cardTab : .style
        return VStack(spacing: 6) {
            // Collapse from the grabber only, so sliders and chips keep their drags.
            Capsule().fill(.white.opacity(0.3)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 14)
                .contentShape(.rect)
                .onTapGesture { inspectorAutoCollapsed = false; inspectorCollapsed = true }
                .gesture(DragGesture(minimumDistance: 8).onEnded { value in
                    if value.translation.height > 20 { inspectorAutoCollapsed = false; inspectorCollapsed = true }
                })
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Collapse details")
                .accessibilityIdentifier("board-inspector-collapse")
            cardHeader(element)
            if tabs.count > 1 {
                HStack(spacing: 2) {
                    ForEach(tabs) { item in
                        Button { withAnimation(.snappy(duration: 0.18)) { cardTab = item } } label: {
                            Text(item.title).font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(item == tab ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.clear), in: .capsule)
                                .foregroundStyle(item == tab ? .black : .white.opacity(0.85))
                                .frame(minHeight: 36)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(item == tab ? .isSelected : [])
                        .accessibilityIdentifier("board-card-tab-\(item.rawValue)")
                    }
                }
                .padding(2)
                .background(.white.opacity(0.08), in: .capsule)
            }
            Group {
                switch tab {
                case .style: styleTab(element)
                case .label: labelTab(element)
                case .motion: motionTab(element)
                case .squad: squadTab(element)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
        .foregroundStyle(.white)
        .glassPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-inspector")
    }

    private func cardHeader(_ element: BoardElement) -> some View {
        HStack(spacing: Theme.Space.sm) {
            BoardLibraryPreview(element: previewElement(element), field: document.fieldType, style: document.fieldStyle)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(of: element)).font(.headline).lineLimit(1)
                    .accessibilityIdentifier("board-card-title")
                Text(cardSubtitle(element)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if element.kind.isPerson || element.kind.isStaff {
                cardIconButton("eye", label: "View from here", id: "board-view-from") { viewFrom(element) }
            }
            cardIconButton("plus.square.on.square", label: "Duplicate", id: "board-card-duplicate") { duplicate(element) }
            cardIconButton("trash", label: "Delete", id: "board-card-delete", tint: .red) { delete(element.id) }
            cardIconButton("xmark", label: "Done", id: "board-card-close") { selectedID = nil }
        }
    }

    private func cardIconButton(_ symbol: String, label: String, id: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: .circle)
                .frame(width: Theme.tapTarget, height: Theme.tapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// The element centred for the header preview (lines and areas keep their shape).
    private func previewElement(_ element: BoardElement) -> BoardElement {
        guard element.kind.isPoint else { return element }
        var copy = element
        copy.position = .center
        return copy
    }

    private func cardSubtitle(_ element: BoardElement) -> String {
        if element.kind.isPerson, !element.label.isEmpty { return element.label }
        if let pose = selectedPathPose, let progress = pose.pathProgress { return "On path · \(Int((progress * 100).rounded()))%" }
        if element.isLineLike { return element.resolvedLineStyle.pattern.rawValue.capitalized + " · " + element.resolvedLineStyle.shape.rawValue }
        if element.kind == .wall { return "\(element.wallCount) mannequins" }
        let rotation = Int(Self.normalized(element.rotation).rounded())
        return String(format: "%.1f× · %d°", element.size, rotation)
    }

    // MARK: Card tabs

    private func hasLabel(_ element: BoardElement) -> Bool {
        element.kind.isPerson || [.text, .coach, .referee, .stepMarker, .wall].contains(element.kind)
    }

    private func styleTab(_ element: BoardElement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasLabel(element) { labelTab(element) }
            swatchRow(element)
            if element.isLineLike || element.kind.isArea {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Space.sm) {
                        if element.isLineLike {
                            lineControls(element)
                            lengthChip(element)
                            heightControls(element)
                        } else {
                            if element.kind == .zone {
                                segmented(id: "board-zone-shape", options: [(BoardZoneShape.rectangle, "rectangle", "Rectangle"), (.ellipse, "circle", "Ellipse")], selection: element.zoneShape) { shape in
                                    commit { $0.update(element.id) { $0.zoneShape = shape } }
                                }
                            }
                            borderMenu(element)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            sliderRow(element, stacked: true)
        }
    }

    private func swatchRow(_ element: BoardElement) -> some View {
        HStack(spacing: 0) {
            ForEach(BoardPalette.swatches.prefix(7), id: \.self) { hex in
                let isOn = element.colorHex == hex
                Button { commit { $0.update(element.id) { $0.colorHex = hex } } } label: {
                    Circle().fill(BoardPalette.color(hex)).frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.white.opacity(isOn ? 1 : 0.2), lineWidth: isOn ? 2.5 : 1))
                        .padding(isOn ? 2 : 0)
                        .overlay(Circle().stroke(isOn ? Theme.signal : .clear, lineWidth: 2))
                        .frame(maxWidth: .infinity, minHeight: Theme.tapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(hex)")
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("board-swatch-\(hex)")
            }
            ColorPicker("Custom colour", selection: Binding(get: { BoardPalette.color(element.colorHex) }, set: { color in
                let hex = BoardPalette.hex(of: color)
                commit { $0.update(element.id) { $0.colorHex = hex } }
            }), supportsOpacity: false)
            .labelsHidden()
            .frame(maxWidth: .infinity, minHeight: Theme.tapTarget)
            .accessibilityLabel("Custom colour")
            .accessibilityIdentifier("board-color-custom")
        }
    }

    @ViewBuilder
    private func labelTab(_ element: BoardElement) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                switch element.kind {
                case .player, .goalkeeper, .opponent:
                    stepper("Number", value: element.number ?? 0, id: "number") { value in commit { $0.update(element.id) { $0.number = value <= 0 ? nil : value } } }
                    cardTextField(element, placeholder: "Name label")
                case .text, .coach, .referee:
                    cardTextField(element, placeholder: element.kind == .text ? "Text" : "Label")
                case .stepMarker:
                    Text("Step").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    stepper("Step", value: element.number ?? 1, id: "step", range: 1...99) { value in commit { $0.update(element.id) { $0.number = value } } }
                case .wall:
                    Text("Mannequins").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    stepper("Mannequins", value: element.wallCount, id: "wall-count", range: BoardElement.wallCountRange) { value in commit { $0.update(element.id) { $0.count = value } } }
                default:
                    EmptyView()
                }
            }
        }
        .frame(minHeight: 44)
    }

    /// Inline label editing: one undo step per editing session.
    private func cardTextField(_ element: BoardElement, placeholder: String) -> some View {
        TextField(placeholder, text: Binding(get: { element.label }, set: { value in
            if liveStart == nil { liveStart = document }
            document.update(element.id) { $0.label = String(value.prefix(24)) }
        }))
        .focused($cardFieldFocused)
        .submitLabel(.done)
        .onSubmit { cardFieldFocused = false }
        .onChange(of: cardFieldFocused) { _, focused in if !focused { editingChanged(element.id)(false) } }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("board-card-label")
    }

    @ViewBuilder
    private func motionTab(_ element: BoardElement) -> some View {
        if let pose = selectedPathPose, let pathID = pose.pathID {
            let closed = BoardDocument.isClosedPath(pathID, in: document.elements)
            let progress = pose.pathProgress ?? 0
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.sm) {
                    BoardInspectorSlider(title: "Progress", symbol: "point.topleft.down.to.point.bottomright.curvepath", value: closed ? progress - floor(progress) : progress, range: 0...1,
                                         id: "board-path-progress", format: { "\(Int(($0 * 100).rounded()))%" }, onEditing: editingChanged(element.id)) { value in
                        let laps = closed ? floor(progress) : 0
                        if liveStart == nil { liveStart = document }
                        document.setPathProgress(laps + value, for: element.id, inFrame: currentFrame)
                        document.showFrame(currentFrame)
                    }
                    if closed {
                        stepper("Laps", value: Int(floor(progress)), id: "path-laps", range: 0...9) { value in
                            editPath { $0.setPathProgress(Double(value) + progress - floor(progress), for: element.id, inFrame: currentFrame) }
                        }
                    }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Space.sm) {
                        chip("Face direction", symbol: "location.north.line", isOn: pose.facesPath == true) {
                            editPath { $0.setFacesPath(pose.facesPath != true, for: element.id, pathID: pathID) }
                        }
                        .accessibilityIdentifier("board-follow-face")
                        chip("Spread evenly", symbol: "equal", isOn: false) { editPath { $0.spreadPathEvenly(element.id, pathID: pathID) } }
                            .accessibilityIdentifier("board-follow-spread")
                        chip("Detach here", symbol: "link.badge.minus", isOn: false) { editPath { $0.detachFromPath(element.id, inFrame: currentFrame) } }
                            .accessibilityIdentifier("board-follow-detach")
                    }
                }
                .scrollIndicators(.hidden)
            }
        } else {
            HStack(spacing: Theme.Space.sm) {
                chip(pickingPathFor == element.id ? "Tap a line or shape…" : "Follow path", symbol: "point.topleft.down.to.point.bottomright.curvepath", isOn: pickingPathFor == element.id) {
                    pickingPathFor = pickingPathFor == element.id ? nil : element.id
                }
                .accessibilityIdentifier("board-follow-path")
                Text("Moves along a line or shape across stages").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(minHeight: 44)
        }
    }

    @ViewBuilder
    private func squadTab(_ element: BoardElement) -> some View {
        HStack {
            SquadLinkControl(element: element) { player in commit { $0.link(element.id, to: player) } }
            SquadFillTeamButton(document: document, element: element) { elements, summary in placeLineup(elements, summary: summary) }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }

    private func collapsedCard(_ element: BoardElement) -> some View {
        HStack(spacing: 0) {
            Button { inspectorAutoCollapsed = false; inspectorCollapsed = false } label: {
                HStack(spacing: Theme.Space.sm) {
                    Circle().fill(BoardPalette.color(element.colorHex)).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                    Text(Self.title(of: element)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.leading, 14).padding(.trailing, 6)
                .frame(minHeight: Theme.tapTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("board-inspector-expand")
            Button { selectedID = nil } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
                    .frame(width: 26, height: 26).background(.white.opacity(0.14), in: .circle)
                    .frame(width: Theme.tapTarget, height: Theme.tapTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("board-card-close")
        }
        .foregroundStyle(.white)
        .glassPanel(cornerRadius: 22)
    }

    static func title(of element: BoardElement) -> String {
        switch element.kind {
        case .player: element.number.map { "Player \($0)" } ?? "Player"
        case .goalkeeper: "Goalkeeper"
        case .opponent: "Opponent"
        case .arrow, .line: Self.lineTypeTitle(element)
        case .polyline: "Path"
        case .zone: "Zone"
        case .polygon: "Shape"
        case .text: element.label.isEmpty ? "Text" : element.label
        case .stepMarker: "Step \(element.number ?? 1)"
        default: BoardTool.allCases.first { $0.pointKind == element.kind && $0 != .template }?.title ?? "Item"
        }
    }

    /// Collapses the card when a newly selected element sits where the expanded card would cover it,
    /// and re-expands after an automatic collapse once the selection is clear of it. The board never moves.
    private func collapseInspectorIfCovering(stageSize: CGSize) {
        guard let element = document.elements(at: nil).first(where: { $0.id == selectedID }) else { return }
        let renderer = hitRenderer(stageSize)
        let point = renderer.transformCenter(element, projection: renderer.projection(size: stageSize)).applying(viewport.transform(in: stageSize))
        let cardHeight: CGFloat = element.isLineLike || element.kind.isArea ? 240 : 200
        var covered: Bool
        if Self.usesTrailingPanels(stageSize) {
            covered = point.x > stageSize.width - min(350, stageSize.width * 0.5) - 24
            cardAtTop = false
        } else {
            let coversBottom = point.y > stageSize.height - cardHeight - (showsFrames ? 118 : 0)
            let coversTop = point.y < cardHeight + 16
            // Prefer moving the card to the top over collapsing it.
            cardAtTop = coversBottom && !coversTop
            covered = coversBottom && coversTop
        }
        if covered, !inspectorCollapsed {
            inspectorCollapsed = true
            inspectorAutoCollapsed = true
        } else if !covered, inspectorAutoCollapsed {
            inspectorCollapsed = false
            inspectorAutoCollapsed = false
        }
    }

    /// Height of a lofted pass or shot: presets plus a custom slider and where it lands.
    @ViewBuilder
    private func heightControls(_ element: BoardElement) -> some View {
        let peak = element.arcHeightMeters ?? 0
        inspectorDivider
        ForEach([("Ground", 0.0), ("Low", 2.0), ("High", 8.0)], id: \.0) { title, height in
            chip(title, symbol: height == 0 ? "arrow.down.to.line" : (height < 4 ? "arrow.up.right" : "arrow.up.forward"), isOn: abs(peak - height) < 0.01) {
                commit { $0.update(element.id) { line in
                    line.arcHeightMeters = height == 0 ? nil : height
                    if height == 0 { line.startHeightMeters = nil; line.endHeightMeters = nil }
                } }
            }
            .accessibilityIdentifier("board-height-\(title.lowercased())")
        }
        if element.isAerial {
            BoardInspectorSlider(title: "Height", symbol: "arrow.up.and.down", value: peak, range: BoardElement.arcHeightRange, id: "board-height-slider",
                                 format: { String(format: "%.1f m", $0) }, onEditing: editingChanged(element.id)) { value in
                liveEdit(element.id) { _, line in line.arcHeightMeters = value < 0.05 ? nil : value }
            }
            .frame(width: 150)
            Menu {
                Picker("Ends at", selection: Binding(get: { element.endHeightMeters ?? 0 }, set: { value in
                    commit { $0.update(element.id) { $0.endHeightMeters = value < 0.05 ? nil : value } }
                })) {
                    ForEach([0.0, 1.0, 2.0, 2.44], id: \.self) { height in
                        Text(height < 0.05 ? "Ground" : String(format: "%.2g m", height)).tag(height)
                    }
                }
            } label: {
                Label(element.endHeightMeters.map { String(format: "Ends %.2g m", $0) } ?? "Ends ground", systemImage: "arrow.down.right")
                    .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 36)
                    .background(.white.opacity(0.1), in: .capsule)
                    .frame(minHeight: Theme.tapTarget)
                    .contentShape(.rect)
            }
            .accessibilityLabel("End height")
            .accessibilityValue(element.endHeightMeters.map { String(format: "%.2g m", $0) } ?? "Ground")
            .accessibilityIdentifier("board-height-end")
        }
    }

    @ViewBuilder
    private func lengthChip(_ element: BoardElement) -> some View {
        if element.kind == .line || element.kind == .polyline || element.kind == .arrow {
            chip("Length", symbol: "ruler", isOn: element.showsLength == true) {
                commit { $0.update(element.id) { $0.showsLength = $0.showsLength == true ? nil : true } }
            }
            .accessibilityIdentifier("board-line-length")
        }
    }

    @ViewBuilder
    private func lineControls(_ element: BoardElement) -> some View {
        let style = element.resolvedLineStyle
        let presets: [(String, String, BoardLineStyle)] = [("Pass", "arrow.right", .pass), ("Run", "figure.run", .run), ("Dribble", "scribble", .dribble)]
        ForEach(presets, id: \.0) { title, symbol, preset in
            let isOn = style.pattern == preset.pattern && style.shape == preset.shape && style.endCap == .arrow
            chip(title, symbol: symbol, isOn: isOn) {
                updateLineStyle(element) { $0.pattern = preset.pattern; $0.shape = preset.shape; $0.endCap = .arrow }
            }
            .accessibilityIdentifier("board-line-preset-\(title.lowercased())")
        }
        inspectorDivider
        HStack(spacing: 2) {
            ForEach(BoardLinePattern.allCases, id: \.self) { pattern in
                glyphButton(id: "board-line-pattern-\(pattern.rawValue)", label: "\(pattern.rawValue.capitalized) line", isOn: style.pattern == pattern,
                            glyph: BoardLineGlyph(style: BoardLineStyle(pattern: pattern, endCap: .none))) {
                    updateLineStyle(element) { $0.pattern = pattern }
                }
            }
        }
        .padding(2)
        .background(.white.opacity(0.08), in: .capsule)
        HStack(spacing: 2) {
            ForEach(BoardLineShape.allCases, id: \.self) { shape in
                glyphButton(id: "board-line-shape-\(shape.rawValue)", label: "\(shape.rawValue.capitalized) shape", isOn: style.shape == shape,
                            glyph: BoardLineGlyph(style: BoardLineStyle(shape: shape, endCap: .none))) {
                    updateLineStyle(element) { $0.shape = shape }
                }
            }
        }
        .padding(2)
        .background(.white.opacity(0.08), in: .capsule)
        capMenu(element, start: true)
        capMenu(element, start: false)
        Menu {
            Picker("Opacity", selection: Binding(get: { (style.strokeOpacity * 4).rounded() / 4 }, set: { value in updateLineStyle(element) { $0.opacity = value >= 1 ? nil : value } })) {
                ForEach([1.0, 0.75, 0.5, 0.25], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
            }
        } label: {
            Label("\(Int((style.strokeOpacity * 100).rounded()))%", systemImage: "circle.lefthalf.filled")
                .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 36)
                .background(.white.opacity(0.1), in: .capsule)
                .frame(minHeight: Theme.tapTarget)
                .contentShape(.rect)
        }
        .accessibilityLabel("Line opacity")
        .accessibilityIdentifier("board-line-opacity")
        if element.curveControl != nil {
            chip("Straighten", symbol: "line.diagonal", isOn: false) { commit(recording: element.id) { $0.setCurveControl(of: element.id, to: nil) } }
        }
    }

    private func capMenu(_ element: BoardElement, start: Bool) -> some View {
        let style = element.resolvedLineStyle
        let current = start ? style.startCap : style.endCap
        return Menu {
            Picker(start ? "Start" : "End", selection: Binding(get: { current }, set: { cap in updateLineStyle(element) { if start { $0.startCap = cap } else { $0.endCap = cap } } })) {
                ForEach(BoardLineCap.allCases, id: \.self) { cap in
                    Label(cap.title, systemImage: cap.symbol).tag(cap)
                }
            }
        } label: {
            BoardLineGlyph(style: BoardLineStyle(startCap: start ? current : .none, endCap: start ? .none : current))
                .frame(width: 30, height: 16)
                .padding(.horizontal, 8).frame(minHeight: 36)
                .background(.white.opacity(0.1), in: .capsule)
                .frame(minHeight: Theme.tapTarget)
                .contentShape(.rect)
        }
        .accessibilityLabel(start ? "Start cap" : "End cap")
        .accessibilityValue(current.title)
        .accessibilityIdentifier(start ? "board-line-start-cap" : "board-line-end-cap")
    }

    private func borderMenu(_ element: BoardElement) -> some View {
        let options: [String] = BoardLinePattern.allCases.map(\.rawValue) + ["none"]
        return Menu {
            Picker("Border", selection: Binding(get: { element.resolvedBorderPattern?.rawValue ?? "none" }, set: { raw in
                commit { $0.update(element.id) { zone in
                    zone.showsBorder = raw == "none" ? false : nil
                    zone.borderPattern = BoardLinePattern(rawValue: raw).flatMap { $0 == .solid ? nil : $0 }
                } }
            })) {
                ForEach(options, id: \.self) { raw in
                    Text(raw == "none" ? "No border" : raw.capitalized).tag(raw)
                }
            }
        } label: {
            Label(element.resolvedBorderPattern?.rawValue.capitalized ?? "No border", systemImage: "square.dashed")
                .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 36)
                .background(.white.opacity(0.1), in: .capsule)
                .frame(minHeight: Theme.tapTarget)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("board-border")
    }

    private func updateLineStyle(_ element: BoardElement, _ change: @escaping (inout BoardLineStyle) -> Void) {
        commit { $0.update(element.id) { line in
            var style = line.resolvedLineStyle
            change(&style)
            line.lineStyle = style
        } }
    }

    @ViewBuilder
    private func sliderRow(_ element: BoardElement, stacked: Bool = false) -> some View {
        let field = document.fieldType
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: Theme.Space.md))
        layout {
            if element.kind.isArea {
                BoardInspectorSlider(title: "Fill", symbol: "drop.halffull", value: element.opacity, range: 0...1, id: "board-fill-slider",
                                     format: { "\(Int(($0 * 100).rounded()))%" }, onEditing: editingChanged(element.id)) { value in
                    liveEdit(element.id) { _, zone in zone.opacity = value }
                }
            } else if element.isLineLike {
                BoardInspectorSlider(title: "Width", symbol: "lineweight", value: element.resolvedLineStyle.width, range: 0.5...3, id: "board-size-slider",
                                     format: { String(format: "%.1f×", $0) }, onEditing: editingChanged(element.id)) { value in
                    liveEdit(element.id) { _, line in var style = line.resolvedLineStyle; style.width = value; line.lineStyle = style }
                }
            } else {
                BoardInspectorSlider(title: "Size", symbol: "arrow.up.left.and.arrow.down.right", value: element.size, range: BoardElement.sizeRange, id: "board-size-slider",
                                     format: { String(format: "%.1f×", $0) }, onEditing: editingChanged(element.id)) { value in
                    liveEdit(element.id) { _, item in item.size = value }
                }
            }
            HStack(spacing: Theme.Space.sm) {
            BoardInspectorSlider(title: "Turn", symbol: "rotate.right", value: Self.normalized(element.rotation), range: -180...180, id: "board-rotation-slider",
                                 format: { "\(Int($0.rounded()))°" }, onEditing: editingChanged(element.id)) { value in
                let nearest = (value / 15).rounded() * 15
                let snapped = abs(value - nearest) < 3 ? nearest : value
                liveEdit(element.id) { start, item in item = start.transformed(rotation: snapped, scale: 1, field: field) }
            }
            .frame(maxWidth: .infinity)
            Button {
                commit(recording: element.id) { doc in doc.update(element.id) { $0 = $0.transformed(rotation: 0, scale: 1, field: field) } }
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.caption.weight(.bold))
                    .frame(width: 30, height: 30).background(.white.opacity(0.1), in: .circle)
                    .frame(width: Theme.tapTarget, height: Theme.tapTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(abs(Self.normalized(element.rotation)) < 0.5)
            .opacity(abs(Self.normalized(element.rotation)) < 0.5 ? 0.35 : 1)
            .accessibilityLabel("Reset rotation")
            .accessibilityIdentifier("board-rotation-reset")
            }
        }
    }

    private var inspectorDivider: some View {
        Rectangle().fill(Theme.inkStroke).frame(width: 1, height: 28)
    }

    private func chip(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(isOn ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.white.opacity(0.1)), in: .capsule)
                .foregroundStyle(isOn ? .black : .white)
                .frame(minHeight: Theme.tapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func glyphButton(id: String, label: String, isOn: Bool, glyph: BoardLineGlyph, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph
                .foregroundStyle(isOn ? .black : .white)
                .frame(width: 26, height: 16)
                .frame(width: 38, height: 34)
                .background(isOn ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.clear), in: .capsule)
                .frame(minWidth: Theme.tapTarget, minHeight: Theme.tapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private func segmented<Value: Equatable>(id: String, options: [(Value, String, String)], selection: Value, change: @escaping (Value) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let (value, symbol, title) = options[index]
                Button { change(value) } label: {
                    Image(systemName: symbol).font(.caption.weight(.bold))
                        .frame(width: 38, height: 34)
                        .background(value == selection ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.clear), in: .capsule)
                        .foregroundStyle(value == selection ? .black : .white)
                        .frame(minWidth: Theme.tapTarget, minHeight: Theme.tapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
            }
        }
        .padding(2)
        .background(.white.opacity(0.08), in: .capsule)
        .accessibilityIdentifier(id)
    }

    private func stepper(_ title: String, value: Int, id: String, range: ClosedRange<Int> = 0...99, change: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            Button { change(max(range.lowerBound, value - 1)) } label: { Image(systemName: "minus").frame(width: 34, height: Theme.tapTarget) }.accessibilityLabel("Decrease \(title)")
            Text("\(value)").font(.caption.weight(.semibold).monospacedDigit()).frame(minWidth: 26)
            Button { change(min(range.upperBound, value + 1)) } label: { Image(systemName: "plus").frame(width: 34, height: Theme.tapTarget) }.accessibilityLabel("Increase \(title)")
        }
        .font(.caption.weight(.bold))
        .frame(height: 36)
        .background(.white.opacity(0.1), in: .capsule)
        .buttonStyle(.plain)
        .accessibilityIdentifier("board-\(id)")
    }

    // MARK: Bottom bar

    static let editorSpace = "board-editor"
    private static let defaultRecents: [BoardTool] = [.home, .away, .ball, .cone]

    /// The last placeable items, newest first, shown at the top of the library.
    private var recentTools: [BoardTool] {
        var list = recentToolsRaw.split(separator: ",").compactMap { BoardTool(rawValue: String($0)) }.filter { $0.pointKind != nil }
        for fallback in Self.defaultRecents where list.count < 4 && !list.contains(fallback) { list.append(fallback) }
        return Array(list.prefix(4))
    }

    /// Items always in the bar: the ones every session uses. Everything else is in the library.
    private static let barItems: [BoardTool] = [.home, .away, .ball, .cone]

    /// One bar that never changes shape: the tools while editing, the transport while animating.
    @ViewBuilder
    private func bottomSlot(vertical: Bool) -> some View {
        if showsFrames { transportBar(vertical: vertical) } else { toolBar(vertical: vertical) }
    }

    /// Library, the four everyday items, Draw and Animate. Nothing scrolls, so an item can be
    /// dragged straight onto the pitch, and the armed item stays lit until Done.
    private func toolBar(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            barSlot(id: "board-library", title: "Library", isOn: false, prominent: true, vertical: vertical) {
                Image(systemName: "plus").font(.system(size: 21, weight: .bold))
            } action: {
                disarm()
                showingLibrary = true
            }
            ForEach(Self.barItems) { item in itemSlot(item, vertical: vertical) }
            barSlot(id: "board-draw", title: "Draw", isOn: isDrawing, vertical: vertical) {
                BoardLineGlyph(style: drawLineStyle).frame(width: 34, height: 24)
            } action: {
                if isDrawing { disarm() } else { arm(.line) }
            }
            barSlot(id: "board-animate", title: "Animate", isOn: false, vertical: vertical) {
                Image(systemName: "play.square.stack").font(.system(size: 20, weight: .semibold))
            } action: {
                toggleFrames()
            }
        }
        .padding(5)
        .glassPanel(cornerRadius: 22)
        .padding(.horizontal, vertical ? 6 : 8)
        .padding(.top, vertical ? 8 : 4)
        .padding(.bottom, vertical ? 8 : 2)
        .frame(width: vertical ? 76 : nil)
        // A fixed rail cannot grow with the largest sizes without hiding the pitch.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-toolbar")
    }

    /// Tap to add several with taps on the pitch (tap again to stop), or drag one straight onto it.
    private func itemSlot(_ item: BoardTool, vertical: Bool) -> some View {
        let armed = tool == item
        return slotLabel(title: item.title, isOn: armed, prominent: false, armed: armed, vertical: vertical) {
            BoardLibraryPreview(element: TacticalBoardLibrarySheet.sample(for: item, document: document), field: document.fieldType, style: document.fieldStyle)
                .frame(width: 38, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .onTapGesture { if armed { disarm() } else { arm(item) } }
        .gesture(DragGesture(minimumDistance: 10, coordinateSpace: .named(Self.editorSpace))
            .onChanged { value in dragPlacement = (item, value.location) }
            .onEnded { value in
                dragPlacement = nil
                drop(item, at: value.location)
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(armed ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if armed { disarm() } else { arm(item) } }
        .accessibilityIdentifier("board-item-\(item.rawValue)")
    }

    static func lineTypeTitle(_ element: BoardElement) -> String {
        let style = element.resolvedLineStyle
        return BoardPaletteItem.drawItems.first { item in
            item.lineStyle.map { $0.pattern == style.pattern && $0.shape == style.shape } ?? false
        }?.title ?? "Line"
    }

    private func slotBackground(isOn: Bool, prominent: Bool) -> AnyShapeStyle {
        if prominent { return AnyShapeStyle(Theme.signal) }
        return isOn ? AnyShapeStyle(Theme.signal.opacity(0.22)) : AnyShapeStyle(.clear)
    }

    private func slotLabel<Icon: View>(title: String, isOn: Bool, prominent: Bool, armed: Bool, vertical: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 2) {
            icon().frame(height: 26)
            Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(prominent ? .black : (isOn ? Theme.signal : .white))
        .frame(maxWidth: .infinity, minHeight: 46, maxHeight: vertical ? .infinity : 50)
        .background(slotBackground(isOn: isOn, prominent: prominent), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            if isOn && !prominent {
                RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Theme.signal, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if armed {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .heavy))
                    .foregroundStyle(.black)
                    .frame(width: 15, height: 15)
                    .background(Theme.signal, in: .circle)
                    .offset(x: 3, y: -3)
            }
        }
        .contentShape(.rect)
    }

    private func barSlot<Icon: View>(id: String, title: String, isOn: Bool, prominent: Bool = false, vertical: Bool,
                                     @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            slotLabel(title: title, isOn: isOn, prominent: prominent, armed: false, vertical: vertical, icon: icon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// Floating tile following a recents drag.
    @ViewBuilder
    private var dragPlacementPreview: some View {
        if let dragPlacement {
            BoardLibraryPreview(element: TacticalBoardLibrarySheet.sample(for: dragPlacement.tool, document: document), field: document.fieldType, style: document.fieldStyle)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.signal, lineWidth: 2))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .position(x: dragPlacement.location.x, y: dragPlacement.location.y - 36)
                .allowsHitTesting(false)
        }
    }

    /// Places a dragged recent item at its drop point without arming it.
    private func drop(_ item: BoardTool, at location: CGPoint) {
        guard canvasFrame.contains(location) else { return }
        if document.viewAngle.is3D {
            commit { $0.viewAngle = .top }
            showToast("Switched to Top view to place")
        }
        let size = canvasFrame.size
        let local = CGPoint(x: location.x - canvasFrame.minX, y: location.y - canvasFrame.minY)
        let element = newElement(for: item, at: fieldPoint(boardPoint(local, size: size), size: size).clamped())
        commit(recording: element.id) { $0.elements.append(element) }
        remember(item)
        flash(element.id)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func toggleArm(_ item: BoardTool) {
        if tool == item { disarm() } else { arm(item) }
    }

    /// Arms an item: taps on empty field place it (point items stay armed), drawing tools draw once.
    private func arm(_ item: BoardTool) {
        if tool.placesByTapping || item.placesByTapping { cancelPath() }
        pickingPathFor = nil
        remember(item)
        tool = item
        selectedID = nil
        selectionFeedback()
        if document.viewAngle.is3D {
            commit { $0.viewAngle = .top }
            showToast("Switched to Top view to place")
        }
    }

    /// Back to the default mode: touches select, move and pan.
    private func disarm() {
        if tool.placesByTapping { cancelPath() }
        tool = .select
        pickingPathFor = nil
    }

    private func remember(_ item: BoardTool) {
        // Items already in the bar keep their slot so nothing jumps under the finger.
        guard item.pointKind != nil, !recentTools.contains(item) else { return }
        let list = [item.rawValue] + recentToolsRaw.split(separator: ",").map(String.init).filter { $0 != item.rawValue }
        recentToolsRaw = list.prefix(8).joined(separator: ",")
    }

    /// Arms an item picked in the library.
    private func pick(_ item: BoardTool) {
        showingLibrary = false
        if item == .line { drawLineStyle = .pass }
        arm(item)
    }

    // MARK: Animation

    /// Transport in the bottom slot (same size as the tools bar): play, loop, speed, time, onion skin, library.
    private func transportBar(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            barSlot(id: "board-play", title: isPlaying ? "Pause" : "Play", isOn: false, prominent: true, vertical: vertical) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 19, weight: .bold))
            } action: {
                togglePlayback()
            }
            Menu {
                Picker("Speed", selection: $playbackSpeed) {
                    ForEach([0.5, 1.0, 2.0], id: \.self) { speed in Text(Self.speedTitle(speed)).tag(speed) }
                }
                Toggle("Loop", systemImage: "repeat", isOn: $loopsPlayback)
                    .accessibilityIdentifier("board-loop")
            } label: {
                slotLabel(title: "Speed", isOn: playbackSpeed != 1, prominent: false, armed: false, vertical: vertical) {
                    Text(Self.speedTitle(playbackSpeed)).font(.subheadline.weight(.bold).monospacedDigit())
                }
            }
            .accessibilityLabel("Playback speed")
            .accessibilityValue(Self.speedTitle(playbackSpeed))
            .accessibilityIdentifier("board-speed")
            slotLabel(title: "of \(Self.seconds(document.duration))", isOn: false, prominent: false, armed: false, vertical: vertical) {
                BoardClockLabel(clock: clock)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback time of \(Self.seconds(document.duration))")
            .accessibilityValue(followState)
            .accessibilityIdentifier("board-follow-state")
            cameraKeySlot(vertical: vertical)
            barSlot(id: "board-onion-toggle", title: "Ghosts", isOn: document.showsOnionSkin == true, vertical: vertical) {
                Image(systemName: "square.3.layers.3d").font(.system(size: 17, weight: .semibold))
            } action: {
                commit { $0.showsOnionSkin = $0.showsOnionSkin == true ? nil : true }
            }
            .accessibilityValue(document.showsOnionSkin == true ? "On" : "Off")
            barSlot(id: "board-anim-library", title: "Add", isOn: false, vertical: vertical) {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
            } action: {
                showingLibrary = true
            }
            // Leaving animation sits with the transport, next to Play, not in the top bar.
            barSlot(id: "board-animation-done", title: "Done", isOn: true, vertical: vertical) {
                Image(systemName: "checkmark").font(.system(size: 18, weight: .bold))
            } action: {
                toggleFrames()
            }
            .accessibilityLabel("Done animating")
        }
        .padding(5)
        .glassPanel(cornerRadius: 22)
        .padding(.horizontal, vertical ? 6 : 8)
        .padding(.top, vertical ? 8 : 4)
        .padding(.bottom, vertical ? 8 : 2)
        .frame(width: vertical ? 76 : nil)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-transport")
    }

    // MARK: Camera keys

    static func cameraModeTitle(_ mode: BoardCameraMode) -> String {
        switch mode {
        case .orbit: "Orbit"
        case .free: "Free"
        case .pointOfView: "POV"
        }
    }

    static func cameraKeySymbol(_ camera: BoardCamera?) -> String {
        switch camera?.resolvedMode {
        case .pointOfView: "eye.fill"
        case .free: "move.3d"
        default: "video.fill"
        }
    }

    /// Switches the 3D camera's mode through the same path as a camera gesture (stage key or base camera).
    private func setCameraMode(_ mode: BoardCameraMode) {
        var camera = displayedCamera
        camera = mode == .orbit ? camera.orbiting : { var free = camera; free.mode = mode; free.subjectID = nil; return free }()
        applyCamera(camera)
        showToast(mode == .orbit ? "Orbit camera" : "Free look: drag to look, pinch to move")
    }

    private func resetCamera() {
        if showsFrames, stageCameraKey != nil {
            applyCamera(document.viewAngle.defaultCamera)
        } else {
            liveCamera = nil
            commit { $0.camera = nil }
        }
    }

    /// Writes a camera as one undo step: into this stage's key when it has one, otherwise as the view.
    private func applyCamera(_ camera: BoardCamera) {
        if showsFrames, !showsPlayback, stageCameraKey != nil {
            commit { $0.keyframes[currentFrame].camera = camera }
        } else if showsFrames, !showsPlayback, document.animatesCamera {
            liveCamera = camera
        } else {
            commit { $0.camera = camera }
        }
    }

    /// Looks through a player's or official's eyes, at the ball when there is one.
    private func viewFrom(_ element: BoardElement) {
        if !document.viewAngle.is3D { setViewAngle(.tilted) }
        let hasBall = document.elements.contains { $0.kind == .ball }
        applyCamera(displayedCamera.pointOfView(subject: element.id, lookAt: hasBall ? .ball : .facing))
        inspectorAutoCollapsed = false
        inspectorCollapsed = true
        showToast("Viewing from \(Self.title(of: element))")
    }

    private var stageCameraKey: BoardCamera? {
        document.keyframes.indices.contains(currentFrame) ? document.keyframes[currentFrame].camera : nil
    }

    /// What the 3D view shows while editing: this stage's key, an unsaved orbit, or the base camera.
    /// During playback and scrubbing the camera follows the clock, which `Board3DStage` resolves itself.
    private var displayedCamera: BoardCamera {
        guard showsFrames else { return document.cameraOrDefault }
        if let stageCameraKey { return stageCameraKey }
        if let liveCamera { return liveCamera }
        return document.animatesCamera ? document.camera(atStage: currentFrame) : document.cameraOrDefault
    }

    /// Orbit, zoom or pan in the 3D view: updates this stage's key (one undo step per gesture), otherwise the
    /// base camera, or an unsaved view on stages between keys.
    private func cameraChanged(_ camera: BoardCamera) {
        guard showsFrames, !showsPlayback else {
            document.camera = camera
            return
        }
        if stageCameraKey != nil {
            if cameraEditStart == nil { cameraEditStart = document }
            document.keyframes[currentFrame].camera = camera
            cameraEditTask?.cancel()
            cameraEditTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let before = cameraEditStart else { return }
                cameraEditStart = nil
                if before != document { history.record(before) }
            }
        } else {
            if document.animatesCamera { liveCamera = camera } else { document.camera = camera }
            if !cameraHintShown {
                cameraHintShown = true
                showToast("Tap the camera button to animate the view")
            }
        }
    }

    private func saveCameraKey() {
        let camera = displayedCamera
        commit { $0.keyframes[currentFrame].camera = camera }
        liveCamera = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showToast("Camera saved to Stage \(currentFrame + 1)")
    }

    private func removeCameraKey() {
        liveCamera = displayedCamera
        commit { $0.keyframes[currentFrame].camera = nil }
        showToast("Camera key removed from Stage \(currentFrame + 1)")
    }

    @ViewBuilder
    private func cameraKeySlot(vertical: Bool) -> some View {
        let is3D = document.viewAngle.is3D
        let hasKey = stageCameraKey != nil
        Group {
            if is3D && hasKey {
                Menu {
                    Button("Update camera", systemImage: "video.badge.checkmark") { saveCameraKey() }
                        .accessibilityIdentifier("board-camera-update")
                    Button("Remove camera key", systemImage: "video.slash", role: .destructive) { removeCameraKey() }
                        .accessibilityIdentifier("board-camera-remove")
                } label: {
                    slotLabel(title: "Camera", isOn: true, prominent: false, armed: false, vertical: vertical) {
                        Image(systemName: "video.fill").font(.system(size: 17, weight: .semibold))
                    }
                }
            } else {
                Button {
                    if is3D { saveCameraKey() } else { showToast("Switch to 3D to animate the camera") }
                } label: {
                    slotLabel(title: "Camera", isOn: false, prominent: false, armed: false, vertical: vertical) {
                        Image(systemName: "video.badge.plus").font(.system(size: 17, weight: .semibold))
                    }
                    .opacity(is3D ? 1 : 0.4)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(hasKey ? "Camera key" : "Save camera key")
        .accessibilityValue(!is3D ? "Top view" : (hasKey ? "Stage \(currentFrame + 1) key" : "No key"))
        .accessibilityIdentifier("board-camera-key")
    }

    static func speedTitle(_ speed: Double) -> String {
        speed == 0.5 ? "½×" : "\(Int(speed))×"
    }

    static func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))s"
    }

    /// Stages as thumbnails with transition pills between them, a trailing add button and a playhead.
    private var stageStrip: some View {
        VStack(spacing: 2) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(document.keyframes.enumerated()), id: \.element.id) { index, frame in
                            stageTile(index: index, frame: frame)
                                .id(frame.id)
                            if index < document.keyframes.count - 1 {
                                transitionPill(index: index)
                            }
                        }
                        Button { addFrame() } label: {
                            Image(systemName: "plus").font(.headline)
                                .frame(width: 56, height: 40)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                                .frame(minWidth: Theme.tapTarget, minHeight: Theme.tapTarget)
                                .padding(.leading, Theme.Space.sm)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add step")
                        .accessibilityIdentifier("board-stage-add")
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.sm)
                }
                .scrollIndicators(.hidden)
                .onChange(of: currentFrame) { _, index in
                    guard document.keyframes.indices.contains(index) else { return }
                    withAnimation(.snappy) { reader.scrollTo(document.keyframes[index].id, anchor: .center) }
                }
            }
            stageScrubber
                .padding(.horizontal, Theme.Space.md)
                .padding(.bottom, 4)
        }
        .foregroundStyle(.white)
        .glassPanel()
        // Stage tiles are thumbnail-sized by nature; their captions scale to xxLarge and stop.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-stage-strip")
    }

    private func stageTile(index: Int, frame: BoardKeyframe) -> some View {
        let isCurrent = index == currentFrame && !showsPlayback
        return Button { selectFrame(index) } label: {
            VStack(spacing: 3) {
                Group {
                    if let image = stageThumbnails[frame.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color(white: 0.12)
                    }
                }
                .frame(width: 60, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(BoardStagePlayhead(clock: clock, document: document, index: index, isCurrent: isCurrent, isLive: showsPlayback))
                Text("Step \(index + 1)").font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(isCurrent ? Theme.signal : .white.opacity(0.75))
            }
            .frame(minWidth: Theme.tapTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if frame.camera != nil {
                Image(systemName: Self.cameraKeySymbol(frame.camera)).font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 17, height: 17)
                    .background(Theme.signal, in: .circle)
                    .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                    .offset(x: 2, y: -5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Step \(index + 1)")
        .accessibilityValue(frame.camera != nil ? "Camera key" : "No camera key")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("board-stage-\(index + 1)")
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") { selectFrame(index); addFrame() }
                .accessibilityIdentifier("board-stage-duplicate")
            Button("Move left", systemImage: "arrow.left") { moveStage(index, by: -1) }.disabled(index == 0)
                .accessibilityIdentifier("board-stage-move-left")
            Button("Move right", systemImage: "arrow.right") { moveStage(index, by: 1) }.disabled(index == document.keyframes.count - 1)
                .accessibilityIdentifier("board-stage-move-right")
            Button("Delete step", systemImage: "trash", role: .destructive) { deleteFrame(index) }.disabled(document.keyframes.count <= 1)
                .accessibilityIdentifier("board-stage-delete")
        }
    }

    private func transitionPill(index: Int) -> some View {
        Menu {
            Picker("Transition", selection: Binding(get: { document.keyframes[index].duration }, set: { value in
                commit { $0.keyframes[index].duration = value }
            })) {
                ForEach([0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0], id: \.self) { seconds in Text(Self.seconds(seconds)).tag(seconds) }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                Text(Self.seconds(document.keyframes[index].duration)).font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(.white.opacity(0.12), in: .capsule)
            }
            .frame(width: 50, height: 44)
            .contentShape(.rect)
        }
        .accessibilityLabel("Time to step \(index + 2)")
        .accessibilityValue(Self.seconds(document.keyframes[index].duration))
        .accessibilityIdentifier("board-transition-\(index + 1)")
    }

    /// Playhead over the whole animation with a tick at each stage.
    private var stageScrubber: some View {
        BoardStageScrubber(clock: clock, duration: document.duration,
                           stageStarts: document.keyframes.indices.map { document.frameStart($0) }) { editing in
            if editing { stopPlayback(); isScrubbing = true } else { isScrubbing = false; jump(to: clock.time) }
        }
    }

    private func moveStage(_ index: Int, by offset: Int) {
        let target = index + offset
        guard document.keyframes.indices.contains(target) else { return }
        stopPlayback()
        commit { $0.moveKeyframe(from: index, to: target) }
        selectFrame(target)
    }

    /// Renders small stage thumbnails off the main actor, debounced after edits.
    private func refreshStageThumbnails() {
        thumbnailTask?.cancel()
        guard showsFrames else { return }
        let snapshot = document
        thumbnailTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let images = await Task.detached(priority: .utility) { () -> [UUID: UIImage] in
                var top = snapshot
                top.viewAngle = .top
                let size = CGSize(width: 90, height: 60)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                var result: [UUID: UIImage] = [:]
                for (index, frame) in snapshot.keyframes.enumerated() {
                    let time = snapshot.frameStart(index)
                    result[frame.id] = UIGraphicsImageRenderer(size: size, format: format).image { context in
                        UIColor(white: 0.08, alpha: 1).setFill()
                        context.fill(CGRect(origin: .zero, size: size))
                        BoardRenderer(document: top, time: time, loadsPhotosSynchronously: true).draw(in: context.cgContext, size: size)
                    }
                }
                return result
            }.value
            guard !Task.isCancelled else { return }
            stageThumbnails = images
        }
    }

    private var currentDuration: Double {
        document.keyframes.indices.contains(currentFrame) ? document.keyframes[currentFrame].duration : 1
    }

    private func toggleFrames() {
        stopPlayback()
        disarm()
        if showsFrames {
            showsFrames = false
        } else {
            if !document.isAnimated { commit { $0.insertKeyframe(after: nil) }; currentFrame = 0 }
            showsFrames = true
        }
    }

    private func selectFrame(_ index: Int) {
        stopPlayback()
        guard document.keyframes.indices.contains(index) else { return }
        liveCamera = nil
        currentFrame = index
        applyFrame(index)
        clock.time = document.frameStart(index)
    }

    /// Loads a frame's poses into the editable elements, leaving the document untouched when they are
    /// already there. Pausing or re-selecting a stage must not mark the board edited.
    private func applyFrame(_ index: Int) {
        var next = document
        next.showFrame(index)
        if next != document { document = next }
    }

    private func addFrame() {
        stopPlayback()
        var index = currentFrame
        commit { index = $0.insertKeyframe(after: currentFrame) }
        selectFrame(index)
        selectionFeedback()
    }

    private func deleteFrame(_ index: Int) {
        stopPlayback()
        guard document.keyframes.count > 1 else { return }
        commit { $0.removeKeyframe(at: index) }
        selectFrame(min(index, document.keyframes.count - 1))
    }

    private func togglePlayback() {
        if isPlaying { stopPlayback() } else { startPlayback() }
    }

    private func startPlayback() {
        guard document.isAnimated else { return }
        selectedID = nil
        isPlaying = true
        let duration = max(0.1, document.duration)
        let offset = clock.time >= duration - 0.05 ? 0 : clock.time
        let started = Date()
        let speed = playbackSpeed
        playbackTask = Task {
            while !Task.isCancelled {
                let elapsed = offset + Date().timeIntervalSince(started) * speed
                if !loopsPlayback && elapsed >= duration {
                    clock.time = duration
                    stopPlayback()
                    return
                }
                clock.time = elapsed.truncatingRemainder(dividingBy: duration)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopPlayback() {
        guard isPlaying else { return }
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        jump(to: clock.time)
    }

    private func jump(to time: Double) {
        let index = document.frameProgress(at: time).index
        currentFrame = index
        applyFrame(index)
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            // Never encode and store mid-gesture; try again once the finger lifts.
            if interaction.isEditing || liveStart != nil || dragStartDocument != nil { scheduleSave(); return }
            save(writesThumbnail: false)
        }
    }

    private func save(writesThumbnail: Bool) {
        // A board that could not be read is never edited here, and must never be written over.
        guard loadError == nil else { return }
        var stored = document
        if stored.isAnimated { stored.showFrame(0) }
        if stored != savedDocument {
            // `store` refuses to overwrite a board whose own bytes cannot be read back.
            guard board.store(stored) else { return }
            savedDocument = stored
            thumbnailIsStale = true
        }
        if board.name != name { board.name = name; board.updatedAt = .now }
        if writesThumbnail, thumbnailIsStale || !FileManager.default.fileExists(atPath: board.thumbnailURL.path(percentEncoded: false)) {
            do {
                try TacticalBoardExporter.writeThumbnail(document: stored, to: board.thumbnailURL)
                thumbnailIsStale = false
                // Board cards reload their preview when `updatedAt` changes.
                board.updatedAt = .now
            } catch {
                // Leave it stale so the next close writes it, rather than leaving a stale preview for good.
            }
        }
        if modelContext.hasChanges { try? modelContext.save() }
    }

    private func close() {
        stopPlayback()
        saveTask?.cancel()
        save(writesThumbnail: true)
        dismiss()
    }

    private func selectionFeedback() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Playback clock

/// The animation clock. It advances every 16 ms, which would otherwise invalidate the whole editor —
/// a body of toolbar, inspector, stage strip and canvas, plus a deep `onChange(of: document)` compare —
/// sixty times a second. Keeping it in its own observable box means only the views below, which read
/// `time` in their own bodies, rebuild on a tick.
@Observable
final class BoardPlaybackClock {
    var time = 0.0
}

/// The 2D board. The only view that redraws on every tick while playing.
private struct BoardPlaybackCanvas: View {
    let clock: BoardPlaybackClock
    let isLive: Bool
    let viewport: BoardViewport
    let size: CGSize
    let makeRenderer: (Double?) -> BoardRenderer

    var body: some View {
        let renderer = makeRenderer(isLive ? clock.time : nil)
        Canvas(rendersAsynchronously: false) { context, _ in
            context.withCGContext { cg in
                cg.concatenate(viewport.transform(in: size))
                renderer.draw(in: cg, size: size)
            }
        }
    }
}

/// The 3D board, including the camera the clock resolves while playing or scrubbing.
private struct Board3DStage: View {
    let clock: BoardPlaybackClock
    let document: BoardDocument
    let isLive: Bool
    let baseCamera: BoardCamera
    let selectedID: UUID?
    let onionFrame: Int?
    let onCamera: (BoardCamera) -> Void
    let onSelect: (UUID?) -> Void
    let onMove: (UUID, BoardPoint, Bool) -> Void

    var body: some View {
        let time: Double? = isLive ? clock.time : nil
        let camera = time.map { document.camera(at: $0) } ?? baseCamera
        TacticalBoard3DView(document: document, time: time, selectedID: isLive ? nil : selectedID,
                            camera: Binding(get: { camera }, set: onCamera),
                            onSelect: onSelect, onMove: onMove, onionFrame: onionFrame)
    }
}

/// The running time in the transport bar.
private struct BoardClockLabel: View {
    let clock: BoardPlaybackClock

    var body: some View {
        Text(TacticalBoardView.seconds(clock.time)).font(.subheadline.weight(.semibold).monospacedDigit())
    }
}

/// A stage tile's border, which also marks the stage the playhead is in.
private struct BoardStagePlayhead: View {
    let clock: BoardPlaybackClock
    let document: BoardDocument
    let index: Int
    let isCurrent: Bool
    let isLive: Bool

    var body: some View {
        let playing = isLive && document.frameProgress(at: clock.time).index == index
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(isCurrent ? Theme.signal : (playing ? Theme.signal.opacity(0.5) : .white.opacity(0.15)), lineWidth: isCurrent ? 2.5 : 1)
    }
}

/// Playhead over the whole animation with a tick at each stage.
private struct BoardStageScrubber: View {
    @Bindable var clock: BoardPlaybackClock
    let duration: Double
    let stageStarts: [Double]
    let onEditing: (Bool) -> Void

    var body: some View {
        Slider(value: $clock.time, in: 0...max(0.1, duration), onEditingChanged: onEditing)
            .tint(Theme.signal)
            .background {
                GeometryReader { proxy in
                    let span = max(0.1, duration)
                    ForEach(stageStarts.indices, id: \.self) { index in
                        Capsule().fill(.white.opacity(0.35)).frame(width: 2, height: 8)
                            .position(x: 12 + (proxy.size.width - 24) * stageStarts[index] / span, y: proxy.size.height / 2 + 9)
                    }
                }
                .allowsHitTesting(false)
            }
            .accessibilityIdentifier("board-scrubber")
    }
}

// MARK: - Inspector components

/// Compact labelled slider that reports when a drag starts and ends (one undo step per drag).
private struct BoardInspectorSlider: View {
    let title: String
    let symbol: String
    let value: Double
    let range: ClosedRange<Double>
    let id: String
    let format: (Double) -> String
    let onEditing: (Bool) -> Void
    let change: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8).frame(width: 46, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: change), in: range, onEditingChanged: onEditing)
                .tint(Theme.signal)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
                .accessibilityIdentifier(id)
            Text(format(value)).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                // The readout sits in a fixed column; at large sizes it shrinks rather than wrapping.
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(minWidth: 38, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 36)
    }
}

/// Tiny preview of a line pattern, shape or caps for inspector buttons.
struct BoardLineGlyph: View {
    let style: BoardLineStyle

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            var path = Path()
            let startX: CGFloat = style.startCap == .arrow ? 6 : 2, endX = size.width - (style.endCap == .arrow ? 6 : 2)
            switch style.shape {
            case .straight:
                path.move(to: CGPoint(x: startX, y: y)); path.addLine(to: CGPoint(x: endX, y: y))
            case .wavy:
                path.move(to: CGPoint(x: startX, y: y))
                for step in 1...24 {
                    let x = startX + (endX - startX) * CGFloat(step) / 24
                    path.addLine(to: CGPoint(x: x, y: y + sin(CGFloat(step) / 24 * 4 * .pi) * 3.5))
                }
            case .zigzag:
                path.move(to: CGPoint(x: startX, y: y))
                for step in 1...8 { path.addLine(to: CGPoint(x: startX + (endX - startX) * CGFloat(step) / 8, y: y + (step % 2 == 0 ? 0 : (step % 4 == 1 ? -3.5 : 3.5)))) }
            }
            let dash: [CGFloat] = switch style.pattern {
            case .solid: []
            case .dashed: [4, 3]
            case .dotted: [0.1, 3.5]
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash))
            for (cap, x, dir) in [(style.startCap, CGFloat(2), CGFloat(-1)), (style.endCap, size.width - 2, CGFloat(1))] {
                switch cap {
                case .none: break
                case .arrow:
                    var head = Path()
                    head.move(to: CGPoint(x: x, y: y)); head.addLine(to: CGPoint(x: x - dir * 7, y: y - 4.5)); head.addLine(to: CGPoint(x: x - dir * 7, y: y + 4.5)); head.closeSubpath()
                    context.fill(head, with: .foreground)
                case .bar:
                    var bar = Path(); bar.move(to: CGPoint(x: x, y: y - 5)); bar.addLine(to: CGPoint(x: x, y: y + 5))
                    context.stroke(bar, with: .foreground, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                case .dot:
                    context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .foreground)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

extension BoardLineCap {
    var title: String {
        switch self {
        case .none: "None"
        case .arrow: "Arrow"
        case .bar: "Bar"
        case .dot: "Dot"
        }
    }

    var symbol: String {
        switch self {
        case .none: "minus"
        case .arrow: "arrowtriangle.right.fill"
        case .bar: "line.diagonal"
        case .dot: "circle.fill"
        }
    }
}

extension BoardFieldStyle {
    var symbol: String {
        switch self {
        case .grass: "leaf"
        case .night: "moon.stars"
        case .classic: "doc.plaintext"
        case .chalk: "pencil.and.scribble"
        case .court: "basketball"
        }
    }
}

private extension View {
    /// Floating dark glass panel used for editor overlays.
    func glassPanel(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(.white.opacity(0.09)))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }
}
