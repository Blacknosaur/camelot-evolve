@preconcurrency import AVFoundation
import SwiftUI

struct GroundCalibrationRequest: Identifiable {
    let id = UUID()
    let sourceTime: Double
    let annotationTime: Double
    var existing: GroundCalibration?
    var isStill = false
}

/// Calibration is clip data, not a drawing. Nothing changes until Apply.
struct GroundCalibrationSheet: View {
    let url: URL
    let request: GroundCalibrationRequest
    let apply: (GroundCalibration?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: GroundCalibration.Mode
    @State private var landmark: GroundLandmark
    @State private var points: [CGPoint]
    @State private var length: Double
    @State private var width: Double
    @State private var fixedCamera: Bool
    @State private var image: UIImage?
    @State private var suggestions: [CGPoint] = []
    @State private var notice: String?
    @State private var scanning = false
    @State private var loadingFailed = false
    @State private var scanID = 0
    @FocusState private var editingDimension: Bool

    init(url: URL, request: GroundCalibrationRequest, apply: @escaping (GroundCalibration?) -> Void) {
        self.url = url; self.request = request; self.apply = apply
        _mode = State(initialValue: request.existing?.mode ?? .localScale)
        _landmark = State(initialValue: .custom)
        _points = State(initialValue: request.existing?.points ?? [])
        _length = State(initialValue: request.existing?.lengthMeters ?? 0)
        _width = State(initialValue: request.existing?.widthMeters ?? 0)
        _fixedCamera = State(initialValue: request.isStill || request.existing?.fixedCamera == true)
    }

    private var calibration: GroundCalibration {
        .init(mode: mode, points: points, lengthMeters: length, widthMeters: width,
              referenceTime: request.annotationTime, imageAspectRatio: (image?.size.width ?? 16) / max(1, image?.size.height ?? 9),
              fixedCamera: fixedCamera)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    AnalysisSheetHeader(title: "Measurements", cancel: { dismiss() }, cancelID: "ground-cancel",
                                        actionTitle: "Apply", actionID: "ground-apply", disabled: !calibration.valid || image == nil || scanning) {
                        apply(calibration); dismiss()
                    }
                    if let image {
                        GroundPointCanvas(image: image, points: $points, count: mode == .plane ? 4 : 2, suggestions: suggestions)
                            .frame(height: max(150, geometry.size.height * 0.48))
                    } else if loadingFailed {
                        ContentUnavailableView("Frame unavailable", systemImage: "video.slash", description: Text("Close Measurements and try another frame."))
                            .frame(height: max(150, geometry.size.height * 0.48))
                    } else {
                        ProgressView("Loading frame…").frame(maxWidth: .infinity).frame(height: max(150, geometry.size.height * 0.48))
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Menu {
                                ForEach(GroundLandmark.allCases) { value in
                                    Button(value.title) { chooseLandmark(value) }
                                }
                            } label: {
                                Label("Reference: \(landmark.title)", systemImage: "ruler")
                            }.accessibilityIdentifier("ground-landmark-picker")
                            Picker("Reference", selection: Binding(get: { mode }, set: { changeMode($0) })) {
                                Text("2 points · local").tag(GroundCalibration.Mode.localScale)
                                Text("4 points · ground").tag(GroundCalibration.Mode.plane)
                            }.pickerStyle(.segmented).accessibilityIdentifier("ground-reference-mode")
                            Text(landmark == .custom ? (mode == .localScale ? "Tap two ground points with a known distance. Measurements are approximate near this reference; perspective is not corrected." : "Tap four corners of a real rectangle on the ground, clockwise. It can be any known marked area—you do not need the whole field.") : landmark.guidance)
                                .font(.subheadline).foregroundStyle(.secondary)
                            HStack {
                                dimension(mode == .plane ? "Side 1–2 (m)" : "Known distance (m)", value: $length)
                                if mode == .plane { dimension("Side 2–3 (m)", value: $width) }
                            }
                            if !request.isStill {
                                Toggle("Camera stays fixed", isOn: $fixedCamera)
                                Text(fixedCamera ? "Use only for an unmoving camera. Movement would invalidate measurements." : "Camera movement is processed once and shared by measurements and ground effects. Values are available from this reference onward, while camera tracking remains valid.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button { editingDimension = false; scanID += 1 } label: {
                                Label(scanning ? "Finding ground reference…" : "Find ground reference", systemImage: "viewfinder")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.bordered).disabled(image == nil || scanning)
                                .accessibilityIdentifier("ground-auto-reference")
                            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("ground-notice") }
                            if request.existing != nil {
                                Button("Remove calibration", role: .destructive) { apply(nil); dismiss() }
                                    .frame(minHeight: 44)
                            }
                        }.padding()
                    }.scrollDismissesKeyboard(.interactively)
                }
            }.background(Theme.ink)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editingDimension = false } }
                }
        }.preferredColorScheme(.dark).tint(Theme.signal)
            .task { await loadFrame() }
            .task(id: scanID) { if scanID > 0 { await findReference() } }
    }

    private func dimension(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number).keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder).focused($editingDimension).frame(minHeight: 44)
                .accessibilityIdentifier(title == "Side 2–3 (m)" ? "ground-width" : "ground-length")
        }
    }
    private func changeMode(_ value: GroundCalibration.Mode) {
        guard value != mode else { return }
        mode = value; landmark = .custom; points = []; notice = nil
    }
    private func chooseLandmark(_ value: GroundLandmark) {
        landmark = value
        mode = value.mode
        points = []
        length = value.defaultLengthMeters
        width = value.defaultWidthMeters
        notice = value == .custom ? nil : "Standard full-size football reference; confirm dimensions for this competition."
    }
    private func loadFrame() async {
        do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1920, height: 1920)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let result = try await generator.image(at: CMTime(seconds: request.sourceTime, preferredTimescale: 600))
            try Task.checkCancellation(); image = UIImage(cgImage: result.image)
        } catch is CancellationError {} catch { loadingFailed = true; notice = "Could not open this frame. Try another position." }
    }
    private func findReference() async {
        guard let source = image?.cgImage else { return }
        scanning = true; defer { scanning = false }
        do {
            let worker = Task.detached(priority: .userInitiated) { try GroundReferenceDetection.detect(in: source) }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); suggestions = result.intersections
            if result.corners.count == 4 {
                // A geometric rectangle is not a recognised penalty/goal area.
                // Never inherit a preset's metres for an unrelated detection.
                landmark = .custom; length = 0; width = 0
                mode = .plane; points = result.corners
                notice = "Suggested rectangle: confirm all four corners and enter its real dimensions. Detection alone cannot determine metres."
            } else {
                notice = "No complete ground rectangle found. Tap your reference points; visible marking intersections are highlighted to help."
            }
        } catch is CancellationError {} catch { notice = "Automatic reference unavailable. You can still set points manually." }
    }
}

private struct GroundPointCanvas: View {
    let image: UIImage
    @Binding var points: [CGPoint]
    let count: Int
    let suggestions: [CGPoint]
    @State private var viewport = FieldPlacementViewport()
    @State private var active = 0
    @State private var finger: CGPoint?
    @State private var navigationStart: FieldPlacementViewport?
    @State private var original: (points: [CGPoint], active: Int)?
    @State private var offset = CGSize.zero

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let fitted = AVMakeRect(aspectRatio: image.size, insideRect: bounds)
                let frame = viewport.frame(fitted: fitted)
                ZStack(alignment: .topLeading) {
                    Color(white: 0.08)
                    Image(uiImage: image).resizable().frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY).allowsHitTesting(false)
                    Canvas { context, _ in
                        func mapped(_ p: CGPoint) -> CGPoint { .init(x: frame.minX + p.x * frame.width, y: frame.minY + p.y * frame.height) }
                        for p in suggestions {
                            let p = mapped(p)
                            context.stroke(Path(ellipseIn: .init(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.cyan), lineWidth: 1)
                        }
                        let handles = points.map(mapped)
                        if let first = handles.first {
                            var path = Path(); path.move(to: first)
                            for p in handles.dropFirst() { path.addLine(to: p) }
                            if handles.count == 4 { path.closeSubpath(); context.fill(path, with: .color(Theme.signal.opacity(0.12))) }
                            context.stroke(path, with: .color(.black), lineWidth: 4)
                            context.stroke(path, with: .color(Theme.signal), lineWidth: 2)
                        }
                        for (i, p) in handles.enumerated() {
                            let circle = Path(ellipseIn: .init(x: p.x - 13, y: p.y - 13, width: 26, height: 26))
                            context.fill(circle, with: .color(i == active ? Theme.signal : .black))
                            context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                            context.draw(Text("\(i + 1)").font(.caption.bold()).foregroundStyle(i == active ? .black : .white), at: p)
                        }
                    }.allowsHitTesting(false)
                    FieldPlacementTouchSurface { handle($0, frame: frame, fitted: fitted) }
                }.clipped()
                    .overlay(alignment: .topTrailing) {
                        Button("Fit preview", systemImage: "arrow.down.right.and.arrow.up.left") { viewport = .init() }
                            .labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle()).padding(6).background(.black.opacity(0.7), in: .rect(cornerRadius: 10))
                    }
                    .overlay {
                        if let finger, points.indices.contains(active) {
                            GroundPointLoupe(image: image, point: points[active], magnification: max(1.5, frame.width / image.size.width * 2))
                                .frame(width: 112, height: 100)
                                .position(FieldPlacementViewport.loupeCenter(finger: finger, bounds: bounds, size: .init(width: 112, height: 100)))
                                .allowsHitTesting(false)
                        }
                    }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("ground-preview")
                .accessibilityValue("\(points.count) points")
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { i in
                    Button("\(i + 1)") { active = i }.frame(maxWidth: .infinity, minHeight: 44)
                        .background(active == i ? Theme.signal.opacity(0.25) : .white.opacity(0.06), in: .rect(cornerRadius: 8))
                        .disabled(i > points.count).accessibilityIdentifier("ground-point-\(i)")
                }
                Button("Clear points", systemImage: "arrow.counterclockwise") { points = []; active = 0 }
                    .labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle())
            }.padding(.horizontal, 8)
            Text(points.count < count ? "Tap point \(min(active + 1, count)) · pinch and pan with two fingers" : "Drag a point to refine · pinch and pan with two fingers")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
        }.onChange(of: count) { active = 0 }
            .onChange(of: points.isEmpty) { _, empty in
                if empty { active = 0; finger = nil; original = nil }
            }
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
        case .beginNavigation: navigationStart = viewport; finger = nil
        case .navigate(let scale, let from, let to):
            if let navigationStart { viewport = navigationStart.navigating(scale: scale, from: from, to: to, fitted: fitted) }
        case .endNavigation: navigationStart = nil
        }
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
