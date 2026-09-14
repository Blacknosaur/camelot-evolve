import Foundation

struct TimelineEventID: Hashable, CustomStringConvertible {
    let eventID: UUID
    var clipID: UUID? = nil
    var description: String { "\(eventID)-\(clipID?.uuidString ?? "source")" }
}

struct TimelineEventSnapshot: Equatable {
    let id: TimelineEventID
    let offset: Double
    let preRoll: Double
    let postRoll: Double
    let kind: String
    let colorHex: String
    var isDrawing: Bool = false
    var isLocked: Bool = false
    var lowerBound: Double = 0
    var upperBound: Double = .greatestFiniteMagnitude
    var start: Double { max(lowerBound, offset - preRoll) }
    var end: Double { min(upperBound, offset + postRoll) }

    init(id: TimelineEventID = TimelineEventID(eventID: UUID()), offset: Double, preRoll: Double, postRoll: Double, kind: String, colorHex: String = "", lowerBound: Double = 0, upperBound: Double = .greatestFiniteMagnitude, isDrawing: Bool = false, isLocked: Bool = false) {
        self.isDrawing = isDrawing; self.isLocked = isLocked
        self.colorHex = colorHex
        self.lowerBound = lowerBound; self.upperBound = upperBound
        self.id = id; self.offset = offset; self.preRoll = preRoll; self.postRoll = postRoll; self.kind = kind
    }

    /// Drawing edges are independent. Match events must still contain their marker.
    func resizing(_ value: Double, start: Double, end: Double, leading: Bool, duration: Double) -> (Double, Double) {
        guard !isLocked else { return (start, end) }
        if isDrawing {
            let minimum = min(1 / 30, max(0, min(upperBound, duration) - lowerBound))
            return leading
                ? (max(lowerBound, min(value, end - minimum)), end)
                : (start, min(upperBound, duration, max(value, start + minimum)))
        }
        return leading
            ? (max(lowerBound, min(offset, end, value)), end)
            : (start, min(upperBound, duration, max(offset, start, value)))
    }

    /// Adjacent cuts of the same source window retain one marker and one pair of
    /// handles. Different timing (repeats, gaps, or speed changes) stays separate.
    func joiningContinuousWindow(_ next: Self) -> Self? {
        let tolerance = 0.000_001
        guard id.eventID == next.id.eventID, isDrawing == next.isDrawing, isLocked == next.isLocked,
              abs(upperBound - next.lowerBound) < tolerance,
              abs(end - next.start) < tolerance,
              abs(offset - next.offset) < tolerance,
              abs(preRoll - next.preRoll) < tolerance,
              abs(postRoll - next.postRoll) < tolerance else { return nil }
        // Select the clip containing the actual marker when it survives the cut.
        let anchor = offset >= next.lowerBound ? next.id : id
        return Self(id: anchor, offset: offset, preRoll: preRoll, postRoll: postRoll,
                    kind: kind, colorHex: colorHex, lowerBound: lowerBound, upperBound: next.upperBound, isDrawing: isDrawing, isLocked: isLocked)
    }
}

/// All geometry uses seconds; zoom never creates a view or layout item per frame.
struct TimelineGeometry {
    let duration: Double
    let width: CGFloat
    let zoom: CGFloat
    var contentInset: CGFloat = 0
    var pointsPerSecond: CGFloat { max(1, width - contentInset * 2) * max(1, zoom) / max(0.1, duration) }
    func x(_ seconds: Double, center: Double) -> CGFloat { width / 2 + CGFloat(seconds - center) * pointsPerSecond }
    func seconds(_ x: CGFloat, center: Double) -> Double { clamp(center + Double((x - width / 2) / pointsPerSecond)) }
    func clamp(_ seconds: Double) -> Double { max(0, min(duration, seconds)) }
    var tickInterval: Double {
        let ideal = Double(72 / pointsPerSecond)
        return [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600].first { $0 >= ideal }
            ?? ceil(ideal / 3600) * 3600
    }
    var subdivisionInterval: Double {
        let major = tickInterval
        if [0.2, 2, 120].contains(major) { return major / 4 }
        if major == 15 { return 5 }
        if [30, 60, 600, 1800, 3600].contains(major) { return major / 6 }
        return major / 5
    }
    static func trim(_ value: Double, start: Double, end: Double, duration: Double, leading: Bool) -> (Double, Double) {
        let minimum = min(0.1, max(0, duration))
        if leading { return (max(0, min(value, end - minimum)), end) }
        return (start, min(duration, max(value, start + minimum)))
    }
}

struct TimelinePlacedEvent: Equatable {
    let event: TimelineEventSnapshot
    let row: Int

    /// Interval partitioning runs only when events change, never on a scroll/zoom frame.
    static func layout(_ events: [TimelineEventSnapshot]) -> [Self] {
        var ends: [Double] = []
        return events.sorted {
            if $0.start == $1.start { return $0.offset == $1.offset ? $0.id.description < $1.id.description : $0.offset < $1.offset }
            return $0.start < $1.start
        }.map { event in
            let row = ends.firstIndex { $0 <= event.start } ?? ends.count
            let end = max(event.start + 0.1, event.end)
            if row == ends.count { ends.append(end) } else { ends[row] = end }
            return Self(event: event, row: row)
        }
    }
}

/// One preview and one workspace, separated by a fixed 20pt grip.
struct EditorPanelSizes {
    let preview: CGFloat
    let workspace: CGFloat
    init(height: CGFloat, workspace: CGFloat, minimumWorkspace: CGFloat = 220) {
        let space = max(0, height - 20)
        let minimumPreview = min(160, space * 0.35)
        let minimumWorkspace = min(minimumWorkspace, space * 0.45)
        self.workspace = min(max(minimumWorkspace, workspace), max(minimumWorkspace, space - minimumPreview))
        preview = max(0, space - self.workspace)
    }
}

/// Maps a clip's source range to its position in the assembled video.
struct EditorSequenceSegment: Equatable {
    let id: UUID
    let sourceStart: Double
    let sourceEnd: Double
    let rate: Double
    let start: Double
    var freezeDuration: Double? = nil
    var duration: Double { freezeDuration ?? max(0, sourceEnd - sourceStart) / max(0.25, min(4, rate)) }
    var end: Double { start + duration }
    func sourceTime(at seconds: Double) -> Double {
        freezeDuration != nil ? sourceStart : min(sourceEnd, max(sourceStart, sourceStart + (seconds - start) * max(0.25, min(4, rate))))
    }
    func outputTime(at seconds: Double) -> Double {
        min(end, max(start, start + (seconds - sourceStart) / max(0.25, min(4, rate))))
    }
    static func containing(_ seconds: Double, in segments: [Self]) -> Self? {
        segments.first { seconds >= $0.start && seconds < $0.end } ?? (seconds >= (segments.last?.end ?? 0) ? segments.last : segments.first)
    }
}

extension EditorSequenceSegment {
    /// Preserve the true marker position even when only its before/after window
    /// survives a cut. Drawing and handle movement are limited to retained footage.
    func eventSnapshot(_ event: TimelineEventSnapshot) -> TimelineEventSnapshot? {
        // A hold adds presentation time, not a second occurrence of a match event.
        guard freezeDuration == nil else { return nil }
        guard event.end > sourceStart, event.start < sourceEnd else { return nil }
        let speed = max(0.25, min(4, rate))
        return TimelineEventSnapshot(id: TimelineEventID(eventID: event.id.eventID, clipID: id),
            offset: start + (event.offset - sourceStart) / speed,
            preRoll: event.preRoll / speed, postRoll: event.postRoll / speed,
            kind: event.kind, colorHex: event.colorHex, lowerBound: start, upperBound: end)
    }
}

/// Preview dimensions can differ by a pixel after even-size video encoding.
func videoAspectRatioLabel(_ size: CGSize) -> String {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return "…" }
    let ratio = size.width / size.height
    for (width, height) in [(1, 1), (16, 9), (9, 16), (4, 3), (3, 4), (4, 5), (5, 4), (3, 2), (2, 3), (17, 9), (21, 9)] {
        let candidate = CGFloat(width) / CGFloat(height)
        if abs(ratio - candidate) / candidate < 0.003 { return "\(width):\(height)" }
    }
    return "\(Double(ratio).formatted(.number.precision(.fractionLength(2)))):1"
}
