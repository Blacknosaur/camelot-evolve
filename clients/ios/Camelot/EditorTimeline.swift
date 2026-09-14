import SwiftUI
import UIKit

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

struct TimelineSurface: UIViewRepresentable {
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

    func makeUIView(context: Context) -> TimelineViewport { TimelineViewport(configuration: self) }
    func updateUIView(_ view: TimelineViewport, context: Context) { view.update(self) }
    static func dismantleUIView(_ view: TimelineViewport, coordinator: ()) { view.stop() }
}

/// A native inertial scroll view drives a single viewport-sized drawing surface.
/// Its content is virtual: even a two-hour recording has the same number of UIViews.
final class TimelineViewport: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var configuration: TimelineSurface
    private let scroll = UIScrollView()
    private let canvas = TimelineCanvas()
    private let leadingHandle = TimelineHandle(leading: true)
    private let trailingHandle = TimelineHandle(leading: false)
    private var centerTime: Double = 0
    private var workingZoom: CGFloat = 1
    private var scrubbing = false
    private var placedEvents: [TimelinePlacedEvent] = []
    private var accessibleEvents: [TimelineEventID: TimelineEventAccessibilityElement] = [:]
    private var programmatic = false
    private var pinching = false
    private var pinchZoom: CGFloat = 1
    private var pinchAnchor: Double = 0
    private var drag: (leading: Bool, start: Double, end: Double, grabOffset: CGFloat)?
    private var clipDrag: (id: UUID, destination: Int, originalTime: Double)?
    private var activeReorder: UILongPressGestureRecognizer?
    private let dragPreview = UILabel()
    private let addBefore = UIButton(type: .system)
    private let addAfter = UIButton(type: .system)
    private var activePan: UIPanGestureRecognizer?
    private var displayLink: CADisplayLink?
    private var lastSize: CGSize = .zero
    private var images: [Double: UIImage] = [:]
    private var thumbnailTask: Task<Void, Never>?
    private var requestedSamples: [Double] = []
    private var sampleInterval: Double = 1
    private var pendingSampleInterval: Double = 1
    private let thumbnailSize = CGSize(width: 160, height: 100)

    init(configuration: TimelineSurface) {
        self.configuration = configuration
        super.init(frame: .zero)
        centerTime = configuration.currentSeconds; workingZoom = configuration.zoom
        placedEvents = TimelinePlacedEvent.layout(configuration.events)
        canvas.placedEvents = placedEvents
        clipsToBounds = true
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.bounces = false
        scroll.isDirectionalLockEnabled = true
        scroll.showsVerticalScrollIndicator = true
        scroll.panGestureRecognizer.maximumNumberOfTouches = 1
        addSubview(scroll)
        canvas.isUserInteractionEnabled = false
        canvas.backgroundColor = .clear
        addSubview(canvas)
        for handle in [leadingHandle, trailingHandle] {
            addSubview(handle)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(trimmed(_:)))
            handle.addGestureRecognizer(pan)
            handle.adjust = { [weak self, weak handle] delta in
                guard let self, let handle, let range = self.selectedRange else { return }
                self.startDrag(leading: handle.leading, range: range, grabOffset: 0)
                self.applyEdge((handle.leading ? range.0 : range.1) + delta)
                self.finishDrag(cancelled: false)
            }
        }
        for (button, leading) in [(addBefore, true), (addAfter, false)] {
            button.setImage(UIImage(systemName: "plus"), for: .normal)
            button.tintColor = .white
            button.backgroundColor = UIColor.white.withAlphaComponent(0.09)
            button.layer.cornerRadius = 6
            button.accessibilityLabel = leading ? "Add clip at start" : "Add clip at end"
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if leading { self.configuration.addClipAtStart?() }
                else { self.configuration.addClipAtEnd?() }
            }, for: .touchUpInside)
            addSubview(button)
        }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        scroll.addGestureRecognizer(pinch)
        let reorder = UILongPressGestureRecognizer(target: self, action: #selector(reordered(_:)))
        reorder.minimumPressDuration = 0.35
        reorder.delegate = self
        scroll.addGestureRecognizer(reorder)
        scroll.panGestureRecognizer.require(toFail: reorder)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: reorder)
        scroll.addGestureRecognizer(tap)
        dragPreview.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        dragPreview.textAlignment = .center
        dragPreview.textColor = .black
        dragPreview.backgroundColor = UIColor(Theme.signal)
        dragPreview.layer.cornerRadius = 6; dragPreview.clipsToBounds = true
        dragPreview.accessibilityIdentifier = "timeline-reorder-label"
        dragPreview.isHidden = true; dragPreview.isUserInteractionEnabled = false
        addSubview(dragPreview)
        scroll.isAccessibilityElement = true
        scroll.accessibilityLabel = "Video timeline"
        scroll.accessibilityHint = "Swipe sideways to scrub or vertically to browse overlapping event tracks. Pinch to zoom. Hold a clip and drag to reorder it. Tap empty space to deselect."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var geometry: TimelineGeometry { TimelineGeometry(duration: configuration.duration, width: bounds.width, zoom: workingZoom, contentInset: configuration.showsTrim ? bounds.width * 0.1 : max(52, bounds.width * 0.1)) }
    private var interacting: Bool { pinching || drag != nil || clipDrag != nil || scroll.isDragging || scroll.isDecelerating }
    private var selectedEvent: TimelineEventSnapshot? { configuration.events.first { $0.id == configuration.selectedEventID } }
    private var selectedRange: (Double, Double)? {
        if let drag { return (drag.start, drag.end) }
        if configuration.showsTrim { return (configuration.trimStart, configuration.trimEnd) }
        if let event = selectedEvent { return (event.start, min(configuration.duration, event.end)) }
        return nil
    }

    func update(_ value: TimelineSurface) {
        let changedURL = configuration.clips != value.clips || (value.clips.isEmpty && configuration.videoURL != value.videoURL)
        let zoomChanged = abs(configuration.zoom - value.zoom) > 0.0001
        let selectionChanged = configuration.selectedEventID != value.selectedEventID
        if configuration.events != value.events {
            placedEvents = TimelinePlacedEvent.layout(value.events)
            canvas.placedEvents = placedEvents
        }
        configuration = value
        if changedURL, clipDrag != nil { finishReorder(cancelled: true) }
        if changedURL { stop(); images.removeAll(); requestedSamples = [] }
        // A button or list selection must take effect even while a previous fling decelerates.
        let explicitChange = zoomChanged || selectionChanged || changedURL
        if explicitChange, !pinching, drag == nil {
            programmatic = true
            scroll.setContentOffset(scroll.contentOffset, animated: false)
            programmatic = false
        }
        guard !pinching, drag == nil, clipDrag == nil, !interacting || explicitChange else { return }
        centerTime = geometry.clamp(value.currentSeconds)
        workingZoom = value.zoom
        updateScrollGeometry()
        if selectionChanged, let id = value.selectedEventID,
           let placed = placedEvents.first(where: { $0.event.id == id }) {
            let laneHeight = max(36, canvas.bounds.height - canvas.eventsTop)
            let y = max(0, CGFloat(placed.row) * 36 - (laneHeight - 36) / 2)
            programmatic = true
            scroll.contentOffset.y = min(max(0, scroll.contentSize.height - scroll.bounds.height), y)
            programmatic = false
        }
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        programmatic = true
        scroll.frame = bounds; canvas.frame = bounds
        programmatic = false
        updateScrollGeometry(); refresh()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let button = [addBefore, addAfter].first(where: { !$0.isHidden && $0.frame.contains(point) }) { return button }
        let handles = [leadingHandle, trailingHandle].filter { !$0.isHidden && $0.frame.contains(point) }
        if let nearest = handles.min(by: { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }) {
            return nearest
        }
        return super.hitTest(point, with: event)
    }

    private func updateScrollGeometry() {
        programmatic = true
        let rows = (placedEvents.map(\.row).max() ?? -1) + 1
        let contentHeight = max(bounds.height, canvas.eventsTop + CGFloat(rows) * 36 + 8)
        scroll.contentSize = CGSize(width: CGFloat(configuration.duration) * geometry.pointsPerSecond + bounds.width, height: contentHeight)
        scroll.contentOffset = CGPoint(x: CGFloat(centerTime) * geometry.pointsPerSecond, y: min(scroll.contentOffset.y, max(0, contentHeight - bounds.height)))
        programmatic = false
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { scrubbing = false }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !programmatic, !pinching, drag == nil, clipDrag == nil else { return }
        let next = geometry.clamp(Double(scrollView.contentOffset.x / geometry.pointsPerSecond))
        if abs(next - centerTime) > 0.001 { scrubbing = true; centerTime = next; configuration.previewSeek(centerTime) }
        refresh()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate, scrubbing { configuration.commitSeek(centerTime); scrubbing = false }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { if scrubbing { configuration.commitSeek(centerTime); scrubbing = false } }

    private func refresh() {
        guard bounds.width > 0 else { return }
        canvas.geometry = geometry; canvas.centerSeconds = centerTime
        canvas.clips = configuration.clips; canvas.selectedClipID = configuration.selectedClipID
        canvas.events = configuration.events
        canvas.verticalOffset = scroll.contentOffset.y
        canvas.selectedID = configuration.selectedEventID
        canvas.range = selectedRange
        canvas.isClipTrim = configuration.showsTrim
        canvas.images = images
        canvas.sampleInterval = sampleInterval
        canvas.setNeedsDisplay()
        layoutHandles()
        if clipDrag != nil { leadingHandle.isHidden = true; trailingHandle.isHidden = true }
        for (button, leading) in [(addBefore, true), (addAfter, false)] {
            let edge = geometry.x(leading ? 0 : configuration.duration, center: centerTime)
            button.frame = CGRect(x: leading ? edge - 48 : edge + 4, y: canvas.filmBand.midY - 22, width: 44, height: 44)
            let action = leading ? configuration.addClipAtStart : configuration.addClipAtEnd
            button.isHidden = configuration.showsTrim || action == nil || clipDrag != nil || !bounds.intersects(button.frame)
        }
        updateAccessibility()
        if !pinching { loadVisibleThumbnails() }
    }

    private func updateAccessibility() {
        var elements: [Any] = [scroll]
        for clip in configuration.clips {
            let start = geometry.x(clip.segment.start, center: centerTime)
            let end = geometry.x(clip.segment.end, center: centerTime)
            let frame = CGRect(x: start, y: canvas.filmBand.minY, width: max(1, end - start), height: canvas.filmBand.height).intersection(bounds)
            guard !frame.isNull, !frame.isEmpty else { continue }
            let element = TimelineEventAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = clip.segment.freezeDuration == nil ? "Clip \(clip.number)" : "Freeze frame \(clip.number)"
            element.accessibilityIdentifier = "timeline-clip-\(clip.segment.id)"
            element.accessibilityTraits = configuration.selectedClipID == clip.segment.id ? [.button, .selected] : .button
            element.accessibilityFrameInContainerSpace = frame
            element.activate = { [weak self] in
                guard let self else { return }
                self.configuration.selectEvent(nil)
                self.configuration.selectClip(clip.segment.id)
                self.configuration.commitSeek(clip.segment.start)
            }
            element.accessibilityHint = "Hold and drag to reorder. Additional actions move this clip earlier or later."
            let index = clip.number - 1
            var actions: [UIAccessibilityCustomAction] = []
            if index > 0 {
                actions.append(UIAccessibilityCustomAction(name: "Move clip earlier") { [weak self] _ in
                    self?.configuration.reorderClip(clip.segment.id, index - 1); return true
                })
            }
            if index + 1 < configuration.clips.count {
                actions.append(UIAccessibilityCustomAction(name: "Move clip later") { [weak self] _ in
                    self?.configuration.reorderClip(clip.segment.id, index + 1); return true
                })
            }
            element.accessibilityCustomActions = actions
            elements.append(element)
        }
        var visibleIDs = Set<TimelineEventID>()
        if !configuration.showsTrim {
            for placed in placedEvents {
                let band = canvas.eventBand(row: placed.row)
                let start = geometry.x(placed.event.start, center: centerTime)
                let end = geometry.x(min(configuration.duration, placed.event.end), center: centerTime)
                let frame = CGRect(x: start, y: band.minY, width: max(8, end - start), height: band.height)
                    .intersection(CGRect(x: 0, y: canvas.eventsTop, width: bounds.width, height: max(0, bounds.height - canvas.eventsTop)))
                guard !frame.isNull, !frame.isEmpty else { continue }
                let id = placed.event.id
                visibleIDs.insert(id)
                let element = accessibleEvents[id] ?? TimelineEventAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = "\(placed.event.kind) at \(timelineTimecode(placed.event.offset, includesTenths: true))"
                element.accessibilityIdentifier = "timeline-event-\(id)"
                element.accessibilityValue = "\(timelineTimecode(placed.event.start, includesTenths: true)) to \(timelineTimecode(min(configuration.duration, placed.event.end), includesTenths: true))"
                element.accessibilityTraits = configuration.selectedEventID == id ? [.button, .selected] : .button
                element.accessibilityHint = placed.event.isDrawing
                    ? (placed.event.isLocked ? "Drawing layer is locked. Open Edit layer to unlock it." : "Select this drawing layer. Drag either edge to set its duration within the clip.")
                    : "Select or deselect this event. Adjust its start and end handles to trim."
                element.accessibilityFrameInContainerSpace = frame
                element.activate = { [weak self] in self?.selectTimelineEvent(id) }
                accessibleEvents[id] = element; elements.append(element)
            }
        }
        accessibleEvents = accessibleEvents.filter { visibleIDs.contains($0.key) }
        for handle in [leadingHandle, trailingHandle] where !handle.isHidden { elements.append(handle) }
        for button in [addBefore, addAfter] where !button.isHidden { elements.append(button) }
        accessibilityElements = elements
    }

    private func selectTimelineEvent(_ id: TimelineEventID) {
        guard let event = configuration.events.first(where: { $0.id == id }) else { return }
        let deselecting = configuration.selectedEventID == id
        configuration.selectEvent(deselecting ? nil : id)
        if !deselecting { centerTime = geometry.clamp(min(event.upperBound, max(event.lowerBound, event.offset))) }
        updateScrollGeometry(); refresh(); configuration.commitSeek(centerTime)
    }

    private func layoutHandles() {
        guard let range = selectedRange, configuration.showsTrim || selectedEvent?.isLocked != true else {
            leadingHandle.isHidden = true; trailingHandle.isHidden = true; return
        }
        let band = configuration.showsTrim ? canvas.filmBand : canvas.eventBand(id: configuration.selectedEventID)
        for handle in [leadingHandle, trailingHandle] {
            let seconds = handle.leading ? range.0 : range.1
            let x = geometry.x(seconds, center: centerTime)
            handle.isHidden = x < -12 || x > bounds.width + 12 || (!configuration.showsTrim && (band.midY < canvas.eventsTop || band.midY > bounds.height))
            handle.frame = CGRect(x: x - 22, y: band.midY - 22, width: 44, height: 44)
            handle.color = configuration.showsTrim ? UIColor(Theme.signal) : .white
            handle.accessibilityLabel = "\(configuration.showsTrim ? "Clip" : selectedEvent?.isDrawing == true ? "Drawing" : "Event") \(handle.leading ? "start" : "end")"
            handle.accessibilityValue = timelineTimecode(seconds, includesTenths: true)
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let seconds = geometry.seconds(point.x, center: centerTime)
        if point.y >= canvas.eventsTop,
           let placed = placedEvents.first(where: {
               let band = canvas.eventBand(row: $0.row)
               return band.contains(point) && seconds >= $0.event.start && seconds <= $0.event.end
           }) {
            selectTimelineEvent(placed.event.id)
            return
        } else {
            configuration.selectEvent(nil)
            if point.y < canvas.eventsTop {
                centerTime = seconds
                if let clip = configuration.clips.first(where: { seconds >= $0.segment.start && seconds < $0.segment.end }) {
                    configuration.selectClip(clip.segment.id)
                }
            }
        }
        updateScrollGeometry(); refresh(); configuration.commitSeek(centerTime)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinching = true; pinchZoom = workingZoom; pinchAnchor = centerTime; scrubbing = false
            scroll.panGestureRecognizer.isEnabled = false
            thumbnailTask?.cancel(); requestedSamples = []
            // Zoom changes scale only. Pin the playhead before publishing the new zoom.
            configuration.commitSeek(pinchAnchor)
        case .changed:
            workingZoom = max(1, min(max(1, CGFloat(configuration.duration / 2)), pinchZoom * gesture.scale))
            centerTime = pinchAnchor
            configuration.feedback.visibleSeconds = configuration.duration / Double(workingZoom)
            updateScrollGeometry(); refresh()
        case .ended, .cancelled, .failed:
            centerTime = pinchAnchor
            updateScrollGeometry()
            configuration.changeZoom(workingZoom)
            scrubbing = false
            scroll.panGestureRecognizer.isEnabled = true
            pinching = false
            refresh()
        default: break
        }
    }

    @objc private func reordered(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let point = gesture.location(in: self)
            let seconds = geometry.seconds(point.x, center: centerTime)
            guard canvas.filmBand.contains(point), point.x >= geometry.x(0, center: centerTime), point.x <= geometry.x(configuration.duration, center: centerTime), configuration.clips.count > 1,
                  let clip = configuration.clips.first(where: { seconds >= $0.segment.start && seconds < $0.segment.end }) else { return }
            clipDrag = (clip.segment.id, clip.number - 1, centerTime)
            activeReorder = gesture; scrubbing = false
            scroll.panGestureRecognizer.isEnabled = false
            configuration.commitSeek(centerTime)
            dragPreview.text = "Clip \(clip.number)"
            dragPreview.isHidden = false
            canvas.draggedClipID = clip.segment.id
            let link = CADisplayLink(target: TimelineDisplayTarget(self), selector: #selector(TimelineDisplayTarget.tick(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            updateReorder()
        case .changed: updateReorder()
        case .ended: updateReorder(); finishReorder(cancelled: false)
        case .cancelled, .failed: finishReorder(cancelled: true)
        default: break
        }
    }

    private func updateReorder() {
        guard var draft = clipDrag, let gesture = activeReorder else { return }
        let point = gesture.location(in: self)
        let seconds = geometry.seconds(point.x, center: centerTime)
        let remaining = configuration.clips.filter { $0.segment.id != draft.id }
        let destination = remaining.filter { seconds > ($0.segment.start + $0.segment.end) / 2 }.count
        if destination != draft.destination { UISelectionFeedbackGenerator().selectionChanged() }
        draft.destination = destination; clipDrag = draft
        canvas.insertionTime = destination < remaining.count ? remaining[destination].segment.start : configuration.duration
        dragPreview.frame = CGRect(x: min(bounds.width - 74, max(2, point.x - 36)), y: 1, width: 72, height: 20)
        refresh()
    }

    private func finishReorder(cancelled: Bool) {
        guard let draft = clipDrag else { return }
        displayLink?.invalidate(); displayLink = nil; activeReorder = nil; clipDrag = nil
        dragPreview.isHidden = true; canvas.draggedClipID = nil; canvas.insertionTime = nil
        scroll.panGestureRecognizer.isEnabled = true; scrubbing = false
        centerTime = draft.originalTime
        updateScrollGeometry(); refresh()
        if !cancelled { configuration.reorderClip(draft.id, draft.destination) }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer {
            let point = gestureRecognizer.location(in: self)
            let seconds = geometry.seconds(point.x, center: centerTime)
            return !configuration.showsTrim && configuration.clips.count > 1 && canvas.filmBand.contains(point)
                && point.x >= geometry.x(0, center: centerTime) && point.x <= geometry.x(configuration.duration, center: centerTime)
                && configuration.clips.contains { seconds >= $0.segment.start && seconds < $0.segment.end }
        }
        return clipDrag == nil
    }

    @objc private func trimmed(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? TimelineHandle else { return }
        switch gesture.state {
        case .began:
            guard let range = selectedRange else { return }
            let edge = handle.leading ? range.0 : range.1
            startDrag(leading: handle.leading, range: range, grabOffset: gesture.location(in: self).x - geometry.x(edge, center: centerTime))
            activePan = gesture
            let link = CADisplayLink(target: TimelineDisplayTarget(self), selector: #selector(TimelineDisplayTarget.tick(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
        case .changed: updateDrag()
        case .ended: updateDrag(); finishDrag(cancelled: false)
        case .cancelled, .failed: finishDrag(cancelled: true)
        default: break
        }
    }

    private func startDrag(leading: Bool, range: (Double, Double), grabOffset: CGFloat) {
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        drag = (leading, range.0, range.1, grabOffset)
        scroll.isScrollEnabled = false
        configuration.previewSeek(leading ? range.0 : range.1)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func updateDrag() {
        guard let activePan, let drag else { return }
        applyEdge(geometry.seconds(activePan.location(in: self).x - drag.grabOffset, center: centerTime))
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

    fileprivate func autoScroll(_ link: CADisplayLink) {
        guard let gesture = activeReorder as UIGestureRecognizer? ?? activePan else { return }
        let x = gesture.location(in: self).x
        let margin: CGFloat = min(44, bounds.width / 4)
        let direction = x < margin ? -min(1, (margin - x) / margin) : x > bounds.width - margin ? min(1, (x - bounds.width + margin) / margin) : 0
        guard direction != 0 else { return }
        centerTime = geometry.clamp(centerTime + Double(direction * 180 / geometry.pointsPerSecond) * (link.targetTimestamp - link.timestamp))
        updateScrollGeometry()
        if clipDrag != nil { updateReorder() } else { updateDrag() }
    }

    private func finishDrag(cancelled: Bool) {
        guard let draft = drag else { return }
        displayLink?.invalidate(); displayLink = nil; activePan = nil
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
        drag = nil; configuration.feedback.draft = nil; scroll.isScrollEnabled = true
        centerTime = geometry.clamp(draft.leading ? draft.start : draft.end)
        configuration.commitSeek(centerTime)
        updateScrollGeometry(); refresh()
    }

    private func loadVisibleThumbnails() {
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
        // One sequential producer per viewport prevents a fast fling from flooding the decoder.
        thumbnailTask = Task { @MainActor [weak self] in
            // Coalesce rapid scroll updates before starting another decoder request.
            try? await Task.sleep(for: .milliseconds(60))
            for seconds in samples {
                guard !Task.isCancelled else { return }
                let cached = self?.images[seconds]
                let image = if let cached { cached } else {
                    await VideoThumbnailService.shared.image(
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
                self.canvas.images = self.images; self.canvas.sampleInterval = interval
                self.canvas.setNeedsDisplay()
            }
        }
    }

    func stop() {
        thumbnailTask?.cancel(); thumbnailTask = nil
        displayLink?.invalidate(); displayLink = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

@MainActor
private final class TimelineDisplayTarget: NSObject {
    weak var viewport: TimelineViewport?
    init(_ viewport: TimelineViewport) { self.viewport = viewport }
    @objc func tick(_ link: CADisplayLink) { viewport?.autoScroll(link) }
}

private final class TimelineEventAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
}

private final class TimelineHandle: UIView {
    let leading: Bool
    var color: UIColor = .white { didSet { setNeedsDisplay() } }
    var adjust: ((Double) -> Void)?
    init(leading: Bool) {
        self.leading = leading
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true; accessibilityTraits = .adjustable
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityIncrement() { adjust?(0.1) }
    override func accessibilityDecrement() { adjust?(-0.1) }
    override func draw(_ rect: CGRect) {
        color.setFill()
        UIBezierPath(roundedRect: CGRect(x: 16, y: 3, width: 12, height: 38), cornerRadius: 4).fill()
        UIColor.black.withAlphaComponent(0.7).setFill()
        UIBezierPath(roundedRect: CGRect(x: 21, y: 14, width: 2, height: 16), cornerRadius: 1).fill()
    }
}

private final class TimelineCanvas: UIView {
    var clips: [EditorSequenceClip] = []
    var selectedClipID: UUID?
    var draggedClipID: UUID?
    var insertionTime: Double?
    var geometry = TimelineGeometry(duration: 1, width: 1, zoom: 1)
    var centerSeconds: Double = 0
    var events: [TimelineEventSnapshot] = []
    var placedEvents: [TimelinePlacedEvent] = []
    var verticalOffset: CGFloat = 0
    var selectedID: TimelineEventID?
    var range: (Double, Double)?
    var isClipTrim = false
    var images: [Double: UIImage] = [:]
    var sampleInterval: Double = 1
    var filmBand: CGRect { CGRect(x: 0, y: 26, width: bounds.width, height: min(68, max(36, bounds.height * 0.26))) }
    var eventsTop: CGFloat { filmBand.maxY + 8 }
    func eventBand(id: TimelineEventID?) -> CGRect { eventBand(row: placedEvents.first { $0.event.id == id }?.row ?? 0) }
    func eventBand(row: Int) -> CGRect {
        return CGRect(x: 0, y: eventsTop + CGFloat(row) * 36 - verticalOffset, width: bounds.width, height: 30)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), geometry.duration > 0 else { return }
        let left = geometry.seconds(0, center: centerSeconds)
        let right = geometry.seconds(bounds.width, center: centerSeconds)
        let videoRect = CGRect(x: x(0), y: filmBand.minY, width: CGFloat(geometry.duration) * geometry.pointsPerSecond, height: filmBand.height)

        // Draw only visible thumbnails. During a pinch, keep the previous samples and stretch them.
        context.saveGState(); context.clip(to: videoRect.intersection(filmBand))
        let drawInterval = max(sampleInterval, geometry.tickInterval)
        let ranges = clips.isEmpty ? [(0.0, geometry.duration)] : clips.map { ($0.segment.start, $0.segment.end) }
        for (start, end) in ranges where end >= left && start <= right {
            let band = CGRect(x: max(-8, x(start)) + 1, y: filmBand.minY,
                width: max(1, min(bounds.width + 8, x(end)) - max(-8, x(start)) - 2), height: filmBand.height)
            context.saveGState()
            UIBezierPath(roundedRect: band, cornerRadius: 6).addClip()
            UIColor.white.withAlphaComponent(0.07).setFill(); context.fill(band)
            let first = max(0, Int(floor((left - start) / drawInterval)))
            let last = max(first, Int(ceil((min(right, end) - start) / drawInterval)))
            for index in first...last {
                let seconds = start + Double(index) * drawInterval
                guard seconds < end else { continue }
                let nearest = images.keys.filter { $0 >= start && $0 < end }.min { abs($0 - seconds) < abs($1 - seconds) }
                guard let image = images[seconds] ?? nearest.flatMap({ images[$0] }) else { continue }
                let cell = CGRect(x: x(seconds), y: filmBand.minY, width: CGFloat(min(drawInterval, end - seconds)) * geometry.pointsPerSecond, height: filmBand.height)
                context.saveGState(); context.clip(to: cell)
                let scale = max(cell.width / image.size.width, cell.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height))
                context.restoreGState()
            }
            context.restoreGState()
        }
        context.restoreGState()
        for clip in clips where clip.segment.end >= left && clip.segment.start <= right {
            let start = max(-8, x(clip.segment.start)); let end = min(bounds.width + 8, x(clip.segment.end))
            let band = CGRect(x: start + 1, y: filmBand.minY, width: max(1, end - start - 2), height: filmBand.height)
            context.saveGState(); UIBezierPath(roundedRect: band, cornerRadius: 6).addClip()
            UIColor.black.withAlphaComponent(0.55).setFill()
            context.fill(CGRect(x: band.minX, y: band.maxY - 21, width: band.width, height: 21))
            if band.width > 28 {
                let title = clip.segment.freezeDuration == nil ? "Clip \(clip.number)" : "Freeze"
                label("\(title) · \(timelineTimecode(clip.segment.duration, includesTenths: true))", at: CGPoint(x: max(5, band.minX + 6), y: band.maxY - 18), color: .white)
            }
            context.restoreGState()
            (selectedClipID == clip.segment.id ? UIColor(Theme.signal) : UIColor.white.withAlphaComponent(0.65)).setStroke()
            let outline = UIBezierPath(roundedRect: band, cornerRadius: 6)
            outline.lineWidth = selectedClipID == clip.segment.id ? 2 : 1; outline.stroke()
        }
        if let id = draggedClipID, let clip = clips.first(where: { $0.segment.id == id }) {
            UIColor.black.withAlphaComponent(0.25).setFill()
            context.fill(CGRect(x: x(clip.segment.start), y: filmBand.minY, width: CGFloat(clip.segment.duration) * geometry.pointsPerSecond, height: filmBand.height))
        }
        if let insertionTime {
            UIColor(Theme.signal).setFill()
            context.fill(CGRect(x: min(bounds.width - 3, max(0, x(insertionTime) - 2)), y: filmBand.minY - 4, width: 4, height: filmBand.height + 8))
        }
        let majorStep = geometry.tickInterval
        let minorStep = geometry.subdivisionInterval
        let divisions = Int((majorStep / minorStep).rounded())
        for index in Int(ceil(left / minorStep))...max(Int(ceil(left / minorStep)), Int(floor(right / minorStep))) {
            let time = Double(index) * minorStep
            guard time >= 0, time <= geometry.duration else { continue }
            let major = index % divisions == 0
            UIColor.white.withAlphaComponent(major ? 0.6 : 0.24).setFill()
            context.fill(CGRect(x: x(time), y: major ? 16 : 20, width: 1, height: major ? 9 : 5))
            if major {
                label(timelineTimecode(time, includesTenths: majorStep < 1), at: CGPoint(x: x(time) + 4, y: 1), color: .lightGray)
            }
        }
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: eventsTop, width: bounds.width, height: max(0, bounds.height - eventsTop)))
        for placed in placedEvents {
            let event = placed.event
            let band = eventBand(row: placed.row)
            guard band.maxY >= eventsTop, band.minY <= bounds.height else { continue }
            let selected = event.id == selectedID && !isClipTrim
            let start = selected ? range?.0 ?? event.start : event.start
            let end = selected ? range?.1 ?? event.end : event.end
            guard end >= left, start <= right else { continue }
            let bar = CGRect(x: max(-12, x(start)), y: band.minY, width: max(8, min(bounds.width + 12, x(end)) - max(-12, x(start))), height: band.height)
            let tint = UIColor(EventColor.tint(hex: event.colorHex, kind: event.kind))
            tint.withAlphaComponent(selected ? 0.55 : 0.28).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: 6).fill()
            context.saveGState(); UIBezierPath(roundedRect: bar, cornerRadius: 6).addClip()
            if !event.isDrawing {
                tint.withAlphaComponent(0.30).setFill()
                context.fill(CGRect(x: x(event.offset), y: band.minY, width: max(0, x(end) - x(event.offset)), height: band.height))
                tint.setFill(); context.fill(CGRect(x: x(event.offset) - 1, y: band.minY, width: 2, height: band.height))
            }
            if bar.width > 58 {
                label("\(event.kind) · \(timelineTimecode(end - start, includesTenths: true))", at: CGPoint(x: max(8, bar.minX + 10), y: band.minY + 7), color: .white)
            }
            context.restoreGState()
            (selected ? UIColor.white : tint.withAlphaComponent(0.7)).setStroke()
            context.setLineWidth(selected ? 2 : 1)
            let outline = UIBezierPath(roundedRect: bar.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
            outline.lineWidth = selected ? 2 : 1; outline.stroke()
        }
        context.restoreGState()
        if let range, isClipTrim {
            let band = filmBand
            let start = max(-16, x(range.0)); let end = min(bounds.width + 16, x(range.1))
            UIColor.black.withAlphaComponent(0.62).setFill()
            context.fill(CGRect(x: 0, y: band.minY, width: max(0, min(bounds.width, start)), height: band.height))
            context.fill(CGRect(x: max(0, end), y: band.minY, width: max(0, bounds.width - end), height: band.height))
            if end >= start {
                let selection = CGRect(x: start, y: band.minY, width: max(1, end - start), height: band.height)
                UIColor(Theme.signal).setStroke()
                let outline = UIBezierPath(roundedRect: selection, cornerRadius: 6)
                outline.lineWidth = 2; outline.stroke()
            }
        }
        UIColor(Theme.signal).setFill()
        context.fill(CGRect(x: bounds.midX - 1, y: 16, width: 2, height: bounds.height - 18))
        let cap = UIBezierPath(); cap.move(to: CGPoint(x: bounds.midX - 4, y: 15)); cap.addLine(to: CGPoint(x: bounds.midX + 4, y: 15)); cap.addLine(to: CGPoint(x: bounds.midX, y: 21)); cap.close(); cap.fill()
    }
    private func x(_ seconds: Double) -> CGFloat { geometry.x(seconds, center: centerSeconds) }
    private func label(_ text: String, at point: CGPoint, color: UIColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color])
    }
}

func timelineTimecode(_ seconds: Double, includesTenths: Bool) -> String {
    guard includesTenths else { return timecode(seconds) }
    let value = max(0, seconds.isFinite ? seconds : 0)
    let tenths = Int((value * 10).rounded())
    return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
}
