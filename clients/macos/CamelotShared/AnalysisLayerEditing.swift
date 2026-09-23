import Foundation

enum AnnotationMotionMode: String, CaseIterable, Identifiable {
    case still, keyframes, player, camera
    var id: Self { self }
    var title: String {
        switch self { case .still: "Static"; case .keyframes: "Keyframes"; case .player: "Follow player"; case .camera: "Follow camera" }
    }
}

enum AnnotationTimelineEdit {
    case move(Double), trimStart(Double), trimEnd(Double), keyframe(UUID, Double)
}

extension AnalysisAnnotation {
    var motionMode: AnnotationMotionMode {
        cameraMotion != nil ? .camera : playerMotion != nil || linkedPlayers != nil ? .player : keyframes.isEmpty ? .still : .keyframes
    }

    /// All timeline edits use source seconds. Automatic motion stays attached to
    /// source frames; only authored keyframes move when a layer is moved.
    func applying(_ edit: AnnotationTimelineEdit, within bounds: ClosedRange<Double>) -> Self {
        guard isLocked != true else { return self }
        var result = self
        let minimum = min(1 / 30.0, bounds.upperBound - bounds.lowerBound)
        switch edit {
        case .move(let delta):
            let shift = min(bounds.upperBound - end, max(bounds.lowerBound - start, delta))
            result.start += shift; result.end += shift
            if motionMode == .still || motionMode == .keyframes {
                result.keyframes = keyframes.map { frame in var frame = frame; frame.time += shift; return frame }
            }
        case .trimStart(let value):
            result.start = min(end - minimum, max(bounds.lowerBound, value))
        case .trimEnd(let value):
            result.end = max(start + minimum, min(bounds.upperBound, value))
        case .keyframe(let id, let value):
            guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return self }
            let lower = max(start, index > 0 ? keyframes[index - 1].time + 1 / 60 : start)
            let upper = min(end, index + 1 < keyframes.count ? keyframes[index + 1].time - 1 / 60 : end)
            guard upper >= lower else { return self }
            result.keyframes[index].time = min(upper, max(lower, value))
        }
        return result
    }

    mutating func makeStatic(at time: Double) {
        points = points(at: time); keyframes = []; playerMotion = nil; linkedPlayers = nil; cameraMotion = nil
    }

    mutating func enableKeyframes(at time: Double) {
        guard keyframes.isEmpty || motionMode == .player || motionMode == .camera else { return }
        makeStatic(at: time)
        setKeyframe(at: start, points: points)
        if time > start + 1 / 30, time <= end { setKeyframe(at: time, points: points) }
    }

    mutating func moveDrawing(to points: [CGPoint], at time: Double) {
        if motionMode == .keyframes { setKeyframe(at: min(end, max(start, time)), points: points) }
        else if let camera = cameraMotion?.transform(at: time) {
            let inverse = CameraTransform(camera.matrix.inverse)
            self.points = points.compactMap { inverse.point($0) }
        } else if let linkedPlayers, linkedPlayers.count == points.count {
            self.points = zip(points, linkedPlayers).map { point, motion in
                guard let reference = motion.reference, let box = motion.box(at: time) else { return point }
                return CGPoint(x: reference.midX + point.x - box.midX, y: reference.maxY + point.y - box.maxY)
            }
        } else if let motion = displayPlayerMotion, let reference = motion.reference, let box = motion.box(at: time) {
            if [.player, .spotlight].contains(tool) {
                guard let body = motion.effectBodyBox(at: time), let feet = motion.groundPoint(at: time) else { return }
                self.points = points.map { CGPoint(x: reference.midX + ($0.x - feet.x) * reference.width / max(0.001, body.width),
                                                   y: reference.maxY + ($0.y - feet.y) * reference.height / max(0.001, body.height)) }
                return
            }
            if tool == .text || tool == .loupe {
                self.points = points.map { CGPoint(x: $0.x + reference.midX - box.midX, y: $0.y + reference.midY - box.midY) }
                return
            }
            self.points = points.map { CGPoint(x: reference.midX + ($0.x - box.midX) * reference.width / max(0.001, box.width),
                                               y: reference.maxY + ($0.y - box.maxY) * reference.height / max(0.001, box.height)) }
        }
        else { self.points = points }
    }

    var motionStart: Double? {
        cameraMotion?.samples.first?.time ?? linkedPlayers?.compactMap { $0.samples.first?.time }.max() ?? playerMotion?.samples.first?.time
    }

    var trackedSpan: ClosedRange<Double>? {
        let lower = max(start, motionStart ?? start)
        let upper: Double
        if let cameraMotion { upper = min(end, cameraMotion.lostAt ?? cameraMotion.samples.last?.time ?? start) }
        else {
            let motions = linkedPlayers ?? playerMotion.map { [$0] } ?? []
            guard !motions.isEmpty else { return nil }
            upper = min(end, motions.compactMap { $0.lostAt ?? $0.samples.last?.time }.min() ?? start)
        }
        return lower <= upper ? lower...upper : nil
    }
    var trackingGaps: [ClosedRange<Double>] { (linkedPlayers ?? playerMotion.map { [$0] } ?? []).flatMap { $0.gaps ?? [] } }
}
