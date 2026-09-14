@preconcurrency import AVFoundation
import SwiftUI

struct AnalysisFieldPlacementRequest: Identifiable {
    let id = UUID()
    let sourceTime: Double
    let annotationTime: Double
    var existing: AnalysisAnnotation? = nil
}

/// All placement edits stay local until Apply. Four points refer to the selected
/// visible rectangle, so a penalty area never needs distant pitch corners.
struct AnalysisFieldPlacementView: View {
    let url: URL
    let request: AnalysisFieldPlacementRequest
    let apply: (AnalysisFieldLayout, [CGPoint]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var layout: AnalysisFieldLayout
    @State private var points: [CGPoint]
    @State private var activePoint = 0
    @State private var image: UIImage?
    @State private var error: String?
    @State private var viewport = FieldPlacementViewport()
    @State private var navigationStart: FieldPlacementViewport?
    @State private var cornerStart: (points: [CGPoint], active: Int)?
    @State private var cornerOffset = CGSize.zero
    @State private var finger: CGPoint?

    init(url: URL, request: AnalysisFieldPlacementRequest, apply: @escaping (AnalysisFieldLayout, [CGPoint]) -> Void) {
        self.url = url; self.request = request; self.apply = apply
        _layout = State(initialValue: request.existing.map { $0.fieldLayout ?? .legacy } ?? .init())
        _points = State(initialValue: request.existing?.points(at: request.annotationTime) ?? [])
    }

    private var valid: Bool { AnalysisFieldGuide.projection(corners: points) != nil }
    private let names = ["Far left", "Far right", "Near right", "Near left"]
    private var activePosition: CGPoint? { points.indices.contains(activePoint) ? points[activePoint] : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Visible reference", selection: $layout.region) {
                    ForEach(AnalysisFieldLayout.Region.allCases) { region in Text(region.title).tag(region) }
                }.pickerStyle(.segmented).padding(.horizontal).accessibilityIdentifier("field-placement-region")
                HStack {
                    Text("Goal on").font(.caption).foregroundStyle(.secondary)
                    Picker("Goal on", selection: $layout.goalSide) {
                        Text("Left").tag(AnalysisFieldLayout.GoalSide.left)
                        Text("Right").tag(AnalysisFieldLayout.GoalSide.right)
                    }.pickerStyle(.segmented).frame(maxWidth: 180).disabled(layout.region == .fullPitch)
                        .accessibilityIdentifier("field-placement-goal-side")
                    Spacer(minLength: 0)
                    Button("Start over", systemImage: "arrow.counterclockwise") { points = []; activePoint = 0 }
                        .labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle()).accessibilityIdentifier("field-placement-reset")
                }.padding(.horizontal)
                Text(points.count < 4 ? "Place \(activePoint + 1) · \(names[activePoint].lowercased()) corner" : "Drag a corner to refine · two fingers to zoom or pan")
                    .font(.subheadline).accessibilityIdentifier("field-placement-instruction")
                preview
                HStack(spacing: 20) {
                    referenceDiagram.frame(maxWidth: .infinity).frame(height: 100)
                    if let image, let position = activePosition {
                        FieldPlacementLoupe(image: image, point: position).frame(width: 112, height: 100)
                    } else {
                        Text("Match the numbered corners in this diagram to the same markings in your video.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal)
                pointControls
                Text(points.count == 4 && !valid ? "The four points must form a non-crossing area. Select a number to correct it." : "Align only what you can see. This is a visual guide, not distance calibration.")
                    .font(.caption).foregroundStyle(points.count == 4 && !valid ? .orange : .secondary)
                    .padding(.horizontal).padding(.bottom, 8)
            }.background(Theme.ink)
                .navigationTitle("Place visible field").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("field-placement-cancel") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") { apply(layout, points); dismiss() }.disabled(!valid || image == nil)
                            .accessibilityIdentifier("field-placement-apply")
                    }
                }
        }.preferredColorScheme(.dark).tint(Theme.signal)
            .task { await loadFrame() }
            .onChange(of: layout.region) { points = []; activePoint = 0 }
    }

    private var preview: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let size = image?.size ?? CGSize(width: 16, height: 9)
            let fitted = AVMakeRect(aspectRatio: size, insideRect: bounds)
            let frame = viewport.frame(fitted: fitted)
            ZStack(alignment: .topLeading) {
                Color(white: 0.10)
                if let image {
                    Image(uiImage: image).resizable().frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading).allowsHitTesting(false)
                    placementOverlay(frame: frame).allowsHitTesting(false)
                    FieldPlacementTouchSurface { handleTouch($0, frame: frame, fitted: fitted) }
                } else if let error { Text(error).padding() }
                else { ProgressView("Loading frame…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.clipped()
                .overlay(alignment: .topTrailing) { zoomControls }
                .overlay {
                    if let image, let finger, let position = activePosition {
                        FieldPlacementLoupe(image: image, point: position,
                                            magnification: max(1.4, frame.width / image.size.width * 2))
                            .frame(width: 112, height: 100)
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(alignment: .topLeading) {
                                Text("\(activePoint + 1)").font(.caption.bold()).padding(5)
                                    .background(.black.opacity(0.75), in: .rect(cornerRadius: 6)).padding(5)
                            }
                            .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
                            .position(FieldPlacementViewport.loupeCenter(finger: finger, bounds: bounds, size: CGSize(width: 112, height: 100)))
                            .allowsHitTesting(false).accessibilityIdentifier("field-placement-floating-loupe")
                    }
                }
        }.frame(minHeight: 140).accessibilityElement(children: .contain).accessibilityIdentifier("field-placement-preview")
            .accessibilityValue("\(points.count) points; " + points.map { String(format: "%.4f,%.4f", Double($0.x), Double($0.y)) }.joined(separator: "; "))
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Text("\(Double(viewport.zoom).formatted(.number.precision(.fractionLength(0...2))))×").font(.caption.monospacedDigit())
                .accessibilityIdentifier("field-placement-viewport")
                .accessibilityValue(String(format: "zoom %.3f; center %.4f,%.4f", Double(viewport.zoom), Double(viewport.center.x), Double(viewport.center.y)))
            Button("Zoom out preview", systemImage: "minus.magnifyingglass") { viewport.zoom = max(0.25, viewport.zoom / 2) }
                .disabled(viewport.zoom <= 0.25).accessibilityIdentifier("field-placement-zoom-out")
            Button("Fit preview", systemImage: "arrow.down.right.and.arrow.up.left") { viewport = .init() }
                .accessibilityIdentifier("field-placement-fit")
        }.labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle()).padding(6).background(.black.opacity(0.7), in: .rect(cornerRadius: 12))
    }

    private func placementOverlay(frame: CGRect) -> some View {
        Canvas { context, _ in
            let handles = points.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
            var lines = context
            lines.clip(to: Path(frame))
            let path = Path(AnalysisFieldGuide.path(corners: handles, layout: layout))
            lines.stroke(path, with: .color(.black.opacity(0.8)), lineWidth: 3)
            lines.stroke(path, with: .color(Theme.signal), lineWidth: 1.2)
            for (index, handle) in handles.enumerated() { Self.drawNumber(index, at: handle, active: index == activePoint, in: &context) }
        }
    }

    private func handleTouch(_ action: FieldPlacementTouchState.Action, frame: CGRect, fitted: CGRect) {
        switch action {
        case .beginCorner(let location):
            cornerStart = (points, activePoint); cornerOffset = .zero
            if let nearest = points.enumerated().min(by: { distance($0.element, to: location, frame: frame) < distance($1.element, to: location, frame: frame) }),
               distance(nearest.element, to: location, frame: frame) <= 28 {
                activePoint = nearest.offset
                cornerOffset = CGSize(width: frame.minX + nearest.element.x * frame.width - location.x,
                                      height: frame.minY + nearest.element.y * frame.height - location.y)
            }
            moveCorner(location, frame: frame)
        case .moveCorner(let location): moveCorner(location, frame: frame)
        case .endCorner:
            if let start = cornerStart, points.count > start.points.count, points.count < 4 { activePoint = points.count }
            cornerStart = nil; finger = nil
        case .cancelCorner:
            if let start = cornerStart { points = start.points; activePoint = start.active }
            cornerStart = nil; finger = nil
        case .beginNavigation: navigationStart = viewport; finger = nil
        case .navigate(let scale, let from, let to):
            if let start = navigationStart { viewport = start.navigating(scale: scale, from: from, to: to, fitted: fitted) }
        case .endNavigation: navigationStart = nil
        }
    }

    private func moveCorner(_ location: CGPoint, frame: CGRect) {
        finger = location
        let target = CGPoint(x: location.x + cornerOffset.width, y: location.y + cornerOffset.height)
        setPoint(AnnotationViewport.sourcePoint(target, frame: frame, allowsOffscreen: true))
    }

    private var referenceDiagram: some View {
        Canvas { context, size in
            let rect = CGRect(x: 18, y: 18, width: size.width - 36, height: size.height - 36)
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            context.fill(Path(rect), with: .color(.green.opacity(0.2)))
            context.stroke(Path(AnalysisFieldGuide.path(corners: corners, layout: layout)), with: .color(.white.opacity(0.7)), lineWidth: 1)
            for (index, point) in corners.enumerated() { Self.drawNumber(index, at: point, active: index == activePoint, in: &context) }
        }.accessibilityLabel("Reference diagram, corners 1 to 4 clockwise from far left")
    }

    private var pointControls: some View {
        VStack(spacing: 6) {
            HStack {
                ForEach(0..<4) { index in
                    Button { activePoint = index } label: {
                        Text("\(index + 1)").frame(maxWidth: .infinity).frame(height: 44)
                        .foregroundStyle(activePoint == index ? .black : Theme.signal)
                        .background(activePoint == index ? Theme.signal : .white.opacity(0.08), in: .rect(cornerRadius: 10))
                        .contentShape(.rect)
                    }.buttonStyle(.plain)
                        .disabled(index > points.count).accessibilityLabel("Point \(index + 1), \(names[index])")
                        .accessibilityIdentifier("field-placement-point-\(index)")
                }
            }
            HStack {
                Text("Fine tune").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                nudge("Left", symbol: "arrow.left", x: -1, y: 0)
                nudge("Up", symbol: "arrow.up", x: 0, y: -1)
                nudge("Down", symbol: "arrow.down", x: 0, y: 1)
                nudge("Right", symbol: "arrow.right", x: 1, y: 0)
            }.disabled(activePosition == nil || image == nil)
        }.padding(.horizontal)
    }

    private func nudge(_ title: String, symbol: String, x: CGFloat, y: CGFloat) -> some View {
        Button(title, systemImage: symbol) {
            guard let point = activePosition, let image else { return }
            setPoint(CGPoint(x: point.x + x / image.size.width, y: point.y + y / image.size.height))
        }.labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle())
            .accessibilityIdentifier("field-placement-nudge-\(title.lowercased())")
    }

    private func setPoint(_ point: CGPoint) {
        if points.indices.contains(activePoint) { points[activePoint] = point }
        else if activePoint == points.count, points.count < 4 { points.append(point) }
    }
    private func distance(_ point: CGPoint, to location: CGPoint, frame: CGRect) -> CGFloat {
        hypot(frame.minX + point.x * frame.width - location.x, frame.minY + point.y * frame.height - location.y)
    }
    private static func drawNumber(_ index: Int, at point: CGPoint, active: Bool, in context: inout GraphicsContext) {
        let circle = Path(ellipseIn: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))
        context.fill(circle, with: .color(active ? Theme.signal : .black))
        context.stroke(circle, with: .color(active ? .black : .white), lineWidth: 2)
        context.draw(Text("\(index + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(active ? .black : .white), at: point)
    }
    private func loadFrame() async {
        do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1920)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: request.sourceTime, preferredTimescale: 600)).image
            try Task.checkCancellation(); image = UIImage(cgImage: frame)
        } catch is CancellationError { }
        catch { self.error = "Could not load this frame. Close placement and try another position." }
    }
}

private struct FieldPlacementLoupe: View {
    let image: UIImage
    let point: CGPoint
    var magnification: CGFloat = 1.4
    var body: some View {
        GeometryReader { geometry in
            let scale = magnification
            Color(white: 0.1).overlay(alignment: .topLeading) {
                Image(uiImage: image).resizable().frame(width: image.size.width * scale, height: image.size.height * scale)
                    .offset(x: geometry.size.width / 2 - point.x * image.size.width * scale,
                            y: geometry.size.height / 2 - point.y * image.size.height * scale)
            }.clipped()
                .overlay {
                    Image(systemName: "plus").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(Theme.signal)
                }.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.signal, lineWidth: 1) }
        }.allowsHitTesting(false).accessibilityLabel("Magnified view of selected point")
    }
}
