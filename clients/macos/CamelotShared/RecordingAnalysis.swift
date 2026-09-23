import CoreGraphics
import Foundation
import simd

/// Derived, regenerable per-recording analysis (player boxes, poses, tracks).
/// Stored as a sidecar file next to recordings and never synced: the server can
/// recompute it, and it is far larger than the metadata sync path allows.
///
/// All coordinates are normalised 0…1 in the recording's *display* frame
/// (after `preferredTransform`), origin top-left, so they map straight onto any
/// player surface regardless of source resolution.
struct RecordingAnalysis: Codable, Equatable, Sendable {
    // Version 2 invalidates Vision-only sidecars now that the sports model is
    // the primary detector. Reusing those files would leave players missing.
    static let currentVersion = 3
    /// Frames further apart than this from the requested time are not shown.
    static let frameTolerance = 0.12

    var version = RecordingAnalysis.currentVersion
    var recordingID: UUID
    var displayWidth: Int
    var displayHeight: Int
    /// Analysed windows as `[start, end]` pairs in recording seconds, sorted, non-overlapping.
    var ranges: [[Double]] = []
    /// Sorted by time.
    var frames: [AnalysisFrame] = []
    var tracks: [AnalysisTrack] = []
    /// Cluster centres (normalised r, g, b) of the team colours, index = team.
    var teamColors: [[Float]] = []

    var displayAspect: CGFloat { CGFloat(displayWidth) / CGFloat(max(1, displayHeight)) }

    func track(_ id: Int) -> AnalysisTrack? { tracks.first { $0.id == id } }

    func isAnalyzed(from start: Double, to end: Double) -> Bool {
        ranges.contains { $0[0] <= start + 0.05 && $0[1] >= end - 0.05 }
    }

    /// Nearest frame to `time`, or nil when the time has not been analysed.
    func frame(at time: Double) -> AnalysisFrame? {
        guard !frames.isEmpty else { return nil }
        var low = 0, high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].time < time { low = mid + 1 } else { high = mid }
        }
        var best = frames[low]
        if low > 0, abs(frames[low - 1].time - time) < abs(best.time - time) { best = frames[low - 1] }
        return abs(best.time - time) <= Self.frameTolerance ? best : nil
    }

    /// Replace everything inside `range` with new results and fold the window into `ranges`.
    mutating func merge(frames newFrames: [AnalysisFrame], tracks newTracks: [AnalysisTrack], teamColors newTeamColors: [[Float]], range: ClosedRange<Double>) {
        frames.removeAll { $0.time >= range.lowerBound && $0.time <= range.upperBound }
        let staleTracks = Set(tracks.filter { $0.start >= range.lowerBound && $0.end <= range.upperBound }.map(\.id))
        tracks.removeAll { staleTracks.contains($0.id) }
        // Keep track ids unique across windows.
        let offset = (tracks.map(\.id).max() ?? -1) + 1
        let shifted = newTracks.map { var track = $0; track.id += offset; return track }
        let shiftedFrames = newFrames.map { frame in
            var frame = frame
            frame.detections = frame.detections.map { var d = $0; d.track += offset; return d }
            return frame
        }
        frames = (frames + shiftedFrames).sorted { $0.time < $1.time }
        tracks += shifted
        teamColors = newTeamColors
        var merged: [[Double]] = []
        for window in (ranges + [[range.lowerBound, range.upperBound]]).sorted(by: { $0[0] < $1[0] }) {
            if let last = merged.last, window[0] <= last[1] + 0.05 {
                merged[merged.count - 1][1] = max(last[1], window[1])
            } else { merged.append(window) }
        }
        ranges = merged
    }
}

struct AnalysisFrame: Codable, Equatable, Sendable {
    var time: Double
    var detections: [AnalysisDetection]
}

struct AnalysisDetection: Codable, Equatable, Sendable {
    var track: Int
    /// x, y, width, height — normalised, top-left origin.
    var box: [Float]
    /// Flat `[x, y, confidence]` triples in `AnalysisSkeleton.jointNames` order, or nil when no pose was found.
    var joints: [Float]?

    var rect: CGRect {
        guard box.count == 4 else { return .zero }
        return CGRect(x: CGFloat(box[0]), y: CGFloat(box[1]), width: CGFloat(box[2]), height: CGFloat(box[3]))
    }
    func joint(_ index: Int, minimumConfidence: Float = 0.25) -> CGPoint? {
        guard let joints, joints.count >= (index + 1) * 3, joints[index * 3 + 2] >= minimumConfidence else { return nil }
        return CGPoint(x: CGFloat(joints[index * 3]), y: CGFloat(joints[index * 3 + 1]))
    }
}

struct AnalysisTrack: Codable, Equatable, Sendable {
    var id: Int
    var start: Double
    var end: Double
    var frameCount: Int
    /// Mean torso colour (normalised r, g, b) used for team assignment.
    var color: [Float]?
    var team: Int?
}

/// Joint order and skeleton edges shared by the engine (which fills it) and the overlay (which draws it).
enum AnalysisSkeleton {
    static let jointNames = ["nose", "leftEye", "rightEye", "leftEar", "rightEar",
                             "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist",
                             "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle", "neck", "root"]
    static let edges: [(Int, Int)] = [
        (17, 5), (17, 6), (5, 7), (7, 9), (6, 8), (8, 10),  // shoulders and arms
        (5, 11), (6, 12), (11, 12),                          // torso
        (11, 13), (13, 15), (12, 14), (14, 16),              // legs
        (0, 17),                                             // head
    ]
}

// MARK: - Tracking

/// Motion prediction and jersey appearance keep short tracks stable between
/// detections. Pair assignments are one-to-one; uncertain identities start anew.
struct PlayerTracker: Sendable {
    struct Candidate: Sendable {
        var box: CGRect
        var joints: [Float]?
        var color: SIMD3<Float>?
    }
    private struct Active {
        var id: Int
        var box: CGRect
        var lastTime: Double
        var start: Double
        var frameCount: Int
        var colorSum: SIMD3<Float>
        var colorCount: Int
        var velocity: CGPoint = .zero
    }

    var overlapThreshold: CGFloat = 0.25
    /// A player hidden for longer than this becomes a new track when they reappear.
    var maximumGap = 0.7
    private var active: [Active] = []
    private var finished: [AnalysisTrack] = []
    private var nextID = 0

    init() {}

    mutating func update(time: Double, candidates: [Candidate]) -> [AnalysisDetection] {
        let expired = active.filter { time - $0.lastTime > maximumGap }
        if !expired.isEmpty {
            finished += expired.map(Self.track)
            active.removeAll { time - $0.lastTime > maximumGap }
        }
        // Score every pair, take the best matches first.
        var pairs: [(score: CGFloat, track: Int, candidate: Int)] = []
        for (t, entry) in active.enumerated() {
            let elapsed = min(0.3, max(0, time - entry.lastTime))
            let predicted = entry.box.offsetBy(dx: entry.velocity.x * elapsed, dy: entry.velocity.y * elapsed)
            for (c, candidate) in candidates.enumerated() {
                var score = max(Self.overlap(entry.box, candidate.box), Self.overlap(predicted, candidate.box))
                if let color = candidate.color, entry.colorCount > 0 {
                    let mean = entry.colorSum / Float(entry.colorCount)
                    let distance = simd_distance(mean, color)
                    if distance > 0.55 { continue }
                    score *= CGFloat(1 - min(0.5, distance))
                }
                if score >= overlapThreshold { pairs.append((score, t, c)) }
            }
        }
        pairs.sort { $0.score > $1.score }
        var usedTracks = Set<Int>(), usedCandidates = Set<Int>()
        var assignment: [Int: Int] = [:]  // candidate → active index
        for pair in pairs where !usedTracks.contains(pair.track) && !usedCandidates.contains(pair.candidate) {
            usedTracks.insert(pair.track); usedCandidates.insert(pair.candidate)
            assignment[pair.candidate] = pair.track
        }
        var detections: [AnalysisDetection] = []
        for (c, candidate) in candidates.enumerated() {
            let index: Int
            if let matched = assignment[c] {
                index = matched
            } else {
                active.append(Active(id: nextID, box: candidate.box, lastTime: time, start: time, frameCount: 0, colorSum: .zero, colorCount: 0))
                nextID += 1
                index = active.count - 1
            }
            let elapsed = time - active[index].lastTime
            if elapsed > 0.001 {
                let velocity = CGPoint(x: (candidate.box.midX - active[index].box.midX) / elapsed, y: (candidate.box.midY - active[index].box.midY) / elapsed)
                active[index].velocity = CGPoint(x: active[index].velocity.x * 0.3 + velocity.x * 0.7, y: active[index].velocity.y * 0.3 + velocity.y * 0.7)
            }
            active[index].box = candidate.box
            active[index].lastTime = time
            active[index].frameCount += 1
            if let color = candidate.color { active[index].colorSum += color; active[index].colorCount += 1 }
            let box = candidate.box
            detections.append(AnalysisDetection(track: active[index].id,
                box: [Float(box.minX), Float(box.minY), Float(box.width), Float(box.height)].map { ($0 * 1000).rounded() / 1000 },
                joints: candidate.joints))
        }
        return detections
    }

    /// All tracks seen so far, including still-active ones.
    var tracks: [AnalysisTrack] { (finished + active.map(Self.track)).sorted { $0.id < $1.id } }

    private static func track(_ entry: Active) -> AnalysisTrack {
        let color: [Float]? = entry.colorCount > 0 ? {
            let mean = entry.colorSum / Float(entry.colorCount)
            return [mean.x, mean.y, mean.z]
        }() : nil
        return AnalysisTrack(id: entry.id, start: entry.start, end: entry.lastTime, frameCount: entry.frameCount, color: color, team: nil)
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let union = a.width * a.height + b.width * b.height - intersection.width * intersection.height
        return union > 0 ? intersection.width * intersection.height / union : 0
    }
}

// MARK: - Team colours

enum TeamClustering {
    /// Assign each track with a colour to one of `k` clusters (k-means on chromaticity).
    /// Short tracks are still assigned but do not seed the centres.
    static func assign(_ tracks: [AnalysisTrack], k: Int = 2, minimumFrames: Int = 8) -> (tracks: [AnalysisTrack], centers: [[Float]]) {
        let colored = tracks.filter { $0.color != nil }
        guard colored.count >= k else { return (tracks, []) }
        let seeds = colored.filter { $0.frameCount >= minimumFrames }
        let points = (seeds.isEmpty ? colored : seeds).map { feature($0.color!) }
        var centers = initialCenters(points, k: k)
        for _ in 0..<12 {
            var sums = Array(repeating: SIMD3<Float>.zero, count: k), counts = Array(repeating: 0, count: k)
            for point in points {
                let index = nearest(point, centers)
                sums[index] += point; counts[index] += 1
            }
            var moved = false
            for index in 0..<k where counts[index] > 0 {
                let next = sums[index] / Float(counts[index])
                if simd_length(next - centers[index]) > 0.0005 { moved = true }
                centers[index] = next
            }
            if !moved { break }
        }
        let assigned = tracks.map { track -> AnalysisTrack in
            var track = track
            if let color = track.color { track.team = nearest(feature(color), centers) }
            return track
        }
        // Report the mean *display* colour of each cluster, not the chromaticity feature.
        var display = Array(repeating: SIMD3<Float>.zero, count: k), counts = Array(repeating: 0, count: k)
        for track in assigned { if let team = track.team, let color = track.color { display[team] += SIMD3(color[0], color[1], color[2]); counts[team] += 1 } }
        let centersOut = (0..<k).map { counts[$0] > 0 ? display[$0] / Float(counts[$0]) : SIMD3<Float>(0.5, 0.5, 0.5) }
        return (assigned, centersOut.map { [$0.x, $0.y, $0.z] })
    }

    /// Chromaticity (r/sum, g/sum) plus a damped brightness term, so shadow and sun
    /// on the same kit stay together while white and dark kits still separate.
    static func feature(_ rgb: [Float]) -> SIMD3<Float> {
        let sum = max(0.001, rgb[0] + rgb[1] + rgb[2])
        return SIMD3(rgb[0] / sum, rgb[1] / sum, sum / 3 * 0.35)
    }

    private static func initialCenters(_ points: [SIMD3<Float>], k: Int) -> [SIMD3<Float>] {
        // Farthest-point seeding: first the mean, then whatever is furthest from the chosen set.
        var centers = [points.reduce(.zero, +) / Float(points.count)]
        while centers.count < k {
            let far = points.max { a, b in
                centers.map { simd_length(a - $0) }.min()! < centers.map { simd_length(b - $0) }.min()!
            } ?? points[0]
            centers.append(far)
        }
        return centers
    }

    private static func nearest(_ point: SIMD3<Float>, _ centers: [SIMD3<Float>]) -> Int {
        var best = 0, bestDistance = Float.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let distance = simd_length(point - center)
            if distance < bestDistance { bestDistance = distance; best = index }
        }
        return best
    }
}

// MARK: - Mapping normalised coordinates onto a player surface

/// Where the recording's frame lands inside a player view, given how the
/// editor composes it: `resizeAspect` for the source, or the sequence preview's
/// centred crop when a fixed aspect is chosen.
struct AnalysisFrameMapping: Equatable {
    let videoRect: CGRect

    init(container: CGSize, displayAspect: CGFloat, renderAspect: CGFloat?) {
        let renderRatio = renderAspect ?? displayAspect
        let renderRect = Self.fit(ratio: renderRatio, in: CGRect(origin: .zero, size: container))
        if renderAspect == nil {
            videoRect = renderRect
        } else {
            // Fixed aspect: the source fills the render frame and is centred (see EditorSequencePreview).
            let scale = max(renderRect.width / displayAspect, renderRect.height) // treat display height as 1
            let size = CGSize(width: displayAspect * scale, height: scale)
            videoRect = CGRect(x: renderRect.midX - size.width / 2, y: renderRect.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    func point(_ normalized: CGPoint) -> CGPoint {
        CGPoint(x: videoRect.minX + normalized.x * videoRect.width, y: videoRect.minY + normalized.y * videoRect.height)
    }
    func rect(_ normalized: CGRect) -> CGRect {
        CGRect(x: videoRect.minX + normalized.minX * videoRect.width, y: videoRect.minY + normalized.minY * videoRect.height,
               width: normalized.width * videoRect.width, height: normalized.height * videoRect.height)
    }
    func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - videoRect.minX) / max(1, videoRect.width), y: (point.y - videoRect.minY) / max(1, videoRect.height))
    }

    static func fit(ratio: CGFloat, in bounds: CGRect) -> CGRect {
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let width = min(bounds.width, bounds.height * ratio)
        let height = width / ratio
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}

// MARK: - Storage

enum AnalysisStore {
    static var folder: URL { URL.documentsDirectory.appending(path: "Analysis", directoryHint: .isDirectory) }
    static func url(for recordingID: UUID) -> URL { folder.appending(path: recordingID.uuidString).appendingPathExtension("json") }

    static func load(recordingID: UUID) -> RecordingAnalysis? {
        guard let data = try? Data(contentsOf: url(for: recordingID)),
              let analysis = try? JSONDecoder().decode(RecordingAnalysis.self, from: data),
              analysis.version == RecordingAnalysis.currentVersion else { return nil }
        return analysis
    }

    static func save(_ analysis: RecordingAnalysis) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(analysis)
        try data.write(to: url(for: analysis.recordingID), options: .atomic)
    }

    static func delete(recordingID: UUID) {
        try? FileManager.default.removeItem(at: url(for: recordingID))
    }
}
