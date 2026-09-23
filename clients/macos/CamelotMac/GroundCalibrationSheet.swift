import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct GroundCalibrationRequest: Identifiable {
    let id = UUID()
    let sourceTime: Double
    let annotationTime: Double
    var existing: GroundCalibration?
    var isStill = false
}

/// A local alignment draft. The template is visible before the first edit;
/// no calibration is committed until the user checks alignment and applies.
struct GroundCalibrationSheet: View {
    let url: URL
    let request: GroundCalibrationRequest
    let apply: (GroundCalibration?) -> Void
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var mode: GroundCalibration.Mode
    @State private var landmark: GroundLandmark
    @State private var points: [CGPoint]
    @State private var length: Double
    @State private var width: Double
    @State private var fixedCamera: Bool
    @State private var pitchLength: Double
    @State private var pitchWidth: Double
    @State private var active = 0
    @State private var checked = false
    @State private var showOverlay = true
    @State private var showSettings = false
    @State private var goalOnRight = true
    @State private var image: CGImage?
    @State private var sourceSize = CGSize.zero
    @State private var fineTuning = false
    @State private var suggestions: [CGPoint] = []
    @State private var notice: String?
    @State private var scanning = false
    @State private var scanID = 0

    init(url: URL, request: GroundCalibrationRequest, apply: @escaping (GroundCalibration?) -> Void, onClose: (() -> Void)? = nil) {
        self.url = url; self.request = request; self.apply = apply; self.onClose = onClose
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
    }

    private var calibration: GroundCalibration {
        var result = GroundCalibration(mode: mode,
            points: GroundFieldOverlay.calibrationCorners(anchors: points, landmark: landmark),
            lengthMeters: length, widthMeters: landmark == .centreCircle ? length : width,
            referenceTime: request.annotationTime,
            imageAspectRatio: imageSize.width / max(1, imageSize.height),
            fixedCamera: fixedCamera)
        if mode == .plane, landmark != .custom {
            result.fieldReference = .init(landmark: landmark, pitchLength: pitchLength, pitchWidth: pitchWidth)
        }
        return result
    }

    private var imageSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 16, height: 9) }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    AnalysisSheetHeader(title: "Align field", cancel: { close() }, cancelID: "ground-cancel",
                                        actionTitle: "Apply", actionID: "ground-apply",
                                        disabled: !calibration.valid || !checked || image == nil || scanning) {
                        apply(calibration); close()
                    }
                    referenceBar
                    if geometry.size.width > geometry.size.height {
                        HStack(spacing: 0) {
                            preview
                            ScrollView { controls }.scrollIndicators(.hidden)
                                .frame(width: min(280, geometry.size.width * 0.38))
                        }
                    } else {
                        preview
                        controls
                    }
                }
            }.background(Theme.ink)
        }.preferredColorScheme(.dark).tint(Theme.signal)
            .frame(minWidth: 900, minHeight: 620)
            .formStyle(.grouped)
            .sheet(isPresented: $showSettings) { settings }
            .task { await loadFrame() }
            .task(id: scanID) { if scanID > 0 { await findReference() } }
            .onChange(of: points) { checked = false }
            .onChange(of: length) { checked = false }
            .onChange(of: width) { checked = false }
            .onChange(of: pitchLength) { checked = false }
            .onChange(of: pitchWidth) { checked = false }
    }

    private var referenceBar: some View {
        HStack(spacing: 4) {
            Menu {
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
                Label(landmark.title, systemImage: "sportscourt").font(.subheadline.bold())
                    .frame(minHeight: 44).labelStyle(.titleAndIcon)
            }.accessibilityIdentifier("ground-landmark-picker")
            Spacer(minLength: 0)
            Button(showOverlay ? "Hide field overlay" : "Show field overlay", systemImage: showOverlay ? "eye" : "eye.slash") { showOverlay.toggle() }
                .accessibilityIdentifier("ground-overlay-toggle")
            Button("Reference settings", systemImage: "slider.horizontal.3") { showSettings = true }
                .accessibilityIdentifier("ground-settings")
        }.labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle()).padding(.horizontal, 8)
    }

    @ViewBuilder private var preview: some View {
        if let image {
            GroundPointCanvas(image: image, points: $points, count: mode == .plane ? 4 : 2,
                              suggestions: suggestions, calibration: calibration, landmark: landmark,
                              active: $active, showOverlay: showOverlay, fineTuning: $fineTuning)
        } else {
            VStack { ProgressView(); if let notice { Text(notice).font(.caption) } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                GroundReferenceDiagram(landmark: landmark, active: active, mode: mode)
                    .frame(width: 116, height: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(active + 1) · \(GroundFieldOverlay.handleNames(landmark, count: mode == .plane ? 4 : 2)[min(active, mode == .plane ? 3 : 1)])")
                        .font(.caption.bold()).accessibilityIdentifier("ground-active-landmark")
                    Text(mode == .localScale ? "Local distance only. No pitch perspective." : "Match the yellow reference to the painted lines. White lines show the rest of the pitch.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                ForEach(0..<(mode == .plane ? 4 : 2), id: \.self) { i in
                    Button("\(i + 1)") { active = i }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(active == i ? Theme.signal.opacity(0.2) : .white.opacity(0.05), in: .rect(cornerRadius: 6))
                        .accessibilityIdentifier("ground-point-\(i)")
                }
                Menu {
                    Button("Restart reference") { chooseLandmark(landmark) }
                    Button("Flip goal side") {
                        points = points.map { CGPoint(x: 1 - $0.x, y: $0.y) }; goalOnRight.toggle()
                    }
                    Button("Find marking intersections") { scanID += 1 }
                } label: { Label("Alignment options", systemImage: "ellipsis").labelStyle(.iconOnly) }
                    .buttonStyle(AnalysisControlStyle()).accessibilityIdentifier("ground-alignment-options")
            }
            GroundPointNudgeControls(move: nudge)
                .disabled(image == nil || !points.indices.contains(active) || !showOverlay || scanning)
            if !calibration.valid {
                Text("Corners cross or dimensions are missing. Adjust the reference before applying.")
                    .font(.caption2).foregroundStyle(.orange).accessibilityIdentifier("ground-invalid")
            }
            if scanning {
                ProgressView("Finding marking intersections…").font(.caption2)
            } else if let notice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
            Button { checked.toggle() } label: {
                HStack {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.body).foregroundStyle(checked ? Theme.signal : .secondary)
                    Text(mode == .plane ? "Lines align with the video" : "Distance and points checked")
                        .font(.caption)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
            }.buttonStyle(.plain).disabled(!calibration.valid)
                .accessibilityValue(checked ? "Checked" : "Unchecked")
                .accessibilityAddTraits(checked ? [.isSelected] : [])
                .accessibilityIdentifier("ground-alignment-confirm")
            Text("Two fingers to zoom / pan · drag a handle to refine")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(10).background(Theme.inkPanel)
    }

    private var settings: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AnalysisSheetHeader(title: "Reference settings", action: { showSettings = false })
                Form {
                    Section("Dimensions · metres") {
                        if landmark == .custom {
                            Picker("Reference", selection: Binding(get: { mode }, set: { changeMode($0) })) {
                                Text("2 points · local").tag(GroundCalibration.Mode.localScale)
                                Text("4 points · ground").tag(GroundCalibration.Mode.plane)
                            }.pickerStyle(.segmented).accessibilityIdentifier("ground-reference-mode")
                        }
                        dimension(landmark == .centreCircle ? "Circle diameter" : mode == .plane ? "Reference width" : "Known distance", value: $length, id: "ground-length")
                        if mode == .plane, landmark != .centreCircle { dimension("Reference depth", value: $width, id: "ground-width") }
                        if mode == .plane, ![.custom, .halfPitch, .fullPitch].contains(landmark) {
                            dimension("Pitch length", value: $pitchLength, id: "ground-pitch-length")
                            dimension("Pitch width", value: $pitchWidth, id: "ground-pitch-width")
                        }
                        Text(landmark.guidance).font(.caption).foregroundStyle(.secondary)
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
                    if let notice { Section { Text(notice).font(.caption) } }
                    if request.existing != nil {
                        Section { Button("Remove calibration", role: .destructive) { apply(nil); close() } }
                    }
                }
            }.background(Theme.inkPanel)
        }.preferredColorScheme(.dark).tint(Theme.signal)
            .frame(width: 460, height: 580)
            .formStyle(.grouped)
    }

    private func dimension(_ title: String, value: Binding<Double>, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number)
                .multilineTextAlignment(.trailing).frame(width: 90, height: 44).accessibilityIdentifier(id)
        }
    }
    private func changeMode(_ value: GroundCalibration.Mode) {
        mode = value; active = 0; checked = false
        points = value == .plane ? GroundFieldOverlay.seed(.penaltyArea, goalOnRight: goalOnRight) : GroundFieldOverlay.seed(.custom)
    }
    private func nudge(dx: Int, dy: Int) {
        guard points.indices.contains(active), sourceSize.width > 0 else { return }
        points[active] = FieldPointNudge.move(points[active], dx: dx, dy: dy, sourceSize: sourceSize)
        fineTuning = true
    }
    private func chooseLandmark(_ value: GroundLandmark) {
        landmark = value; mode = value.mode; active = 0; checked = false; showOverlay = true
        points = GroundFieldOverlay.seed(value, goalOnRight: goalOnRight)
        length = value.defaultLengthMeters; width = value.defaultWidthMeters
    }
    private func loadFrame() async {
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
            let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
            let displaySize = CGRect(origin: .zero, size: size).applying(transform).standardized.size
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1920, height: 1920)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let result = try await generator.image(at: CMTime(seconds: request.sourceTime, preferredTimescale: 600))
            try Task.checkCancellation(); sourceSize = displaySize; image = result.image
        } catch is CancellationError {} catch { notice = "Could not open this frame. Close and try another position." }
    }
    private func findReference() async {
        guard let source = image else { return }
        scanning = true; defer { scanning = false }
        do {
            let worker = Task.detached(priority: .userInitiated) { try GroundReferenceDetection.detect(in: source) }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); suggestions = result.intersections
            notice = suggestions.isEmpty ? "No clear marking intersections found." : "Cyan dots mark possible intersections. Confirm them against the footage."
        } catch is CancellationError {} catch { notice = "Marking search unavailable. Align the reference manually." }
    }
}
private struct GroundPointCanvas: View {
    private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    let image: CGImage
    @Binding var points: [CGPoint]
    let count: Int
    let suggestions: [CGPoint]
    let calibration: GroundCalibration
    let landmark: GroundLandmark
    @Binding var active: Int
    let showOverlay: Bool
    @Binding var fineTuning: Bool
    @State private var viewport = FieldPlacementViewport()
    @State private var finger: CGPoint?
    @State private var navigationStart: FieldPlacementViewport?
    @State private var original: (points: [CGPoint], active: Int)?
    @State private var offset = CGSize.zero

    var body: some View {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let fitted = AVMakeRect(aspectRatio: imageSize, insideRect: bounds)
                let frame = viewport.frame(fitted: fitted)
                ZStack(alignment: .topLeading) {
                    Color(white: 0.08)
                    Image(decorative: image, scale: 1).resizable().frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY).allowsHitTesting(false)
                    Canvas { context, _ in
                        func mapped(_ p: CGPoint) -> CGPoint { .init(x: frame.minX + p.x * frame.width, y: frame.minY + p.y * frame.height) }
                        guard showOverlay else { return }
                        var field = context
                        field.clip(to: Path(frame))
                        let projected = Path(GroundFieldOverlay.path(calibration: calibration, frame: frame))
                        field.stroke(projected, with: .color(.black.opacity(0.7)), lineWidth: 3)
                        field.stroke(projected, with: .color(.white.opacity(0.9)), lineWidth: 1.3)
                        let reference = Path(GroundFieldOverlay.referencePath(calibration: calibration, frame: frame))
                        field.stroke(reference, with: .color(.black), lineWidth: 4)
                        field.stroke(reference, with: .color(calibration.valid ? Theme.signal : .orange), lineWidth: 2)
                        for p in suggestions {
                            let p = mapped(p)
                            context.stroke(Path(ellipseIn: .init(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.cyan), lineWidth: 1)
                        }
                        let handles = points.map(mapped)
                        for (i, p) in handles.enumerated() {
                            let circle = Path(ellipseIn: .init(x: p.x - 13, y: p.y - 13, width: 26, height: 26))
                            context.fill(circle, with: .color(i == active ? Theme.signal : .black))
                            context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                            context.draw(Text("\(i + 1)").font(.caption.bold()).foregroundStyle(i == active ? .black : .white), at: p)
                        }
                    }.allowsHitTesting(false)
                    FieldPlacementTouchSurface { if showOverlay { handle($0, frame: frame, fitted: fitted) } }
                }.clipped()
                    .overlay(alignment: .topTrailing) {
                        Button("Fit preview", systemImage: "arrow.down.right.and.arrow.up.left") { viewport = .init() }
                            .labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle()).padding(6).background(.black.opacity(0.7), in: .rect(cornerRadius: 10))
                    }
                    .overlay {
                        if showOverlay, points.indices.contains(active), finger != nil || fineTuning {
                            let focus = finger ?? CGPoint(x: frame.minX + points[active].x * frame.width, y: frame.minY + points[active].y * frame.height)
                            GroundPointLoupe(image: image, point: points[active], magnification: max(fineTuning ? 4 : 1.5, frame.width / imageSize.width * 2))
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
            let nearest = points.enumerated().min { hypot(frame.minX + $0.element.x * frame.width - location.x, frame.minY + $0.element.y * frame.height - location.y) < hypot(frame.minX + $1.element.x * frame.width - location.x, frame.minY + $1.element.y * frame.height - location.y) }
            if let nearest {
                let p = CGPoint(x: frame.minX + nearest.element.x * frame.width, y: frame.minY + nearest.element.y * frame.height)
                if hypot(p.x - location.x, p.y - location.y) <= 28 { active = nearest.offset; offset = .init(width: p.x - location.x, height: p.y - location.y) }
            }
            move(location)
        case .moveCorner(let location): move(location)
        case .endCorner:
            if let original, points.count > original.points.count, points.count < count { active = points.count }
            original = nil; finger = nil
        case .cancelCorner:
            if let original { points = original.points; active = original.active }
            original = nil; finger = nil
        case .beginNavigation: navigationStart = viewport; finger = nil; fineTuning = false
        case .navigate(let scale, let from, let to):
            if let navigationStart { viewport = navigationStart.navigating(scale: scale, from: from, to: to, fitted: fitted) }
        case .endNavigation: navigationStart = nil
        }
    }
}

private struct GroundPointNudgeControls: View {
    let move: (Int, Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("1 px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
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
            let frame = CGRect(x: 14, y: 13, width: size.width - 28, height: size.height - 26)
            let anchors = mode == .plane ? GroundFieldOverlay.referenceAnchors(landmark) : [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)]
            var calibration = GroundCalibration(mode: mode, points: mode == .plane ? GroundFieldOverlay.rectangle : anchors,
                lengthMeters: max(1, landmark.defaultLengthMeters), widthMeters: max(1, landmark.defaultWidthMeters), referenceTime: 0, imageAspectRatio: 1)
            calibration.fieldReference = .init(landmark: landmark)
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            context.stroke(Path(GroundFieldOverlay.path(calibration: calibration, frame: frame)), with: .color(.white.opacity(0.5)), lineWidth: 1)
            context.stroke(Path(GroundFieldOverlay.referencePath(calibration: calibration, frame: frame)), with: .color(Theme.signal), lineWidth: 1.5)
            for (i, point) in anchors.enumerated() {
                let p = CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
                let circle = Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
                context.fill(circle, with: .color(active == i ? Theme.signal : .black))
                context.draw(Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(active == i ? .black : .white), at: p)
            }
        }.background(.green.opacity(0.12), in: .rect(cornerRadius: 8))
            .accessibilityLabel("Reference diagram with matching numbered handles")
    }
}

private struct GroundPointLoupe: View {
    let image: CGImage
    let point: CGPoint
    let magnification: CGFloat
    var body: some View {
        GeometryReader { geometry in
            Color.black.overlay(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: CGFloat(image.width) * magnification, height: CGFloat(image.height) * magnification)
                    .offset(x: geometry.size.width / 2 - point.x * CGFloat(image.width) * magnification, y: geometry.size.height / 2 - point.y * CGFloat(image.height) * magnification)
            }.clipped().overlay { Image(systemName: "plus").foregroundStyle(Theme.signal) }
                .clipShape(.rect(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.signal, lineWidth: 2) }
        }
    }
}
