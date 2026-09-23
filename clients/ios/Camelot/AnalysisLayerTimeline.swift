import SwiftUI

struct AnalysisTimelineViewport {
    static func visibleStart(time: Double, bounds: ClosedRange<Double>, span: Double) -> Double {
        let duration = max(0, bounds.upperBound - bounds.lowerBound)
        let visibleSpan = min(duration, max(0, span))
        let latestStart = max(bounds.lowerBound, bounds.upperBound - visibleSpan)
        return min(latestStart, max(bounds.lowerBound, time - visibleSpan / 2))
    }
}


/// One shared time axis, with a separate track for every
/// drawing. The horizontal viewport belongs to the whole stack, never each row.
struct AnalysisLayerTimeline: View {
    let annotations: [AnalysisAnnotation]
    let bounds: ClosedRange<Double>
    let time: Double
    let selectedID: UUID?
    let selectedKeyframe: UUID?
    let select: (UUID, Double?) -> Void
    let seek: (Double) -> Void
    let previewSeek: (Double) -> Void
    let beginEdit: () -> Void
    let edit: (AnalysisAnnotation, Bool) -> Void
    let selectKeyframe: (UUID, UUID, Double) -> Void
    let toggleHidden: (UUID) -> Void
    let toggleLocked: (UUID) -> Void
    let reorder: (UUID, Int) -> Void
    var videoURL: URL? = nil
    var freezeTime: Double? = nil
    var undo: (() -> Void)? = nil
    var redo: (() -> Void)? = nil
    @Binding var zoom: CGFloat
    @State private var panStart: Double?
    @State private var pinchStart: Double?
    @GestureState private var isMagnifying = false
    @State private var rulerStart: Double?
    @State private var rowDragging = false
    private let edgeInset: CGFloat = 24

    private var rows: [AnalysisAnnotation] { Array(annotations.reversed()) }
    private var span: Double { (bounds.upperBound - bounds.lowerBound) / zoom }
    // Keep the playhead at the viewport center. The half-span padding lets the
    // beginning and end of the clip reach that center as well.
    private var visibleStart: Double { time - span / 2 }
    private var maxZoom: Double { max(64, bounds.upperBound - bounds.lowerBound) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                Text("\(Double(zoom).formatted(.number.precision(.fractionLength(1))))×").font(.caption2.monospacedDigit())
                    .accessibilityIdentifier("analysis-timeline-scale")
                Button("Zoom out timeline", systemImage: "minus.magnifyingglass") { setZoom(zoom / 2) }.disabled(zoom <= 1).accessibilityIdentifier("analysis-timeline-zoom-out")
                Button("Fit timeline", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { setZoom(1) }
                    .accessibilityIdentifier("analysis-timeline-fit")
                Button("Zoom in timeline", systemImage: "plus.magnifyingglass") { setZoom(zoom * 2) }.disabled(zoom >= maxZoom).accessibilityIdentifier("analysis-timeline-zoom-in")
            }.labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle()).padding(.horizontal, 8).padding(.vertical, 4)
            GeometryReader { geometry in
                let viewport = max(64, geometry.size.width - edgeInset * 2)
                let scale = viewport / max(0.01, span)
                ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ruler(width: viewport, scale: scale)
                            ForEach(rows) { mark in
                                AnalysisLayerTrack(mark: mark, bounds: bounds, visibleStart: visibleStart, scale: scale, selected: mark.id == selectedID,
                                                   selectedKeyframe: selectedKeyframe, gestureDisabled: isMagnifying, select: select,
                                                   beginEdit: beginEdit, edit: edit, selectKeyframe: selectKeyframe,
                                                   dragging: { rowDragging = $0 },
                                                   pan: { delta, finished in panTimeline(delta / scale, finished: finished) })
                                    .frame(height: 48)
                                    .contextMenu {
                                        Button(mark.isHidden == true ? "Show layer" : "Hide layer", systemImage: "eye") { toggleHidden(mark.id) }
                                        Button(mark.isLocked == true ? "Unlock layer" : "Lock layer", systemImage: "lock") { toggleLocked(mark.id) }
                                        Button("Bring forward", systemImage: "arrow.up") { reorder(mark.id, 1) }
                                        Button("Send backward", systemImage: "arrow.down") { reorder(mark.id, -1) }
                                    }
                            }
                            Color.clear.frame(height: max(44, geometry.size.height - 30 - CGFloat(rows.count * 48)))
                                .contentShape(.rect)
                                .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                                    guard !isMagnifying, abs(value.translation.width) > abs(value.translation.height) else { return }
                                    panTimeline(value.translation.width / scale, finished: false)
                                }.onEnded { value in
                                    if panStart != nil { panTimeline(value.translation.width / scale, finished: true) }
                                })
                                .accessibilityIdentifier("analysis-timeline-pan-area")
                        }.frame(width: viewport).frame(minHeight: geometry.size.height, alignment: .top).contentShape(.rect)
                            .overlay(alignment: .topLeading) {
                                    Rectangle().fill(Theme.signal).frame(width: 1.5)
                                    .frame(width: 22)
                                    .offset(x: viewport / 2 - 11)
                                    .allowsHitTesting(false)
                                    .accessibilityLabel("Playhead").accessibilityIdentifier("analysis-playhead")
                            }
                            .clipped()
                            .padding(.horizontal, edgeInset)
                }.scrollDisabled(rowDragging || panStart != nil || rulerStart != nil)
            }
        }.background(Theme.inkTimeline)
            .coordinateSpace(name: "analysis-timeline")
            .simultaneousGesture(pinchGesture)
            .accessibilityElement(children: .contain).accessibilityIdentifier("analysis-layer-timeline")
            .accessibilityValue(String(format: "Visible %.2f to %.2f seconds", visibleStart - bounds.lowerBound, visibleStart + span - bounds.lowerBound))
            .onChange(of: isMagnifying) {
                if isMagnifying { panStart = nil; rulerStart = nil }
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .updating($isMagnifying) { _, active, _ in active = true }
            .onChanged { value in
                // Magnification is cumulative: keep one baseline for the gesture.
                if pinchStart == nil { pinchStart = Double(zoom) }
                guard let initial = pinchStart else { return }
                zoom = min(maxZoom, max(1, initial * value.magnification))
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func setZoom(_ value: Double) {
        pinchStart = nil
        zoom = min(maxZoom, max(1, value))
    }

    private func panTimeline(_ delta: Double, finished: Bool) {
        if panStart == nil { panStart = time }
        guard let initial = panStart else { return }
        let next = min(bounds.upperBound, max(bounds.lowerBound, initial - delta))
        previewSeek(next)
        if finished {
            seek(next)
            panStart = nil
        }
    }

    private func ruler(width: CGFloat, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let desired = 64 / scale
                let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
                let step = steps.first { $0 >= desired } ?? max(3600, desired)
                let first = ceil((visibleStart - bounds.lowerBound) / step) * step
                let count = min(512, Int(span / step) + 1)
                for index in 0..<count {
                    let seconds = first + Double(index) * step
                    guard seconds >= 0, seconds <= bounds.upperBound - bounds.lowerBound else { continue }
                    let x = (seconds + bounds.lowerBound - visibleStart) * scale
                    context.draw(Text(timelineTimecode(seconds, includesTenths: step < 1)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.gray), at: CGPoint(x: x + 4, y: 8), anchor: .topLeading)
                    var tick = Path(); tick.move(to: CGPoint(x: x, y: 23)); tick.addLine(to: CGPoint(x: x, y: 30))
                    context.stroke(tick, with: .color(.white.opacity(0.2)), lineWidth: 1)
                }
            }
        }.frame(width: width, height: 30).contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !isMagnifying else { return }
                if rulerStart == nil { rulerStart = time }
                if abs(value.translation.width) > 3 {
                    // The ruler is content: moving it left advances time.
                    let next = (rulerStart ?? time) - value.translation.width / scale
                    previewSeek(min(bounds.upperBound, max(bounds.lowerBound, next)))
                }
            }.onEnded { value in
                defer { rulerStart = nil }
                guard !isMagnifying else { return }
                let next: Double
                if abs(value.translation.width) > 3 {
                    next = (rulerStart ?? time) - value.translation.width / scale
                } else {
                    next = (rulerStart ?? time) + (value.startLocation.x - width / 2) / scale
                }
                seek(min(bounds.upperBound, max(bounds.lowerBound, next)))
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Analysis time ruler").accessibilityIdentifier("analysis-time-ruler")
            .accessibilityValue(String(format: "%.3f seconds", time - bounds.lowerBound))
            .accessibilityAdjustableAction { direction in
                seek(min(bounds.upperBound, max(bounds.lowerBound, time + (direction == .increment ? 1 / 30 : -1 / 30))))
            }
    }
}

struct AnalysisLayerTrack: View {
    let mark: AnalysisAnnotation
    let bounds: ClosedRange<Double>
    let visibleStart: Double
    let scale: CGFloat
    let selected: Bool
    let selectedKeyframe: UUID?
    let gestureDisabled: Bool
    let select: (UUID, Double?) -> Void
    let beginEdit: () -> Void
    let edit: (AnalysisAnnotation, Bool) -> Void
    let selectKeyframe: (UUID, UUID, Double) -> Void
    let dragging: (Bool) -> Void
    let pan: (Double, Bool) -> Void
    @State private var original: AnalysisAnnotation?
    @State private var dragTarget: DragTarget?
    @State private var dragScale: CGFloat?

    private enum DragTarget { case layer, start, end, keyframe(UUID), pan }

    private var tint: Color { Color(red: mark.color.red, green: mark.color.green, blue: mark.color.blue) }
    private var frames: [AnnotationKeyframe] {
        mark.keyframes.filter { $0.time >= max(mark.start, bounds.lowerBound) && $0.time <= min(mark.end, bounds.upperBound) }
    }

    var body: some View {
        let clippedStart = max(bounds.lowerBound, min(bounds.upperBound, mark.start))
        let clippedEnd = max(clippedStart, min(bounds.upperBound, mark.end))
        let x = (clippedStart - visibleStart) * scale
        let width = max(3, (clippedEnd - clippedStart) * scale)
        // The row owns layout. A zoomed bar can be wider than the viewport;
        // keeping it in an overlay prevents it from shifting the row's origin.
        Color.white.opacity(selected ? 0.055 : 0.018)
            .onTapGesture { location in select(mark.id, visibleStart + location.x / scale) }
            .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(tint.opacity(mark.isHidden == true ? 0.10 : selected ? 0.36 : 0.18))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(selected ? 1 : 0.4), lineWidth: selected ? 1.5 : 1) }
                .overlay(alignment: .topLeading) {
                    Text(mark.motionMode == .camera ? "CAMERA" : mark.motionMode == .player ? (mark.linkedPlayers != nil ? "LINKED" : "FOLLOW") : mark.motionMode == .keyframes ? "KEYFRAMES" : mark.title)
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(tint).lineLimit(1).padding(.horizontal, 10).padding(.top, 3)
                }
                .frame(width: width, height: 36).offset(x: x)
                .contentShape(.rect)
                .onTapGesture { select(mark.id, nil) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(mark.title) timing").accessibilityValue("\(mark.start - bounds.lowerBound) to \(mark.end - bounds.lowerBound) seconds")
                .accessibilityIdentifier("analysis-layer-bar-\(mark.id)")
            if mark.motionMode == .player || mark.motionMode == .camera {
                Canvas { context, size in
                    let start = max(clippedStart, min(clippedEnd, mark.trackedSpan?.lowerBound ?? clippedStart))
                    let end = max(start, min(clippedEnd, mark.trackedSpan?.upperBound ?? clippedStart))
                    let rect = CGRect(x: (start - visibleStart) * scale, y: 32, width: max(0, (end - start) * scale), height: 3)
                    context.fill(Path(rect), with: .color(.cyan))
                    if start > clippedStart + 0.05 {
                        context.fill(Path(CGRect(x: (clippedStart - visibleStart) * scale, y: 32, width: (start - clippedStart) * scale, height: 3)), with: .color(.orange))
                    }
                    if end < clippedEnd - 0.12 {
                        context.fill(Path(CGRect(x: (end - visibleStart) * scale, y: 32, width: (clippedEnd - end) * scale, height: 3)), with: .color(.orange))
                    }
                    for gap in mark.trackingGaps {
                        let lower = max(clippedStart, gap.lowerBound), upper = min(clippedEnd, gap.upperBound)
                        if upper > lower {
                            context.fill(Path(CGRect(x: (lower - visibleStart) * scale, y: 32, width: (upper - lower) * scale, height: 3)), with: .color(.orange))
                        }
                    }
                }.allowsHitTesting(false)
            }
            ForEach(frames) { frame in
                Image(systemName: "diamond.fill")
                    .font(.system(size: frame.id == selectedKeyframe ? 13 : 10))
                    .foregroundStyle(frame.id == selectedKeyframe ? .white : tint)
                    .frame(width: 24, height: 26).contentShape(.rect)
                    .offset(x: (frame.time - visibleStart) * scale - 12, y: 8)
                    .onTapGesture { selectKeyframe(mark.id, frame.id, frame.time) }
                    .accessibilityLabel("Keyframe at \(timelineTimecode(frame.time - bounds.lowerBound, includesTenths: true))")
                    .accessibilityValue(frame.time.formatted(.number.precision(.fractionLength(3))))
                    .accessibilityIdentifier("analysis-keyframe-\(frame.id)")
            }
            if selected && mark.isLocked != true {
                handle(leading: true).offset(x: x - 22)
                handle(leading: false).offset(x: x + width - 22)
            }
            }
        }.contentShape(.rect)
            .simultaneousGesture(timelineDrag)
            .onChange(of: gestureDisabled) {
                if gestureDisabled {
                    if let original { edit(original, false) }
                    original = nil; dragTarget = nil; dragScale = nil; dragging(false)
                }
            }
            .overlay(alignment: .bottom) { Color.white.opacity(0.07).frame(height: 1) }
    }

    private func handle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 12, height: 38)
            .overlay { Capsule().fill(.black.opacity(0.7)).frame(width: 2, height: 16) }
            .frame(width: 44, height: 44).contentShape(.rect)
            .accessibilityLabel(leading ? "Layer start" : "Layer end")
            .accessibilityValue(timelineTimecode((leading ? mark.start : mark.end) - bounds.lowerBound, includesTenths: true))
            .accessibilityAdjustableAction { direction in
                beginEdit()
                let delta = direction == .increment ? 0.1 : -0.1
                edit(mark.applying(leading ? .trimStart(mark.start + delta) : .trimEnd(mark.end + delta), within: bounds), true)
            }
            .accessibilityIdentifier(leading ? "analysis-layer-start" : "analysis-layer-end")
    }

    // Resolve the target once from the row coordinates. Separate gestures on
    // moving/overlapping SwiftUI shapes can hand a drag to the wrong element.
    private var timelineDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !gestureDisabled else { return }
                if dragTarget == nil {
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    original = mark
                    dragScale = scale; dragging(true)
                    dragTarget = target(at: value.startLocation)
                    if case .keyframe(let id) = dragTarget, let frame = mark.keyframes.first(where: { $0.id == id }) {
                        selectKeyframe(mark.id, id, frame.time)
                    }
                    if case .pan = dragTarget {} else { beginEdit() }
                }
                updateDrag(delta: value.translation.width / (dragScale ?? scale), finished: false)
            }
            .onEnded { value in
                if !gestureDisabled { updateDrag(delta: value.translation.width / (dragScale ?? scale), finished: true) }
                original = nil; dragTarget = nil; dragScale = nil; dragging(false)
            }
    }

    private func target(at point: CGPoint) -> DragTarget {
        guard selected, mark.isLocked != true else { return .pan }
        let startTime = max(bounds.lowerBound, min(bounds.upperBound, mark.start))
        let endTime = max(startTime, min(bounds.upperBound, mark.end))
        let start = (startTime - visibleStart) * scale, end = (endTime - visibleStart) * scale
        if point.y >= 24, let frame = frames.min(by: { abs(($0.time - visibleStart) * scale - point.x) < abs(($1.time - visibleStart) * scale - point.x) }),
           abs((frame.time - visibleStart) * scale - point.x) <= 14 { return .keyframe(frame.id) }
        if min(abs(point.x - start), abs(point.x - end)) <= 22 {
            return abs(point.x - start) <= abs(point.x - end) ? .start : .end
        }
        return point.x >= start && point.x <= end ? .layer : .pan
    }

    private func updateDrag(delta: Double, finished: Bool) {
        guard let original, let dragTarget else { return }
        let operation: AnnotationTimelineEdit
        switch dragTarget {
        case .pan: pan(delta * scale, finished); return
        case .layer: operation = .move(delta)
        case .start: operation = .trimStart(original.start + delta)
        case .end: operation = .trimEnd(original.end + delta)
        case .keyframe(let id):
            guard let frame = original.keyframes.first(where: { $0.id == id }) else { return }
            operation = .keyframe(id, frame.time + delta)
        }
        edit(original.applying(operation, within: bounds), finished)
    }
}
