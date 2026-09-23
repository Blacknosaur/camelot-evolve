@preconcurrency import AVFoundation
import SwiftUI

struct GroundCalibrationRequest: Identifiable {
    let id = UUID()
    let sourceTime: Double
    let annotationTime: Double
    var existing: GroundCalibration?
    var isStill = false
    var sourceRange: ClosedRange<Double>? = nil
    var cameraMotion: AnnotationCameraMotion? = nil

    func referenceTime(at source: Double) -> Double { isStill ? annotationTime : source }

    func relocating(_ draft: GroundCalibration, to source: Double) -> GroundCalibration? {
        var original = draft
        original.cameraMotion = cameraMotion ?? existing?.cameraMotion
        guard var moved = original.frozen(at: referenceTime(at: source)) else { return nil }
        moved.fixedCamera = draft.fixedCamera; moved.cameraMotion = original.cameraMotion
        return moved
    }
}

/// Field setup: choose a frame, get or place a starting alignment, snap it to
/// the painted markings, review the overlay and apply. Every edit stays a local
/// draft; nothing is committed until the user confirms alignment and applies.
struct GroundCalibrationSheet: View {
    let url: URL
    let request: GroundCalibrationRequest
    let apply: (GroundCalibration?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: FieldFrameSource

    // Reference draft
    @State private var usesLines: Bool
    @State private var mode: GroundCalibration.Mode
    @State private var landmark: GroundLandmark
    @State private var points: [CGPoint]
    @State private var lines: [GroundLineObservation]
    @State private var selectedLine = GroundPitchLine.leftGoal
    @State private var circle: GroundCircleReference?
    @State private var editingHalfway = false
    @State private var centerPlaced = false
    @State private var length: Double
    @State private var width: Double
    @State private var pitchLength: Double
    @State private var pitchWidth: Double
    @State private var fixedCamera: Bool
    @State private var goalOnRight = true

    // Frame
    @State private var sourceTime: Double
    @State private var displayedTime: Double
    @State private var frameRange: ClosedRange<Double>
    @State private var frameRate = 30.0
    @State private var loadingFrame = true
    @State private var image: UIImage?
    @State private var sourceSize = CGSize.zero

    // Interaction
    @State private var active = 0
    @State private var checked: Bool
    /// Detect field and Apply are the whole flow for most clips; the method
    /// picker, handles, loupe and nudges stay one tap away.
    @State private var showsAdjustments = false
    @State private var showOverlay = true
    @State private var showSettings = false
    @State private var loupePinned = false
    @State private var fineTuning = false
    @State private var suggestions: [CGPoint] = []

    // Automation
    @State private var notice: String?
    @State private var scanning = false
    @State private var progressTitle = "Working…"
    @State private var scanID = 0
    @State private var aiScanID = 0
    @State private var snapID = 0
    @State private var findClearFrame = false
    @State private var pendingReference: PitchRegionDetection.ReferenceFrame?
    @State private var autoSnapPending = false
    @State private var evidence: PitchRegistration.Evidence?
    @State private var quality: PitchRegistration.Quality?
    @State private var snappedPoints: [CGPoint]?
    @State private var snappedLines: [GroundLineObservation]?
    @State private var circleSensitivity: Double?
    /// A new setup starts detecting as soon as the first frame is on screen.
    @State private var autoDetected = false
    /// Detection placed a reference; before that the default guess is hidden
    /// so a half-finished search never looks like a wrong answer.
    @State private var proposed = false
    /// Positions before each hand adjustment, newest last, for Undo.
    @State private var undoPoints: [[CGPoint]] = []
    /// The next snap follows a hand adjustment: keep the coach's placement if it cannot lock on.
    @State private var snapIsAutomatic = false

    init(url: URL, request: GroundCalibrationRequest, apply: @escaping (GroundCalibration?) -> Void) {
        self.url = url; self.request = request; self.apply = apply
        _source = State(initialValue: FieldFrameSource(url: url))
        _sourceTime = State(initialValue: request.sourceTime)
        _displayedTime = State(initialValue: request.sourceTime)
        _frameRange = State(initialValue: request.sourceRange ?? request.sourceTime...request.sourceTime)
        let landmark = request.existing?.fieldReference?.landmark ?? (request.existing == nil ? .penaltyArea : .custom)
        _landmark = State(initialValue: landmark)
        _mode = State(initialValue: request.existing?.mode ?? landmark.mode)
        _points = State(initialValue: request.existing.map { GroundFieldOverlay.editingAnchors($0, landmark: landmark) } ?? GroundFieldOverlay.seed(landmark))
        _length = State(initialValue: request.existing?.lengthMeters ?? landmark.defaultLengthMeters)
        _width = State(initialValue: request.existing?.widthMeters ?? landmark.defaultWidthMeters)
        _fixedCamera = State(initialValue: request.isStill || request.existing?.fixedCamera == true)
        _pitchLength = State(initialValue: request.existing?.fieldReference?.pitchLength ?? 105)
        _pitchWidth = State(initialValue: request.existing?.fieldReference?.pitchWidth ?? 68)
        _checked = State(initialValue: request.existing != nil)
        _lines = State(initialValue: request.existing?.lineReferences ?? [])
        _circle = State(initialValue: request.existing?.circleReference)
        _centerPlaced = State(initialValue: request.existing?.circleReference != nil)
        _usesLines = State(initialValue: request.existing?.lineReferences != nil)
    }

    // MARK: - Draft model

    /// Hand adjustment moves the whole pitch (drag, pinch, turn) and corners fix the angle.
    /// Traced lines, the centre-spot workflow and two-point distances keep their own handles.
    private var adjustsWhole: Bool {
        showsAdjustments && !usesLines && circle == nil && mode == .plane
    }

    private var revealsOverlay: Bool {
        showsAdjustments || proposed || quality != nil || request.existing != nil
    }

    private var aspect: Double { Double(image?.size.width ?? 16) / Double(max(1, image?.size.height ?? 9)) }

    private var calibration: GroundCalibration {
        if usesLines {
            if let fit = lineFit { return fit.calibration }
            if lines.isEmpty, let existing = request.existing,
               let moved = request.relocating(existing, to: displayedTime) { return moved }
            return GroundCalibration(mode: .plane, points: [], lengthMeters: pitchWidth, widthMeters: pitchLength,
                                     referenceTime: request.referenceTime(at: displayedTime), imageAspectRatio: aspect, fixedCamera: fixedCamera)
        }
        var result = GroundCalibration(mode: mode,
            points: GroundFieldOverlay.calibrationCorners(anchors: circle?.anchors ?? (circle == nil ? points : []), landmark: landmark),
            lengthMeters: length, widthMeters: landmark == .centreCircle ? length : width,
            referenceTime: request.referenceTime(at: displayedTime),
            imageAspectRatio: aspect, fixedCamera: fixedCamera)
        if mode == .plane, landmark != .custom {
            result.fieldReference = .init(landmark: landmark, pitchLength: pitchLength, pitchWidth: pitchWidth)
        }
        result.circleReference = circle
        return result
    }

    private var lineFit: GroundLineAlignment.Fit? {
        GroundLineAlignment.fit(lines, length: pitchLength, width: pitchWidth,
                                time: request.referenceTime(at: displayedTime), aspect: aspect, fixed: fixedCamera)
    }

    private var linePoints: Binding<[CGPoint]> {
        Binding(get: { lines.first { $0.kind == selectedLine }?.points ?? [] }, set: { value in
            if let i = lines.firstIndex(where: { $0.kind == selectedLine }) { lines[i].points = value }
            else { lines.append(.init(kind: selectedLine, points: value)) }
            checked = false
        })
    }

    private var editingPoints: Binding<[CGPoint]> {
        if usesLines { return linePoints }
        guard circle != nil else { return $points }
        return Binding(get: { editingHalfway ? circle?.halfway ?? [] : circle?.farTouchline ?? circle.map { [$0.center] } ?? [] }, set: { value in
            if editingHalfway { circle?.halfway = value }
            else if circle?.farTouchline != nil { circle?.farTouchline = value }
            else if let point = value.first { circle?.center = point; centerPlaced = true }
            if circle?.farTouchline != nil { updateCenterFromTouchline() }
            checked = false
        })
    }

    private var editingCount: Int {
        if usesLines { return 2 }
        if circle != nil { return editingHalfway || circle?.farTouchline != nil ? 2 : 1 }
        return mode == .plane ? 4 : 2
    }

    private var frameReady: Bool { image != nil && !loadingFrame && sourceTime == displayedTime && !scanning }
    private var canSnap: Bool {
        guard frameReady, !usesLines || lineFit != nil else { return false }
        if circle != nil { return true }
        return calibration.valid && calibration.mode == .plane && calibration.fieldReference != nil
    }
    private var canApply: Bool {
        calibration.valid && (usesLines || circle == nil || centerPlaced) && frameReady
    }

    private func updateCenterFromTouchline() {
        guard circle?.farTouchline != nil else { return }
        if let center = circle?.centerFromTouchline(pitchWidth: pitchWidth, diameter: length) { circle?.center = center; centerPlaced = true }
        else { centerPlaced = false }
    }

    private func invalidateSnap() { quality = nil; snappedPoints = nil; snappedLines = nil }

    // MARK: - Layout

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if geometry.size.width > geometry.size.height {
                        HStack(spacing: 0) {
                            VStack(spacing: 0) { preview; frameControls }
                            ScrollView { controls }.scrollIndicators(.hidden)
                                .frame(width: min(300, geometry.size.width * 0.4))
                        }
                    } else {
                        preview
                        frameControls
                        controls
                    }
                }
            }.background(Theme.ink)
                .navigationTitle("Line up the pitch").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.accessibilityIdentifier("ground-cancel")
                    }
                    if request.existing != nil {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Remove", role: .destructive) { apply(nil); dismiss() }
                                .accessibilityIdentifier("ground-remove")
                        }
                    }
                }
        }.preferredColorScheme(.dark).tint(Theme.signal)
            .sheet(isPresented: $showSettings) { settings }
            .task(id: sourceTime) { await loadFrame() }
            .task(id: scanID) { if scanID > 0 { await findIntersections() } }
            .task(id: aiScanID) { if aiScanID > 0 { await detectPitch() } }
            .task(id: snapID) { if snapID > 0 { await snapToMarkings() } }
            .onChange(of: points) { checked = false; if points != snappedPoints { invalidateSnap() } }
            .onChange(of: lines) { if lines != snappedLines { invalidateSnap() } }
            .onChange(of: circle) { circleSensitivity = circle?.pixelSensitivity(imageSize: sourceSize); if circle != nil { invalidateSnap() } }
            .onChange(of: usesLines) { checked = false; invalidateSnap() }
            .onChange(of: length) { checked = false; invalidateSnap(); updateCenterFromTouchline() }
            .onChange(of: width) { checked = false; invalidateSnap() }
            .onChange(of: pitchLength) { checked = false; invalidateSnap() }
            .onChange(of: pitchWidth) { checked = false; invalidateSnap(); updateCenterFromTouchline() }
            .onChange(of: sourceTime) {
                checked = false; fineTuning = false; suggestions = []; scanID = 0; aiScanID = 0; snapID = 0; notice = nil
                evidence = nil; invalidateSnap()
            }
    }

    @ViewBuilder private var preview: some View {
        if let image {
            GroundPointCanvas(image: image, points: editingPoints, count: editingCount,
                              suggestions: suggestions, calibration: calibration, landmark: landmark,
                              active: $active, showOverlay: showOverlay && revealsOverlay, fineTuning: $fineTuning, pinnedLoupe: loupePinned,
                              referenceLines: previewReferenceLines, drawingLine: usesLines || (!editingHalfway && circle?.farTouchline != nil),
                              adjustsWhole: adjustsWhole,
                              beginEdit: {
                                  notice = nil
                                  if undoPoints.last != points { undoPoints.append(points) }
                                  if undoPoints.count > 30 { undoPoints.removeFirst() }
                              },
                              endEdit: autoSnap)
                .allowsHitTesting(frameReady)
                .overlay { if loadingFrame { ProgressView().padding(12).background(.black.opacity(0.7), in: .circle) } }
                .overlay(alignment: .topLeading) { qualityBadge }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text(notice ?? "Loading frame…").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var qualityBadge: some View {
        if showOverlay, let quality {
            HStack(spacing: 6) {
                Circle().fill(tone(for: quality.grade)).frame(width: 8, height: 8)
                Text(plainQuality(quality.grade)).font(.caption.weight(.semibold)).lineLimit(1)
            }.padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.72), in: .capsule)
                .padding(8).allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Snap quality").accessibilityValue(quality.summary)
                .accessibilityIdentifier("ground-quality")
        }
    }

    private var previewReferenceLines: [GroundLineObservation] {
        if usesLines { return lines }
        guard let circle else { return [] }
        if editingHalfway { return [.init(kind: .halfway, points: circle.halfway)] }
        return circle.farTouchline.map { [.init(kind: .farTouch, points: $0)] } ?? []
    }

    @ViewBuilder private var frameControls: some View {
        if !request.isStill, frameRange.upperBound > frameRange.lowerBound {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    Button("−1s") { changeFrame(by: -1) }
                        .accessibilityLabel("Back one second").accessibilityIdentifier("ground-second-back")
                    Button("Previous frame", systemImage: "backward.frame.fill") { changeFrame(by: -1 / frameRate) }
                        .accessibilityIdentifier("ground-frame-back")
                    Spacer(minLength: 2)
                    Text(timelineTimecode(sourceTime - frameRange.lowerBound, includesTenths: true))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .accessibilityIdentifier("ground-frame-time")
                        .accessibilityValue(sourceTime.formatted(.number.precision(.fractionLength(3))))
                    Spacer(minLength: 2)
                    Button("Next frame", systemImage: "forward.frame.fill") { changeFrame(by: 1 / frameRate) }
                        .accessibilityIdentifier("ground-frame-forward")
                    Button("+1s") { changeFrame(by: 1) }
                        .accessibilityLabel("Forward one second").accessibilityIdentifier("ground-second-forward")
                }.labelStyle(.iconOnly).buttonStyle(AnalysisTransportStyle())
                Slider(value: Binding(get: { sourceTime }, set: { setFrame($0) }), in: frameRange)
                    .accessibilityLabel("Field reference time").accessibilityIdentifier("ground-frame-scrubber")
                    .padding(.horizontal, 10)
            }.padding(.bottom, 6).background(Theme.inkTimeline)
        }
    }

    private func changeFrame(by delta: Double) { setFrame(sourceTime + delta) }
    private func setFrame(_ time: Double) {
        let next = min(frameRange.upperBound, max(frameRange.lowerBound, (time * frameRate).rounded() / frameRate))
        if abs(next - sourceTime) > 0.0001 { sourceTime = next }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            statusRow
            HStack(spacing: 8) {
                Button(quality == nil ? "Find the pitch" : "Try again", systemImage: "sparkles") { findClearFrame = false; aiScanID += 1 }
                    .buttonStyle(EditorActionStyle(prominent: quality == nil && !scanning))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .disabled(!frameReady)
                    .accessibilityIdentifier("ground-auto-align")
                Button("Looks right", systemImage: "checkmark") { apply(calibration); dismiss() }
                    .buttonStyle(EditorActionStyle(prominent: quality != nil))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .disabled(!canApply)
                    .accessibilityIdentifier("ground-apply")
            }
            Button(showsAdjustments ? "Hide manual tools" : "Adjust by hand", systemImage: showsAdjustments ? "chevron.up" : "hand.draw") {
                // Placing by hand never waits for a search that is still running.
                if scanning { aiScanID = 0; pendingReference = nil; autoSnapPending = false }
                showsAdjustments.toggle()
            }
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.plain).foregroundStyle(Theme.signal)
                .accessibilityIdentifier("ground-adjustments")
            if showsAdjustments {
                if adjustsWhole { wholePitchControls } else { referenceControls }
            }
        }.padding(10).background(Theme.inkPanel)
    }

    /// What the coach sees drives where the adjustable corners sit.
    private static let visibleParts: [(String, GroundLandmark)] = [("Box", .penaltyArea), ("Centre", .centreCircle), ("Half", .halfPitch), ("Whole", .fullPitch)]

    private var wholePitchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag the lines onto the pitch. Pinch to resize and turn. Pull a dot to fix the angle.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ground-adjust-help")
            HStack(spacing: 6) {
                Text("You can see").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Self.visibleParts, id: \.0) { title, value in
                    Button(title) { undoPoints.append(points); chooseLandmark(value) }
                        .buttonStyle(EditorActionStyle(prominent: landmark == value))
                        .accessibilityAddTraits(landmark == value ? .isSelected : [])
                        .accessibilityIdentifier("ground-visible-\(value.rawValue)")
                }
            }
            HStack(spacing: 8) {
                Button("Undo", systemImage: "arrow.uturn.backward") { undoAdjustment() }
                    .buttonStyle(EditorActionStyle()).disabled(undoPoints.isEmpty)
                    .accessibilityIdentifier("ground-undo")
                if ![.centreCircle, .halfPitch, .fullPitch].contains(landmark) {
                    Button("Other end", systemImage: "arrow.left.arrow.right") {
                        undoPoints.append(points)
                        points = points.map { CGPoint(x: 1 - $0.x, y: $0.y) }; goalOnRight.toggle()
                    }.buttonStyle(EditorActionStyle()).accessibilityIdentifier("ground-goal-side")
                }
                Spacer(minLength: 0)
                moreWaysMenu
            }
        }
    }

    private func undoAdjustment() {
        guard let previous = undoPoints.popLast() else { return }
        points = previous
    }

    /// After a hand adjustment, lock onto the painted lines when they are clear enough.
    private func autoSnap() {
        guard canSnap else { return }
        snapIsAutomatic = true
        snapID += 1
    }

    private var moreWaysMenu: some View {
        Menu {
            Section("Other ways to line up") {
                Button("Goal area", systemImage: "sportscourt") { chooseLandmark(.goalArea) }
                Button("Trace white lines", systemImage: "line.diagonal") { chooseLines() }
                Button("Goal width · local scale") { chooseLandmark(.goalWidth) }
                Button("Custom distance or rectangle") { chooseLandmark(.custom) }
            }
            Button(showOverlay ? "Hide pitch lines" : "Show pitch lines", systemImage: showOverlay ? "eye.slash" : "eye") { showOverlay.toggle() }
                .accessibilityIdentifier("ground-overlay-toggle")
            Button("Pitch size and camera", systemImage: "slider.horizontal.3") { showSettings = true }
                .accessibilityIdentifier("ground-settings")
        } label: {
            Label("More", systemImage: "ellipsis.circle").font(.subheadline.weight(.semibold))
                .frame(minHeight: 44).contentShape(.rect)
        }
        .accessibilityIdentifier("ground-alignment-options")
    }

    /// The expert placements keep their own tools: traced lines, the centre-spot circle and two-point distances.
    private var referenceControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                methodPicker
                Spacer(minLength: 0)
                if !usesLines, circle == nil, ![.centreCircle, .goalWidth, .custom].contains(landmark) {
                    Button(goalOnRight ? "Goal on the right" : "Goal on the left", systemImage: goalOnRight ? "arrow.right.to.line" : "arrow.left.to.line") {
                        points = points.map { CGPoint(x: 1 - $0.x, y: $0.y) }; goalOnRight.toggle()
                    }.font(.caption.bold()).buttonStyle(.plain).foregroundStyle(Theme.signal).frame(minHeight: 44)
                        .accessibilityIdentifier("ground-goal-side")
                }
            }
            HStack(spacing: 2) {
                Button("Snap to lines", systemImage: "scope") { snapID += 1 }
                    .buttonStyle(EditorActionStyle(prominent: canSnap && quality == nil)).labelStyle(.titleAndIcon)
                    .frame(height: 44).disabled(!canSnap)
                    .accessibilityIdentifier("ground-snap")
                Spacer(minLength: 0)
                Button(showOverlay ? "Hide overlay" : "Show overlay", systemImage: showOverlay ? "eye" : "eye.slash") { showOverlay.toggle() }
                    .accessibilityIdentifier("ground-overlay-toggle")
                Button(loupePinned ? "Hide loupe" : "Show loupe", systemImage: loupePinned ? "magnifyingglass.circle.fill" : "magnifyingglass.circle") {
                    loupePinned.toggle(); fineTuning = loupePinned
                }.accessibilityIdentifier("ground-fine-tune")
                Button("Reference settings", systemImage: "slider.horizontal.3") { showSettings = true }
                    .accessibilityIdentifier("ground-settings")
                optionsMenu
            }.buttonStyle(AnalysisTransportStyle()).labelStyle(.iconOnly)
            if usesLines { visibleLineControls }
            else if circle != nil { circleControls }
            else { landmarkControls }
            GroundPointNudgeControls(move: nudge)
                .disabled(!frameReady || !editingPoints.wrappedValue.indices.contains(active) || !showOverlay)
        }
    }

    private var methodPicker: some View {
        Menu {
            Button("Trace visible lines", systemImage: "line.diagonal") { chooseLines() }
            Section("Field overlay") {
                ForEach([GroundLandmark.penaltyArea, .goalArea, .centreCircle, .halfPitch, .fullPitch]) { value in
                    Button(value.title) { chooseLandmark(value) }
                }
            }
            Section("Other references") {
                Button("Goal width · local scale") { chooseLandmark(.goalWidth) }
                Button("Custom distance / rectangle") { chooseLandmark(.custom) }
            }
        } label: {
            Label(usesLines ? "Trace lines" : landmark.title, systemImage: usesLines ? "line.diagonal" : "sportscourt")
                .font(.subheadline.bold()).labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
                .frame(minHeight: 44)
        }.layoutPriority(1).accessibilityLabel("Reference method").accessibilityIdentifier("ground-landmark-picker")
    }

    private var optionsMenu: some View {
        Menu {
            if circle != nil {
                Button("Use manual circle handles") { points = circle?.anchors ?? points; circle = nil; active = 0; checked = false }
            }
            if !usesLines, circle == nil {
                Button("Flip goal side", systemImage: "arrow.left.arrow.right") { points = points.map { CGPoint(x: 1 - $0.x, y: $0.y) }; goalOnRight.toggle() }
            }
            Button("Restart reference", systemImage: "arrow.counterclockwise", role: .destructive) {
                if usesLines { lines = []; checked = false } else { chooseLandmark(landmark) }
            }
        } label: { Label("Alignment options", systemImage: "ellipsis") }
            .accessibilityIdentifier("ground-alignment-options")
    }

    private var landmarkControls: some View {
        HStack(spacing: 6) {
            ForEach(0..<editingCount, id: \.self) { i in
                Button { active = i } label: {
                    Text("\(i + 1)").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(active == i ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(active == i ? Theme.signal : .white.opacity(0.07), in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                }.buttonStyle(.plain)
                    .accessibilityLabel("Point \(i + 1), \(GroundFieldOverlay.handleNames(landmark, count: editingCount)[i])")
                    .accessibilityAddTraits(active == i ? [.isSelected] : [])
                    .accessibilityIdentifier("ground-point-\(i)")
            }
            GroundReferenceDiagram(landmark: landmark, active: active, mode: mode)
                .frame(width: 96, height: 44)
        }
    }

    private var circleControls: some View {
        HStack(spacing: 4) {
            Button("Centre spot", systemImage: "scope") {
                if circle?.farTouchline != nil { circle?.farTouchline = nil; centerPlaced = false; checked = false }
                editingHalfway = false; active = 0
            }.tint(editingHalfway || circle?.farTouchline != nil ? .secondary : Theme.signal)
                .accessibilityIdentifier("ground-circle-center")
            Spacer(minLength: 0)
            Button("Touchline") {
                if circle?.farTouchline == nil { circle?.farTouchline = []; centerPlaced = false; checked = false }
                editingHalfway = false; active = 0
            }.tint(circle?.farTouchline != nil && !editingHalfway ? Theme.signal : .secondary)
                .accessibilityIdentifier("ground-circle-touchline")
            Button("Halfway line", systemImage: "line.diagonal") { editingHalfway = true; active = 0 }
                .tint(editingHalfway ? Theme.signal : .secondary)
                .accessibilityIdentifier("ground-circle-halfway")
        }.font(.caption.bold()).frame(minHeight: 44)
    }

    private var visibleLineControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Menu {
                    ForEach(GroundPitchLine.allCases) { value in
                        Button(value.title) { selectedLine = value; active = 0; fineTuning = false }
                    }
                } label: { Label(selectedLine.title, systemImage: "line.diagonal").font(.caption.bold()) }
                    .frame(minHeight: 44).accessibilityIdentifier("ground-line-picker")
                Spacer(minLength: 0)
                Button("Redraw line", systemImage: "trash") { linePoints.wrappedValue = []; active = 0 }
                    .buttonStyle(AnalysisTransportStyle()).labelStyle(.iconOnly).accessibilityIdentifier("ground-redraw-line")
            }
            if !lines.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(lines) { line in
                            Button(line.kind.title) { selectedLine = line.kind; active = 0 }
                                .font(.caption2).padding(.horizontal, 8).frame(minHeight: 44)
                                .background(line.kind == selectedLine ? Theme.signal.opacity(0.2) : .white.opacity(0.05), in: .rect(cornerRadius: 6))
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Status

    private enum Tone { case neutral, positive, warning }

    private func plainQuality(_ grade: PitchRegistration.Quality.Grade) -> String {
        switch grade {
        case .good: "Lines match"
        case .check: "Nearly there"
        case .poor: "Not matching yet"
        }
    }

    private func tone(for grade: PitchRegistration.Quality.Grade) -> Color {
        switch grade {
        case .good: Theme.signal
        case .check: .orange
        case .poor: .red
        }
    }

    private var status: (text: String, tone: Tone) {
        if scanning { return (progressTitle, .neutral) }
        if let notice { return (notice, .neutral) }
        if !calibration.valid, !usesLines, circle == nil {
            return ("Corners cross or dimensions are missing. Adjust the reference before applying.", .warning)
        }
        if let quality {
            switch quality.grade {
            case .good: return ("The pitch lines match the video. Check they sit on the white lines, then tap Looks right.", .positive)
            case .check: return ("Mostly matches. Check the lines furthest from the camera before you continue.", .warning)
            case .poor: return ("Not a good match. Move to a frame with more white lines and tap Try again, or adjust by hand.", .warning)
            }
        }
        if usesLines {
            if lineFit != nil { return ("Field fitted from your lines. Snap to lines refines it against the video.", .neutral) }
            let missing = max(0, 4 - lines.filter { $0.points.count == 2 }.count)
            return ("Trace visible parts of \(missing == 0 ? "more" : "\(missing) more") white lines, 2 in each field direction. Corners can be offscreen.", .neutral)
        }
        if let circle {
            if let circleSensitivity, circleSensitivity > 12, centerPlaced {
                return ("Sharp angle · verify distant lines or choose a clearer frame.", .warning)
            }
            if centerPlaced {
                return (circle.farTouchline != nil ? "Perspective from the far touchline · confirm the pitch width in settings (\(pitchWidth.formatted()) m)." : "Perspective fitted · check the overlay beyond the circle, or Snap to lines.", .neutral)
            }
            return (circle.farTouchline != nil ? "Trace the far touchline. Confirm the actual pitch width in settings (currently \(pitchWidth.formatted()) m)." : "Place the point on the actual centre spot, or use Touchline if the spot is hidden.", .warning)
        }
        if mode == .localScale { return ("Place both points on the ground at a known distance, then set it in settings.", .neutral) }
        if !showsAdjustments { return ("Tap Find the pitch and the app lines up the pitch markings for you.", .neutral) }
        if adjustsWhole { return ("Move the white lines onto the pitch. They lock on when they are close.", .neutral) }
        return ("Drag the numbered handles onto the \(landmark.title.lowercased()) corners, then Snap to lines.", .neutral)
    }

    private var statusRow: some View {
        let status = status
        return HStack(alignment: .top, spacing: 8) {
            if scanning { ProgressView().controlSize(.small) }
            else {
                Circle().fill(status.tone == .positive ? Theme.signal : status.tone == .warning ? Color.orange : Color.white.opacity(0.35))
                    .frame(width: 7, height: 7).padding(.top, 5)
            }
            Text(status.text).font(.caption).foregroundStyle(status.tone == .warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 22)
            .accessibilityElement(children: .ignore).accessibilityLabel("Field setup status").accessibilityValue(status.text)
            .accessibilityIdentifier(usesLines ? "ground-line-status" : circle != nil ? "ground-circle-status" : "ground-status")
    }

    // MARK: - Settings

    private var settings: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Dimensions · metres") {
                        if landmark == .custom, !usesLines {
                            Picker("Reference", selection: Binding(get: { mode }, set: { changeMode($0) })) {
                                Text("2 points · local").tag(GroundCalibration.Mode.localScale)
                                Text("4 points · ground").tag(GroundCalibration.Mode.plane)
                            }.pickerStyle(.segmented).accessibilityIdentifier("ground-reference-mode")
                        }
                        if !usesLines {
                            dimension(landmark == .centreCircle ? "Circle diameter" : mode == .plane ? "Reference width" : "Known distance", value: $length, id: "ground-length")
                            if mode == .plane, landmark != .centreCircle { dimension("Reference depth", value: $width, id: "ground-width") }
                        }
                        if usesLines || (mode == .plane && ![.custom, .halfPitch, .fullPitch].contains(landmark)) {
                            dimension("Pitch length", value: $pitchLength, id: "ground-pitch-length")
                            dimension("Pitch width", value: $pitchWidth, id: "ground-pitch-width")
                        }
                        Text(usesLines ? "Trace any visible part of named lines; their intersections may be offscreen." : landmark.guidance)
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Football defaults are editable. The overlay is an alignment aid, not proof of accurate measurements.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !request.isStill {
                        Section("Camera") {
                            Toggle("Camera stays fixed", isOn: $fixedCamera)
                            Text("Leave off for moving footage. One camera track is reused for measurements and floor effects.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let quality {
                        Section("Snap result") {
                            LabeledContent("Fit", value: quality.grade.title)
                            LabeledContent("Median residual", value: "\(quality.residualPixels.formatted(.number.precision(.fractionLength(2)))) px")
                            LabeledContent("Evidence coverage", value: quality.coverage.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Supported lines", value: "\(quality.supportedLines)")
                            Text("Residual and coverage describe agreement with visible paint, not metric accuracy.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if request.existing != nil {
                        Section { Button("Remove calibration", role: .destructive) { apply(nil); dismiss() } }
                    }
                }.scrollDismissesKeyboard(.interactively)
            }.background(Theme.inkPanel)
                .navigationTitle("Reference settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(Theme.ink, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        }.presentationDetents([.large]).presentationDragIndicator(.visible).preferredColorScheme(.dark).tint(Theme.signal)
    }

    /// Commits on every keystroke, so closing the sheet never drops a value.
    private func dimension(_ title: String, value: Binding<Double>, id: String) -> some View {
        let text = Binding<String>(
            get: { value.wrappedValue.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)) },
            set: { typed in
                let normalized = typed.replacingOccurrences(of: ",", with: ".")
                if let parsed = Double(normalized), parsed.isFinite, parsed >= 0 { value.wrappedValue = parsed }
                else if normalized.isEmpty { value.wrappedValue = 0 }
            })
        return HStack {
            Text(title)
            Spacer()
            TextField(title, text: text).keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing).frame(width: 90, height: 44).accessibilityIdentifier(id)
        }
    }

    // MARK: - Editing actions

    private func changeMode(_ value: GroundCalibration.Mode) {
        mode = value; active = 0; checked = false
        points = value == .plane ? GroundFieldOverlay.seed(.penaltyArea, goalOnRight: goalOnRight) : GroundFieldOverlay.seed(.custom)
    }

    private func nudge(dx: Int, dy: Int) {
        var selected = editingPoints.wrappedValue
        guard selected.indices.contains(active), sourceSize.width > 0 else { return }
        selected[active] = FieldPointNudge.move(selected[active], dx: dx, dy: dy, sourceSize: sourceSize)
        editingPoints.wrappedValue = selected; fineTuning = true
    }

    private func chooseLines() {
        circle = nil; centerPlaced = false; editingHalfway = false
        usesLines = true; active = 0; checked = false; showOverlay = true
    }

    private func chooseLandmark(_ value: GroundLandmark) {
        circle = nil; centerPlaced = false; editingHalfway = false
        usesLines = false
        landmark = value; mode = value.mode; active = 0; checked = false; showOverlay = true
        points = GroundFieldOverlay.seed(value, goalOnRight: goalOnRight)
        length = value.defaultLengthMeters; width = value.defaultWidthMeters
    }

    // MARK: - Frames

    private func loadFrame() async {
        let target = sourceTime
        loadingFrame = true
        defer { if sourceTime == target { loadingFrame = false } }
        do {
            if image != nil { try await Task.sleep(for: .milliseconds(60)) }
            let metadata = try await source.metadata()
            let rate = metadata.frameRate
            let requestedRange = request.sourceRange ?? 0...metadata.duration
            let lower = min(requestedRange.lowerBound, request.sourceTime)
            let upper = max(lower, min(metadata.duration - 1 / rate, max(requestedRange.upperBound, request.sourceTime)))
            if !request.isStill, target > upper {
                try Task.checkCancellation()
                frameRange = lower...upper; sourceTime = upper
                return
            }
            let frame = try await source.image(at: min(upper, target))
            try Task.checkCancellation()
            guard sourceTime == target else { return }
            if image != nil, displayedTime != target {
                if let moved = request.relocating(calibration, to: target) {
                    if usesLines { lines = moved.lineReferences ?? [] }
                    else { points = GroundFieldOverlay.editingAnchors(moved, landmark: landmark); circle = moved.circleReference }
                } else {
                    circle = nil; centerPlaced = false
                    if usesLines { lines = [] }
                    notice = "Align the reference on this frame, then confirm the lines."
                }
                checked = false
            }
            sourceSize = metadata.displaySize; frameRate = rate; frameRange = lower...upper
            displayedTime = target; image = UIImage(cgImage: frame)
            evidence = nil
            if !autoDetected, request.existing == nil, pendingReference == nil {
                autoDetected = true; aiScanID += 1
            }
            circleSensitivity = circle?.pixelSensitivity(imageSize: sourceSize)
            if let pending = pendingReference, abs(pending.time - target) < 1 / 600 {
                pendingReference = nil; useProposal(pending.proposal)
                if autoSnapPending { autoSnapPending = false; if quality == nil { snapID += 1 } }
            }
        } catch is CancellationError {} catch { notice = "Could not open this frame. Choose another position." }
    }

    // MARK: - Automation

    private func findIntersections() async {
        guard let source = image?.cgImage else { return }
        scanning = true; progressTitle = "Finding marking intersections…"; defer { scanning = false }
        do {
            let worker = Task.detached(priority: .userInitiated) { try GroundReferenceDetection.detect(in: source) }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); suggestions = result.intersections
            notice = suggestions.isEmpty ? "No clear marking intersections found." : "Cyan dots mark possible intersections. Confirm them against the footage."
        } catch is CancellationError {} catch { notice = "Marking search unavailable. Align the reference manually." }
    }

    /// One tap does the whole setup: detect on this frame; if that is not a
    /// snapped fit, search the clip for a clearer frame, jump there, place the
    /// detected landmark with its orientation and snap it to the paint.
    private func detectPitch() async {
        guard let source = image?.cgImage else { return }
        let frame = displayedTime, pitchLength = pitchLength, pitchWidth = pitchWidth
        scanning = true; notice = nil
        progressTitle = "Finding the pitch…"
        defer { scanning = false }
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try PitchRegionDetection.detect(in: source, pitchLength: pitchLength, pitchWidth: pitchWidth)
            }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard displayedTime == frame, sourceTime == frame else { return }
            if let first = result.first, first.registration?.quality.grade != nil, first.registration?.quality.grade != .poor {
                useProposal(first); return
            }
            if !request.isStill {
                progressTitle = "Looking for a clearer view of the pitch…"
                let range = frameRange, url = url
                let search = Task.detached(priority: .userInitiated) {
                    try await PitchRegionDetection.findReference(url: url, range: range, preferred: frame,
                                                                 pitchLength: pitchLength, pitchWidth: pitchWidth)
                }
                let found = try await withTaskCancellationHandler { try await search.value } onCancel: { search.cancel() }
                try Task.checkCancellation()
                if let found {
                    if abs(found.time - frame) < 1 / 600 { useProposal(found.proposal); await finishAutomaticSetup() }
                    else { pendingReference = found; autoSnapPending = true; sourceTime = found.time }
                    return
                }
            }
            if let first = result.first { useProposal(first); await finishAutomaticSetup() }
            else if canSnap { scanning = false; await snapToMarkings() }
            else { notice = "Couldn't find pitch markings in this clip. Use Adjust by hand on a frame where lines are visible." }
        } catch is CancellationError {} catch {
            if canSnap { scanning = false; await snapToMarkings() }
            else { notice = "Automatic lining up isn't available here. Use Adjust by hand." }
        }
    }

    /// A proposal without a snapped registration still needs the paint fit.
    private func finishAutomaticSetup() async {
        guard quality == nil, canSnap || circle != nil else { return }
        scanning = false
        await snapToMarkings()
        if quality != nil { notice = nil }
    }

    private func useProposal(_ proposal: PitchRegionDetection.Proposal) {
        proposed = true
        chooseLandmark(proposal.landmark)
        if let registration = proposal.registration, registration.quality.grade != .poor {
            let anchors = GroundFieldOverlay.editingAnchors(registration.calibration, landmark: proposal.landmark)
            points = anchors; snappedPoints = anchors; snappedLines = nil
            quality = registration.quality
            circle = nil; centerPlaced = false; notice = nil
            return
        }
        let draft = GroundCalibration(mode: .plane, points: proposal.corners,
            lengthMeters: proposal.landmark.defaultLengthMeters, widthMeters: proposal.landmark.defaultWidthMeters,
            referenceTime: displayedTime, imageAspectRatio: aspect)
        points = GroundFieldOverlay.editingAnchors(draft, landmark: proposal.landmark)
        circle = proposal.circle; centerPlaced = false; editingHalfway = false; active = 0
        checked = false; invalidateSnap()
        notice = proposal.circle == nil
            ? "A rough match only. Use Adjust by hand to move the corners onto the lines."
            : "Centre circle found. Use Adjust by hand to place the centre spot."
    }

    private func snapToMarkings() async {
        let automatic = snapIsAutomatic
        snapIsAutomatic = false
        guard let cgImage = image?.cgImage else { return }
        if !usesLines, let circle, let anchors = circle.anchors {
            points = anchors; self.circle = nil; centerPlaced = false; editingHalfway = false
        }
        let draft = calibration
        guard draft.valid, draft.mode == .plane, draft.fieldReference != nil else {
            notice = "Place a field reference before snapping."; return
        }
        let frame = displayedTime
        scanning = true; progressTitle = "Matching the white lines…"; notice = nil
        defer { scanning = false }
        let existing = evidence
        let prepared = await Task.detached(priority: .userInitiated) { existing ?? PitchRegistration.Evidence(image: cgImage) }.value
        guard let prepared, displayedTime == frame else { notice = "Could not read this frame's markings."; return }
        evidence = prepared
        let result = await Task.detached(priority: .userInitiated) { PitchRegistration.snap(draft, evidence: prepared) }.value
        guard displayedTime == frame, sourceTime == frame else { return }
        guard let result, !(automatic && result.quality.grade == .poor) else {
            notice = automatic ? "Couldn't lock onto the white lines here, so it stays where you put it."
                : "No markings found near the overlay. Move it closer to the white lines and try again."
            return
        }
        if usesLines {
            guard let moved = PitchRegistration.reproject(lines, onto: result.calibration, pitchLength: pitchLength, pitchWidth: pitchWidth) else {
                notice = "Snapped alignment could not be applied to the traced lines."; return
            }
            lines = moved; snappedLines = moved; snappedPoints = nil
        } else {
            let anchors = GroundFieldOverlay.editingAnchors(result.calibration, landmark: landmark)
            points = anchors; snappedPoints = anchors; snappedLines = nil
        }
        quality = result.quality; checked = false
    }
}

private struct GroundPointCanvas: View {
    let image: UIImage
    @Binding var points: [CGPoint]
    let count: Int
    let suggestions: [CGPoint]
    let calibration: GroundCalibration
    let landmark: GroundLandmark
    @Binding var active: Int
    let showOverlay: Bool
    @Binding var fineTuning: Bool
    var pinnedLoupe = false
    var referenceLines: [GroundLineObservation] = []
    var drawingLine = false
    /// One finger away from a corner slides the whole pitch; two fingers resize and turn it.
    var adjustsWhole = false
    var beginEdit: () -> Void = {}
    var endEdit: () -> Void = {}
    @State private var viewport = FieldPlacementViewport()
    /// Set while the whole pitch is being moved: the positions and finger it started from.
    @State private var wholeStart: (points: [CGPoint], location: CGPoint)?
    @State private var pinchStart: [CGPoint]?
    @State private var draggingCorner = false
    @State private var finger: CGPoint?
    @State private var navigationStart: FieldPlacementViewport?
    @State private var original: (points: [CGPoint], active: Int)?
    @State private var offset = CGSize.zero

    var body: some View {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let fitted = AVMakeRect(aspectRatio: image.size, insideRect: bounds)
                let frame = viewport.frame(fitted: fitted)
                ZStack(alignment: .topLeading) {
                    Color(white: 0.08)
                    Image(uiImage: image).resizable().frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY).allowsHitTesting(false)
                    Canvas { context, _ in
                        func mapped(_ p: CGPoint) -> CGPoint { .init(x: frame.minX + p.x * frame.width, y: frame.minY + p.y * frame.height) }
                        guard showOverlay else { return }
                        var field = context
                        field.clip(to: Path(frame))
                        let projected = Path(GroundFieldOverlay.path(calibration: calibration, frame: frame))
                        field.stroke(projected, with: .color(.black.opacity(0.7)), lineWidth: 3)
                        field.stroke(projected, with: .color(.white.opacity(0.9)), lineWidth: 1.3)
                        if !drawingLine {
                            let reference = Path(GroundFieldOverlay.referencePath(calibration: calibration, frame: frame))
                            field.stroke(reference, with: .color(.black), lineWidth: 4)
                            field.stroke(reference, with: .color(calibration.valid ? Theme.signal : .orange), lineWidth: 2)
                        }
                        for (index, line) in referenceLines.enumerated() where line.points.count == 2 {
                            let a = mapped(line.points[0]), b = mapped(line.points[1])
                            var path = Path(); path.move(to: a); path.addLine(to: b)
                            context.stroke(path, with: .color(.black), lineWidth: 5)
                            context.stroke(path, with: .color(.cyan), lineWidth: 2)
                            context.draw(Text("\(index+1)").font(.caption.bold()).foregroundStyle(.white),
                                         at: .init(x: (a.x+b.x)/2,y: (a.y+b.y)/2-12))
                        }
                        for p in suggestions {
                            let p = mapped(p)
                            context.stroke(Path(ellipseIn: .init(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.cyan), lineWidth: 1)
                        }
                        let handles = points.map(mapped)
                        for (i, p) in handles.enumerated() {
                            if adjustsWhole {
                                let dot = Path(ellipseIn: .init(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
                                context.fill(dot, with: .color(draggingCorner && i == active ? Theme.signal : .white.opacity(0.9)))
                                context.stroke(dot, with: .color(.black.opacity(0.8)), lineWidth: 2)
                            } else {
                                let circle = Path(ellipseIn: .init(x: p.x - 13, y: p.y - 13, width: 26, height: 26))
                                context.fill(circle, with: .color(i == active ? Theme.signal : .black))
                                context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                                context.draw(Text("\(i + 1)").font(.caption.bold()).foregroundStyle(i == active ? .black : .white), at: p)
                            }
                        }
                    }.allowsHitTesting(false)
                    FieldPlacementTouchSurface { if showOverlay { handle($0, frame: frame, fitted: fitted) } }
                }.clipped()
                    .overlay(alignment: .topTrailing) {
                        if !adjustsWhole || viewport != .init() {
                            Button("Fit preview", systemImage: "arrow.down.right.and.arrow.up.left") { viewport = .init() }
                                .labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle()).padding(6).background(.black.opacity(0.7), in: .rect(cornerRadius: 10))
                        }
                    }
                    .overlay {
                        if showOverlay, points.indices.contains(active), (finger != nil && (!adjustsWhole || draggingCorner)) || fineTuning || pinnedLoupe {
                            let focus = finger ?? CGPoint(x: frame.minX + points[active].x * frame.width, y: frame.minY + points[active].y * frame.height)
                            GroundPointLoupe(image: image, point: points[active], magnification: max(fineTuning || pinnedLoupe ? 4 : 1.5, frame.width / image.size.width * 2))
                                .frame(width: 112, height: 100)
                                .position(FieldPlacementViewport.loupeCenter(finger: focus, bounds: bounds, size: .init(width: 112, height: 100)))
                                .allowsHitTesting(false)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Selected field point magnified").accessibilityIdentifier("ground-point-loupe")
                        }
                    }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("ground-preview")
                .accessibilityValue("\(showOverlay ? "Overlay visible" : "Overlay hidden"); \(points.count) points; " + points.map { String(format: "%.4f,%.4f", Double($0.x), Double($0.y)) }.joined(separator: "; "))
    }
    private func nearestHandle(to location: CGPoint, frame: CGRect, within radius: CGFloat) -> (index: Int, point: CGPoint)? {
        points.enumerated().map { index, p in (index, CGPoint(x: frame.minX + p.x * frame.width, y: frame.minY + p.y * frame.height)) }
            .filter { hypot($0.1.x - location.x, $0.1.y - location.y) <= radius }
            .min { hypot($0.1.x - location.x, $0.1.y - location.y) < hypot($1.1.x - location.x, $1.1.y - location.y) }
            .map { (index: $0.0, point: $0.1) }
    }

    private func handle(_ action: FieldPlacementTouchState.Action, frame: CGRect, fitted: CGRect) {
        func move(_ location: CGPoint) {
            finger = location
            let target = CGPoint(x: location.x + offset.width, y: location.y + offset.height)
            let point = AnnotationViewport.sourcePoint(target, frame: frame, allowsOffscreen: true)
            if points.indices.contains(active) { points[active] = point }
            else if active == points.count, points.count < count { points.append(point) }
        }
        switch action {
        case .beginCorner(let location):
            fineTuning = false
            original = (points, active); offset = .zero
            if adjustsWhole {
                beginEdit()
                if let corner = nearestHandle(to: location, frame: frame, within: 34) {
                    active = corner.index; draggingCorner = true
                    offset = .init(width: corner.point.x - location.x, height: corner.point.y - location.y)
                    move(location)
                } else {
                    wholeStart = (points, location)
                }
                return
            }
            if drawingLine, points.count < 2 {
                let point = AnnotationViewport.sourcePoint(location, frame: frame, allowsOffscreen: true)
                if points.isEmpty { points = [point, point] } else { points.append(point) }
                active = 1; finger = location
                return
            }
            let nearest = points.enumerated().min { hypot(frame.minX + $0.element.x * frame.width - location.x, frame.minY + $0.element.y * frame.height - location.y) < hypot(frame.minX + $1.element.x * frame.width - location.x, frame.minY + $1.element.y * frame.height - location.y) }
            if let nearest {
                let p = CGPoint(x: frame.minX + nearest.element.x * frame.width, y: frame.minY + nearest.element.y * frame.height)
                if hypot(p.x - location.x, p.y - location.y) <= 28 { active = nearest.offset; offset = .init(width: p.x - location.x, height: p.y - location.y) }
            }
            move(location)
        case .moveCorner(let location):
            if let wholeStart {
                let dx = (location.x - wholeStart.location.x) / max(1, frame.width)
                let dy = (location.y - wholeStart.location.y) / max(1, frame.height)
                points = wholeStart.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            } else { move(location) }
        case .endCorner where adjustsWhole:
            let moved = original.map { $0.points != points } ?? false
            wholeStart = nil; draggingCorner = false; original = nil; finger = nil
            if moved { endEdit() }
        case .endCorner:
            if drawingLine, points.count == 2,
               hypot((points[1].x-points[0].x)*frame.width,(points[1].y-points[0].y)*frame.height) < 8 {
                points.removeLast(); active = 1
            }
            if let original, points.count > original.points.count, points.count < count { active = points.count }
            original = nil; finger = nil
        case .cancelCorner:
            if let original { points = original.points; active = original.active }
            original = nil; finger = nil; wholeStart = nil; draggingCorner = false
        case .beginNavigation where adjustsWhole:
            finger = nil; fineTuning = false
            if pinchStart == nil { beginEdit() }
            pinchStart = original?.points ?? points
        case .navigate(let scale, let from, let to, let rotation) where adjustsWhole:
            guard let pinchStart, scale.isFinite, scale > 0 else { return }
            // Scale and turn about the point between the fingers, which the pitch follows.
            let s = min(4, max(0.25, scale)), c = cos(rotation), n = sin(rotation)
            points = pinchStart.map { p in
                let x = frame.minX + p.x * frame.width - from.x, y = frame.minY + p.y * frame.height - from.y
                let screen = CGPoint(x: to.x + s * (c * x - n * y), y: to.y + s * (n * x + c * y))
                return CGPoint(x: (screen.x - frame.minX) / max(1, frame.width), y: (screen.y - frame.minY) / max(1, frame.height))
            }
        case .endNavigation where adjustsWhole:
            let moved = pinchStart != nil
            pinchStart = nil; original = nil
            if moved { endEdit() }
        case .beginNavigation: navigationStart = viewport; finger = nil; fineTuning = false
        case .navigate(let scale, let from, let to, _):
            if let navigationStart { viewport = navigationStart.navigating(scale: scale, from: from, to: to, fitted: fitted) }
        case .endNavigation: navigationStart = nil
        }
    }
}

private struct GroundPointNudgeControls: View {
    let move: (Int, Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("Nudge 1 px").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            direction("Left", symbol: "arrow.left", dx: -1, dy: 0)
            direction("Up", symbol: "arrow.up", dx: 0, dy: -1)
            direction("Down", symbol: "arrow.down", dx: 0, dy: 1)
            direction("Right", symbol: "arrow.right", dx: 1, dy: 0)
        }.accessibilityElement(children: .contain).accessibilityLabel("Fine tune selected field point")
    }

    private func direction(_ name: String, symbol: String, dx: Int, dy: Int) -> some View {
        Button { move(dx, dy) } label: {
            Label(name, systemImage: symbol).labelStyle(.iconOnly).font(.body)
                .frame(width: 44, height: 44).contentShape(.rect)
        }.buttonStyle(.plain).background(.white.opacity(0.07), in: .rect(cornerRadius: 8))
            .accessibilityLabel("Move point \(name.lowercased()) one pixel")
            .accessibilityIdentifier("ground-nudge-\(name.lowercased())")
    }
}

private struct GroundReferenceDiagram: View {
    let landmark: GroundLandmark
    let active: Int
    let mode: GroundCalibration.Mode

    var body: some View {
        Canvas { context, size in
            let frame = CGRect(x: 10, y: 9, width: size.width - 20, height: size.height - 18)
            let anchors = mode == .plane ? GroundFieldOverlay.referenceAnchors(landmark) : [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)]
            var calibration = GroundCalibration(mode: mode, points: mode == .plane ? GroundFieldOverlay.rectangle : anchors,
                lengthMeters: max(1, landmark.defaultLengthMeters), widthMeters: max(1, landmark.defaultWidthMeters), referenceTime: 0, imageAspectRatio: 1)
            calibration.fieldReference = .init(landmark: landmark)
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            context.stroke(Path(GroundFieldOverlay.path(calibration: calibration, frame: frame)), with: .color(.white.opacity(0.5)), lineWidth: 1)
            context.stroke(Path(GroundFieldOverlay.referencePath(calibration: calibration, frame: frame)), with: .color(Theme.signal), lineWidth: 1.5)
            for (i, point) in anchors.enumerated() {
                let p = CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
                let circle = Path(ellipseIn: CGRect(x: p.x - 6.5, y: p.y - 6.5, width: 13, height: 13))
                context.fill(circle, with: .color(active == i ? Theme.signal : .black))
                context.draw(Text("\(i + 1)").font(.system(size: 8, weight: .bold)).foregroundStyle(active == i ? .black : .white), at: p)
            }
        }.background(.green.opacity(0.14), in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

private struct GroundPointLoupe: View {
    let image: UIImage
    let point: CGPoint
    let magnification: CGFloat
    var body: some View {
        GeometryReader { geometry in
            Color.black.overlay(alignment: .topLeading) {
                Image(uiImage: image).resizable().frame(width: image.size.width * magnification, height: image.size.height * magnification)
                    .offset(x: geometry.size.width / 2 - point.x * image.size.width * magnification, y: geometry.size.height / 2 - point.y * image.size.height * magnification)
            }.clipped().overlay { Image(systemName: "plus").foregroundStyle(Theme.signal) }
                .clipShape(.rect(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.signal, lineWidth: 2) }
        }
    }
}
