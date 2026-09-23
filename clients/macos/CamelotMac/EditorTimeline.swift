import AppKit
import SwiftUI

struct EditorTimeline: View {
    let videoURL: URL
    var clips: [EditorSequenceClip] = []
    var selectedClipID: UUID? = nil
    var selectClip: (UUID) -> Void = { _ in }
    var reorderClip: (UUID, Int) -> Void = { _, _ in }
    let playback: EditorPlayback
    let feedback: EditorTimelineFeedback
    var undo: (() -> Void)? = nil
    var redo: (() -> Void)? = nil
    var addVideo: (() -> Void)? = nil
    var addEvent: (() -> Void)? = nil
    var showsEvents = false
    var addClipAtStart: (() -> Void)? = nil
    @Binding var zoom: CGFloat
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let events: [TimelineEventSnapshot]
    let selectedEventID: TimelineEventID?
    let showsTrim: Bool
    let height: CGFloat
    var fit: (() -> Void)? = nil
    var fitLabel = "Fit clip"
    let previewSeek: (Double) -> Void
    let commitSeek: (Double) -> Void
    let beginTrimEdit: () -> Void
    let selectEvent: (TimelineEventID?) -> Void
    let updateEventWindow: (TimelineEventID, Double, Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorPlaybackControls(playback: playback, feedback: feedback, zoom: $zoom, undo: undo, redo: redo, showsHistory: !showsTrim, addEvent: addEvent, showsEvents: showsEvents, fit: fit, fitLabel: fitLabel)
            TimelineSurface(
                videoURL: videoURL, clips: clips, addClipAtStart: showsTrim ? nil : addClipAtStart, addClipAtEnd: showsTrim ? nil : addVideo, selectedClipID: selectedClipID, selectClip: selectClip, reorderClip: reorderClip, feedback: feedback, duration: playback.duration, currentSeconds: playback.currentSeconds,
                zoom: zoom, events: events, selectedEventID: showsTrim ? nil : selectedEventID,
                trimStart: trimStart, trimEnd: trimEnd, showsTrim: showsTrim,
                previewSeek: previewSeek, commitSeek: commitSeek, changeZoom: { zoom = $0 },
                beginTrimEdit: beginTrimEdit,
                updateTrim: { start, end in trimStart = start; trimEnd = end },
                selectEvent: selectEvent, updateEventWindow: updateEventWindow
            )
            .accessibilityIdentifier("editor-timeline")
        }
        .frame(height: height).background(Theme.inkTimeline)
    }

    private var maxZoom: CGFloat { max(1, CGFloat(playback.duration / 2)) }
}

extension TimelineEventSnapshot {
    init(_ event: MatchEvent) {
        self.init(id: TimelineEventID(eventID: event.id), offset: event.offsetSeconds, preRoll: event.preRollSeconds, postRoll: event.postRollSeconds, kind: event.kind, colorHex: event.colorHex)
    }
}

struct TimelineSurface: NSViewRepresentable {
    let videoURL: URL
    let clips: [EditorSequenceClip]
    var addClipAtStart: (() -> Void)? = nil
    var addClipAtEnd: (() -> Void)? = nil
    let selectedClipID: UUID?
    let selectClip: (UUID) -> Void
    var reorderClip: (UUID, Int) -> Void = { _, _ in }
    let feedback: EditorTimelineFeedback
    let duration: Double
    let currentSeconds: Double
    let zoom: CGFloat
    let events: [TimelineEventSnapshot]
    let selectedEventID: TimelineEventID?
    let trimStart: Double
    let trimEnd: Double
    let showsTrim: Bool
    let previewSeek: (Double) -> Void
    let commitSeek: (Double) -> Void
    let changeZoom: (CGFloat) -> Void
    let beginTrimEdit: () -> Void
    let updateTrim: (Double, Double) -> Void
    let selectEvent: (TimelineEventID?) -> Void
    let updateEventWindow: (TimelineEventID, Double, Double) -> Void

    func makeNSView(context: Context) -> TimelineViewport { TimelineViewport(configuration: self) }
    func updateNSView(_ view: TimelineViewport, context: Context) { view.update(self) }
    static func dismantleNSView(_ view: TimelineViewport, coordinator: ()) { view.stop() }
}

/// A single viewport-sized drawing surface with virtual content. Scrolling,
/// pinching and event-lane browsing are handled directly, so even a two-hour
/// recording keeps the same number of views.
final class TimelineViewport: NSView {
    var configuration: TimelineSurface
    private var centerTime: Double = 0
    private var workingZoom: CGFloat = 1
    private var verticalOffset: CGFloat = 0
    private var scrubbing = false
    private var scrubAnchor: (center: Double, x: CGFloat)?
    private var placedEvents: [TimelinePlacedEvent] = []
    private var pinching = false
    private var pinchZoom: CGFloat = 1
    private var pinchAnchor: Double = 0
    private var drag: (leading: Bool, start: Double, end: Double, grabOffset: CGFloat)?
    private var clipDrag: (id: UUID, destination: Int, originalTime: Double)?
    private var images: [Double: CGImage] = [:]
    private var thumbnailTask: Task<Void, Never>?
    private var requestedSamples: [Double] = []
    private var sampleInterval: Double = 1
    private var pendingSampleInterval: Double = 1
    private var lastSize: CGSize = .zero
    private var mouseDownPoint: CGPoint?
    private let thumbnailSize = CGSize(width: 160, height: 100)

    init(configuration: TimelineSurface) {
        self.configuration = configuration
        super.init(frame: .zero)
        centerTime = configuration.currentSeconds; workingZoom = configuration.zoom
        placedEvents = TimelinePlacedEvent.layout(configuration.events)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video timeline")
        setAccessibilityHelp("Scroll to scrub or browse overlapping event tracks. Pinch to zoom. Option-drag a clip to reorder it. Click empty space to deselect.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var geometry: TimelineGeometry { TimelineGeometry(duration: configuration.duration, width: bounds.width, zoom: workingZoom, contentInset: configuration.showsTrim ? bounds.width * 0.1 : max(52, bounds.width * 0.1)) }
    private var selectedEvent: TimelineEventSnapshot? { configuration.events.first { $0.id == configuration.selectedEventID } }
    private var selectedRange: (Double, Double)? {
        if let drag { return (drag.start, drag.end) }
        if configuration.showsTrim { return (configuration.trimStart, configuration.trimEnd) }
        if let event = selectedEvent { return (event.start, min(configuration.duration, event.end)) }
        return nil
    }
    private var filmBand: CGRect { CGRect(x: 0, y: 26, width: bounds.width, height: min(68, max(36, bounds.height * 0.26))) }
    private var eventsTop: CGFloat { filmBand.maxY + 8 }
    private func eventBand(row: Int) -> CGRect { CGRect(x: 0, y: eventsTop + CGFloat(row) * 36 - verticalOffset, width: bounds.width, height: 30) }
    private func eventBand(id: TimelineEventID?) -> CGRect { eventBand(row: placedEvents.first { $0.event.id == id }?.row ?? 0) }
    private func x(_ seconds: Double) -> CGFloat { geometry.x(seconds, center: centerTime) }

    func update(_ value: TimelineSurface) {
        let changedURL = configuration.clips != value.clips || (value.clips.isEmpty && configuration.videoURL != value.videoURL)
        let zoomChanged = abs(configuration.zoom - value.zoom) > 0.0001
        let selectionChanged = configuration.selectedEventID != value.selectedEventID
        if configuration.events != value.events {
            placedEvents = TimelinePlacedEvent.layout(value.events)
        }
        configuration = value
        if changedURL, clipDrag != nil { finishReorder(cancelled: true) }
        if changedURL { stop(); images.removeAll(); requestedSamples = [] }
        if !pinching, drag == nil, clipDrag == nil, zoomChanged || selectionChanged || changedURL || abs(centerTime - value.currentSeconds) < 2 {
            centerTime = geometry.clamp(value.currentSeconds)
        }
        workingZoom = value.zoom
        if selectionChanged, let id = value.selectedEventID,
           let placed = placedEvents.first(where: { $0.event.id == id }) {
            let laneHeight = max(36, bounds.height - eventsTop)
            verticalOffset = max(0, CGFloat(placed.row) * 36 - (laneHeight - 36) / 2)
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        refresh()
    }

    private func refresh() {
        needsDisplay = true
        if !pinching { loadVisibleThumbnails() }
    }

    // MARK: Interaction

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        let seconds = geometry.seconds(point.x, center: centerTime)
        if let range = selectedRange, configuration.showsTrim || selectedEvent?.isLocked != true {
            let band = configuration.showsTrim ? filmBand : eventBand(id: configuration.selectedEventID)
            if band.contains(point) {
                let leadingX = x(range.0), trailingX = x(range.1)
                if abs(point.x - leadingX) <= 16 || abs(point.x - trailingX) <= 16 {
                    let leading = abs(point.x - leadingX) <= abs(point.x - trailingX)
                    startDrag(leading: leading, range: range, x: point.x)
                    return
                }
            }
        }
        if event.modifierFlags.contains(.option), !configuration.showsTrim, configuration.clips.count > 1, filmBand.contains(point),
           let clip = configuration.clips.first(where: { seconds >= $0.segment.start && seconds < $0.segment.end }) {
            clipDrag = (clip.segment.id, clip.number - 1, centerTime)
            return
        }
        if point.y >= eventsTop,
           let placed = placedEvents.first(where: { eventBand(row: $0.row).contains(point) && seconds >= $0.event.start && seconds <= $0.event.end }) {
            selectTimelineEvent(placed.event.id)
            return
        }
        configuration.selectEvent(nil)
        centerTime = geometry.clamp(seconds)
        if let clip = configuration.clips.first(where: { seconds >= $0.segment.start && seconds < $0.segment.end }) {
            configuration.selectClip(clip.segment.id)
        }
        scrubbing = true
        scrubAnchor = (centerTime, point.x)
        configuration.previewSeek(centerTime)
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let draft = clipDrag {
            let seconds = geometry.seconds(point.x, center: centerTime)
            let remaining = configuration.clips.filter { $0.segment.id != draft.id }
            let destination = remaining.filter { seconds > ($0.segment.start + $0.segment.end) / 2 }.count
            clipDrag?.destination = destination
            refresh()
            return
        }
        if drag != nil { updateDrag(x: point.x); return }
        if let anchor = scrubAnchor {
            let delta = Double((point.x - anchor.x) / geometry.pointsPerSecond)
            centerTime = geometry.clamp(anchor.center - delta)
            configuration.previewSeek(centerTime)
            refresh()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let draft = clipDrag {
            clipDrag = nil
            centerTime = draft.originalTime
            configuration.reorderClip(draft.id, draft.destination)
            refresh(); return
        }
        if drag != nil { finishDrag(cancelled: false); return }
        if scrubbing { configuration.commitSeek(centerTime); scrubbing = false; scrubAnchor = nil; refresh() }
        mouseDownPoint = nil
    }

    /// Keep pointer events on the timeline even if a SwiftUI overlay is nearby.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            workingZoom = max(1, min(max(1, CGFloat(configuration.duration / 2)), workingZoom * (1 - event.scrollingDeltaY * 0.01)))
            configuration.changeZoom(workingZoom)
            refresh(); return
        }
        if event.modifierFlags.contains(.shift) {
            // Shift + wheel browses overlapping event lanes.
            let rows = (placedEvents.map(\.row).max() ?? -1) + 1
            let contentHeight = max(bounds.height, eventsTop + CGFloat(rows) * 36 + 8)
            verticalOffset = min(max(0, verticalOffset + event.scrollingDeltaY), max(0, contentHeight - bounds.height))
            refresh(); return
        }
        // A plain wheel scrubs the timeline horizontally, like an NLE.
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        centerTime = geometry.clamp(centerTime + Double(delta / geometry.pointsPerSecond))
        configuration.previewSeek(centerTime)
        refresh()
    }

    override func magnify(with event: NSEvent) {
        if event.phase.contains(.began) {
            pinching = true; pinchZoom = workingZoom; pinchAnchor = centerTime; scrubbing = false
            thumbnailTask?.cancel(); requestedSamples = []
            configuration.commitSeek(pinchAnchor)
        }
        workingZoom = max(1, min(max(1, CGFloat(configuration.duration / 2)), pinchZoom * (1 + event.magnification)))
        centerTime = pinchAnchor
        configuration.feedback.visibleSeconds = configuration.duration / Double(workingZoom)
        refresh()
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            centerTime = pinchAnchor
            configuration.changeZoom(workingZoom)
            pinching = false
            refresh()
        }
    }

    private func selectTimelineEvent(_ id: TimelineEventID) {
        guard let event = configuration.events.first(where: { $0.id == id }) else { return }
        let deselecting = configuration.selectedEventID == id
        configuration.selectEvent(deselecting ? nil : id)
        if !deselecting { centerTime = geometry.clamp(min(event.upperBound, max(event.lowerBound, event.offset))) }
        refresh(); configuration.commitSeek(centerTime)
    }

    private func startDrag(leading: Bool, range: (Double, Double), x pointX: CGFloat) {
        let edge = leading ? range.0 : range.1
        drag = (leading, range.0, range.1, pointX - x(edge))
        configuration.previewSeek(leading ? range.0 : range.1)
    }

    private func updateDrag(x pointX: CGFloat) {
        guard let drag else { return }
        applyEdge(geometry.seconds(pointX - drag.grabOffset, center: centerTime))
    }

    private func applyEdge(_ value: Double) {
        guard var draft = drag else { return }
        let seconds = (value * 10).rounded() / 10
        if configuration.showsTrim {
            (draft.start, draft.end) = TimelineGeometry.trim(seconds, start: draft.start, end: draft.end, duration: configuration.duration, leading: draft.leading)
        } else if let event = selectedEvent {
            (draft.start, draft.end) = event.resizing(seconds, start: draft.start, end: draft.end, leading: draft.leading, duration: configuration.duration)
        }
        drag = draft
        configuration.feedback.draft = EditorRangeDraft(eventID: configuration.showsTrim ? nil : configuration.selectedEventID, start: draft.start, end: draft.end)
        configuration.previewSeek(draft.leading ? draft.start : draft.end)
        refresh()
    }

    private func finishDrag(cancelled: Bool) {
        guard let draft = drag else { return }
        if !cancelled {
            if configuration.showsTrim {
                if draft.start != configuration.trimStart || draft.end != configuration.trimEnd {
                    configuration.beginTrimEdit()
                    configuration.updateTrim(draft.start, draft.end)
                }
            } else if let event = selectedEvent {
                configuration.updateEventWindow(event.id,
                    draft.leading ? event.offset - draft.start : event.preRoll,
                    draft.leading ? event.postRoll : draft.end - event.offset)
            }
        }
        drag = nil; configuration.feedback.draft = nil
        centerTime = geometry.clamp(draft.leading ? draft.start : draft.end)
        configuration.commitSeek(centerTime)
        refresh()
    }

    private func finishReorder(cancelled: Bool) {
        guard let draft = clipDrag else { return }
        clipDrag = nil
        centerTime = draft.originalTime
        refresh()
        if !cancelled { configuration.reorderClip(draft.id, draft.destination) }
    }

    private func loadVisibleThumbnails() {
        guard bounds.width > 0 else { return }
        let interval = max(0.25, pow(2, ceil(log2(Double(72 / geometry.pointsPerSecond)))))
        let left = geometry.seconds(-72, center: centerTime)
        let right = geometry.seconds(bounds.width + 72, center: centerTime)
        let ranges = configuration.clips.isEmpty ? [(0.0, configuration.duration)] : configuration.clips.map { ($0.segment.start, $0.segment.end) }
        let samples = ranges.flatMap { start, end -> [Double] in
            guard end >= left, start <= right else { return [] }
            let lower = max(0, Int(floor((left - start) / interval)))
            let upper = max(lower, Int(ceil((min(right, end) - start) / interval)))
            return (lower...upper).map { start + Double($0) * interval }.filter { $0 < end }
        }
        guard samples != requestedSamples || interval != pendingSampleInterval else { return }
        requestedSamples = samples; pendingSampleInterval = interval
        thumbnailTask?.cancel()
        let url = configuration.videoURL
        let clips = configuration.clips
        let size = thumbnailSize
        thumbnailTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            for seconds in samples {
                guard !Task.isCancelled else { return }
                let image: CGImage?
                if let cached = self?.images[seconds] { image = cached } else {
                    image = await VideoThumbnailService.shared.image(
                        url: clips.first(where: { seconds >= $0.segment.start && seconds < $0.segment.end })?.url ?? clips.last?.url ?? url,
                        seconds: clips.first(where: { seconds >= $0.segment.start && seconds < $0.segment.end })?.segment.sourceTime(at: seconds) ?? clips.last?.segment.sourceEnd ?? seconds,
                        size: size, tolerance: 0.25)
                }
                guard !Task.isCancelled, let self else { return }
                if let image { self.images[seconds] = image }
                if self.images.count > 48 {
                    let keep = Set(self.images.keys.sorted { abs($0 - self.centerTime) < abs($1 - self.centerTime) }.prefix(32))
                    self.images = self.images.filter { keep.contains($0.key) }
                }
                self.sampleInterval = interval
                self.needsDisplay = true
            }
        }
    }

    func stop() {
        thumbnailTask?.cancel(); thumbnailTask = nil
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext, geometry.duration > 0 else { return }
        let left = geometry.seconds(0, center: centerTime)
        let right = geometry.seconds(bounds.width, center: centerTime)
        let videoRect = CGRect(x: x(0), y: filmBand.minY, width: CGFloat(geometry.duration) * geometry.pointsPerSecond, height: filmBand.height)

        context.saveGState(); context.clip(to: videoRect.intersection(filmBand))
        let drawInterval = max(sampleInterval, geometry.tickInterval)
        let ranges = configuration.clips.isEmpty ? [(0.0, geometry.duration)] : configuration.clips.map { ($0.segment.start, $0.segment.end) }
        for (start, end) in ranges where end >= left && start <= right {
            let band = CGRect(x: max(-8, x(start)) + 1, y: filmBand.minY,
                width: max(1, min(bounds.width + 8, x(end)) - max(-8, x(start)) - 2), height: filmBand.height)
            context.saveGState()
            context.addPath(CGPath(roundedRect: band, cornerWidth: 6, cornerHeight: 6, transform: nil)); context.clip()
            context.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor); context.fill(band)
            let first = max(0, Int(floor((left - start) / drawInterval)))
            let last = max(first, Int(ceil((min(right, end) - start) / drawInterval)))
            if first <= last {
                for index in first...last {
                    let seconds = start + Double(index) * drawInterval
                    guard seconds < end else { continue }
                    let nearest = images.keys.filter { $0 >= start && $0 < end }.min { abs($0 - seconds) < abs($1 - seconds) }
                    guard let image = images[seconds] ?? nearest.flatMap({ images[$0] }) else { continue }
                    let cell = CGRect(x: x(seconds), y: filmBand.minY, width: CGFloat(min(drawInterval, end - seconds)) * geometry.pointsPerSecond, height: filmBand.height)
                    context.saveGState(); context.clip(to: cell)
                    let scale = max(cell.width / CGFloat(image.width), cell.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    context.draw(image, in: CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height))
                    context.restoreGState()
                }
            }
            context.restoreGState()
        }
        context.restoreGState()
        for clip in configuration.clips where clip.segment.end >= left && clip.segment.start <= right {
            let start = max(-8, x(clip.segment.start)); let end = min(bounds.width + 8, x(clip.segment.end))
            let band = CGRect(x: start + 1, y: filmBand.minY, width: max(1, end - start - 2), height: filmBand.height)
            context.saveGState(); context.addPath(CGPath(roundedRect: band, cornerWidth: 6, cornerHeight: 6, transform: nil)); context.clip()
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.fill(CGRect(x: band.minX, y: band.maxY - 21, width: band.width, height: 21))
            if band.width > 28 {
                let title = clip.segment.freezeDuration == nil ? "Clip \(clip.number)" : "Freeze"
                label("\(title) · \(timelineTimecode(clip.segment.duration, includesTenths: true))", at: CGPoint(x: max(5, band.minX + 6), y: band.maxY - 18), color: .white)
            }
            context.restoreGState()
            (configuration.selectedClipID == clip.segment.id ? NSColor(Theme.signal) : NSColor.white.withAlphaComponent(0.65)).setStroke()
            let outline = CGPath(roundedRect: band, cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.addPath(outline); context.setLineWidth(configuration.selectedClipID == clip.segment.id ? 2 : 1); context.strokePath()
        }
        let majorStep = geometry.tickInterval
        let minorStep = geometry.subdivisionInterval
        let divisions = max(1, Int((majorStep / minorStep).rounded()))
        let firstIndex = Int(ceil(left / minorStep))
        let lastIndex = max(firstIndex, Int(floor(right / minorStep)))
        if firstIndex <= lastIndex {
            for index in firstIndex...lastIndex {
                let time = Double(index) * minorStep
                guard time >= 0, time <= geometry.duration else { continue }
                let major = index % divisions == 0
                context.setFillColor(NSColor.white.withAlphaComponent(major ? 0.6 : 0.24).cgColor)
                context.fill(CGRect(x: x(time), y: major ? 16 : 20, width: 1, height: major ? 9 : 5))
                if major { label(timelineTimecode(time, includesTenths: majorStep < 1), at: CGPoint(x: x(time) + 4, y: 1), color: .lightGray) }
            }
        }
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: eventsTop, width: bounds.width, height: max(0, bounds.height - eventsTop)))
        for placed in placedEvents {
            let event = placed.event
            let band = eventBand(row: placed.row)
            guard band.maxY >= eventsTop, band.minY <= bounds.height else { continue }
            let selected = event.id == configuration.selectedEventID && !configuration.showsTrim
            let start = selected ? selectedRange?.0 ?? event.start : event.start
            let end = selected ? selectedRange?.1 ?? event.end : event.end
            guard end >= left, start <= right else { continue }
            let bar = CGRect(x: max(-12, x(start)), y: band.minY, width: max(8, min(bounds.width + 12, x(end)) - max(-12, x(start))), height: band.height)
            let tint = NSColor(EventColor.tint(hex: event.colorHex, kind: event.kind))
            tint.withAlphaComponent(selected ? 0.55 : 0.28).setFill()
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 6, cornerHeight: 6, transform: nil)); context.fillPath()
            if bar.width > 58 {
                label("\(event.kind) · \(timelineTimecode(end - start, includesTenths: true))", at: CGPoint(x: max(8, bar.minX + 10), y: band.minY + 7), color: .white)
            }
            (selected ? NSColor.white : tint.withAlphaComponent(0.7)).setStroke()
            context.addPath(CGPath(roundedRect: bar.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.setLineWidth(selected ? 2 : 1); context.strokePath()
        }
        context.restoreGState()
        if let range = selectedRange, configuration.showsTrim {
            let band = filmBand
            let start = max(-16, x(range.0)); let end = min(bounds.width + 16, x(range.1))
            context.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
            context.fill(CGRect(x: 0, y: band.minY, width: max(0, min(bounds.width, start)), height: band.height))
            context.fill(CGRect(x: max(0, end), y: band.minY, width: max(0, bounds.width - end), height: band.height))
        }
        context.setFillColor(NSColor(Theme.signal).cgColor)
        context.fill(CGRect(x: bounds.midX - 1, y: 16, width: 2, height: bounds.height - 18))
        let cap = CGMutablePath(); cap.move(to: CGPoint(x: bounds.midX - 4, y: 15)); cap.addLine(to: CGPoint(x: bounds.midX + 4, y: 15)); cap.addLine(to: CGPoint(x: bounds.midX, y: 21)); cap.closeSubpath()
        context.addPath(cap); context.fillPath()
    }

    private func label(_ text: String, at point: CGPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}

func timelineTimecode(_ seconds: Double, includesTenths: Bool) -> String {
    guard includesTenths else { return timecode(seconds) }
    let value = max(0, seconds.isFinite ? seconds : 0)
    let tenths = Int((value * 10).rounded())
    return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
}