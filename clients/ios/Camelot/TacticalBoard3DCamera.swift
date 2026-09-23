import CoreGraphics
import Foundation
import simd

// MARK: - View pose

/// A resolved camera in world space (metres; x along the field length, z along its width, y up).
/// `fieldOfViewDegrees` spans the shorter side of the viewport, as for the orbit camera.
struct BoardViewPose: Equatable, Sendable {
    var eye: SIMD3<Double>
    /// Unit look direction.
    var forward: SIMD3<Double>
    var fieldOfViewDegrees: Double
    /// Roughly how far the interesting part of the view is (fog and label sizing).
    var focusDistance: Double
    /// Elements hidden because the camera looks through their eyes. Usually one; a blend between
    /// two point-of-view keys hides both for its whole length, so neither figure pops into view.
    var hiddenSubjects: Set<UUID> = []

    /// The single hidden subject, when there is exactly one (the common case).
    var hiddenSubject: UUID? { hiddenSubjects.count == 1 ? hiddenSubjects.first : nil }

    var target: SIMD3<Double> { eye + forward * focusDistance }

    var right: SIMD3<Double> {
        let cross = simd_cross(forward, SIMD3(0, 1, 0))
        return simd_length(cross) > 1e-6 ? simd_normalize(cross) : SIMD3(1, 0, 0)
    }

    var up: SIMD3<Double> { simd_cross(right, forward) }

    func tangents(_ viewport: CGSize) -> (Double, Double) {
        let aspect = Double(max(1, viewport.width) / max(1, viewport.height))
        let t = tan(fieldOfViewDegrees * .pi / 360)
        return aspect >= 1 ? (t * aspect, t) : (t, t / max(0.01, aspect))
    }

    func project(_ world: SIMD3<Double>, viewport: CGSize) -> CGPoint? {
        let (tanX, tanY) = tangents(viewport)
        let v = world - eye
        let depth = simd_dot(v, forward)
        guard depth > 1e-6 else { return nil }
        let x = simd_dot(v, right) / (depth * tanX), y = simd_dot(v, up) / (depth * tanY)
        return CGPoint(x: (x + 1) / 2 * viewport.width, y: (1 - y) / 2 * viewport.height)
    }

    func rayDirection(through screen: CGPoint, viewport: CGSize) -> SIMD3<Double> {
        let (tanX, tanY) = tangents(viewport)
        let x = Double(screen.x / max(1, viewport.width)) * 2 - 1
        let y = 1 - Double(screen.y / max(1, viewport.height)) * 2
        return simd_normalize(forward + right * (x * tanX) + up * (y * tanY))
    }

    func groundPoint(at screen: CGPoint, viewport: CGSize) -> SIMD3<Double>? {
        let direction = rayDirection(through: screen, viewport: viewport)
        guard direction.y < -1e-4 else { return nil }
        let t = -eye.y / direction.y
        return t > 0 ? eye + direction * t : nil
    }

    var transform: simd_float4x4 {
        let r = right, u = up, back = -forward
        return simd_float4x4(columns: (
            SIMD4(Float(r.x), Float(r.y), Float(r.z), 0),
            SIMD4(Float(u.x), Float(u.y), Float(u.z), 0),
            SIMD4(Float(back.x), Float(back.y), Float(back.z), 0),
            SIMD4(Float(eye.x), Float(eye.y), Float(eye.z), 1)
        ))
    }

    /// The pose turned by `yaw` degrees (clockwise from above) and tilted by `pitch` degrees.
    func lookingAround(yaw: Double, pitch: Double) -> BoardViewPose {
        var copy = self
        let (currentYaw, currentPitch) = BoardViewPose.angles(of: forward)
        copy.forward = BoardViewPose.direction(yaw: currentYaw + yaw, pitch: min(80, max(-85, currentPitch + pitch)))
        return copy
    }

    /// Unit direction for a yaw (degrees clockwise on the top view, 0 towards +x) and pitch (up positive).
    static func direction(yaw: Double, pitch: Double) -> SIMD3<Double> {
        let y = yaw * .pi / 180, p = pitch * .pi / 180
        return SIMD3(cos(p) * cos(y), sin(p), cos(p) * sin(y))
    }

    static func angles(of direction: SIMD3<Double>) -> (yaw: Double, pitch: Double) {
        let d = simd_normalize(direction)
        return (atan2(d.z, d.x) * 180 / .pi, asin(max(-1, min(1, d.y))) * 180 / .pi)
    }

    /// World-space blend: eye and focus distance lerp, direction slerps, field of view lerps.
    static func blend(_ a: BoardViewPose, _ b: BoardViewPose, _ t: Double) -> BoardViewPose {
        let t = min(1, max(0, t))
        var result = a
        result.eye = a.eye + (b.eye - a.eye) * t
        result.forward = slerp(a.forward, b.forward, t)
        result.fieldOfViewDegrees = a.fieldOfViewDegrees + (b.fieldOfViewDegrees - a.fieldOfViewDegrees) * t
        result.focusDistance = a.focusDistance + (b.focusDistance - a.focusDistance) * t
        // Both subjects stay hidden for the whole blend: switching at the midpoint drops the figure
        // we are flying out of straight in front of the camera.
        result.hiddenSubjects = t <= 0 ? a.hiddenSubjects : t >= 1 ? b.hiddenSubjects : a.hiddenSubjects.union(b.hiddenSubjects)
        return result
    }

    static func slerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        let a = simd_normalize(a), b = simd_normalize(b)
        let dot = max(-1, min(1, simd_dot(a, b)))
        let angle = acos(dot)
        if angle < 1e-4 { return simd_normalize(a + (b - a) * t) }
        if angle > .pi - 1e-3 {
            // Opposite directions: turn through the horizontal perpendicular.
            let axis = simd_normalize(simd_cross(a, SIMD3(0, 1, 0)) + SIMD3(0, 1e-6, 0))
            let q = simd_quatd(angle: angle * t, axis: axis)
            return simd_normalize(q.act(a))
        }
        let s = sin(angle)
        return simd_normalize(a * (sin((1 - t) * angle) / s) + b * (sin(t * angle) / s))
    }
}

// MARK: - Resolver

/// Turns any `BoardCamera` (orbit, free or point of view) into a world pose at a playback time.
/// Pure and deterministic, so the live view and exports agree frame for frame.
enum BoardCameraResolver {
    static let freeFieldOfView = 55.0
    static let pointOfViewFieldOfView = 65.0
    /// Eye height of a standing figure at figure scale 1 (the figures are ~1.65 m tall at the head).
    static let figureEyeHeight = 1.5

    /// The pose for `camera` at `time`. Orbit cameras use `framing` when given, else solve it.
    static func pose(_ camera: BoardCamera, in document: BoardDocument, time: Double?, viewport: CGSize, framing: BoardFraming? = nil) -> BoardViewPose {
        switch camera.resolvedMode {
        case .orbit:
            return orbitPose(camera, field: document.fieldType, viewport: viewport, framing: framing)
        case .free:
            return freePose(camera, field: document.fieldType) ?? orbitPose(camera, field: document.fieldType, viewport: viewport, framing: framing)
        case .pointOfView:
            if let pose = pointOfViewPose(camera, in: document, time: time) { return pose }
            // Subject gone: the camera's free pose if it has one, else its orbit.
            return freePose(camera, field: document.fieldType) ?? orbitPose(camera.orbiting, field: document.fieldType, viewport: viewport, framing: framing)
        }
    }

    /// The pose a board shows at `time`: the camera track (keys blended in world space unless both
    /// are orbit cameras) during playback when the board animates its camera, else its own camera.
    static func pose(for document: BoardDocument, time: Double?, viewport: CGSize) -> BoardViewPose {
        guard let time, document.viewAngle.is3D, let blend = document.cameraBlend(at: time) else {
            return pose(document.cameraOrDefault, in: document, time: time, viewport: viewport)
        }
        if blend.fraction == 0 || (blend.from.isOrbit && blend.to.isOrbit) {
            return pose(document.camera(at: time), in: document, time: time, viewport: viewport)
        }
        let from = pose(blend.from, in: document, time: time, viewport: viewport)
        let to = pose(blend.to, in: document, time: time, viewport: viewport)
        return BoardViewPose.blend(from, to, blend.fraction)
    }

    static func orbitPose(_ camera: BoardCamera, field: BoardFieldType, viewport: CGSize, framing: BoardFraming?) -> BoardViewPose {
        let orbit = BoardOrbit(field: field, camera: camera.orbiting, viewport: viewport, framing: framing)
        return BoardViewPose(eye: orbit.eye, forward: orbit.forward, fieldOfViewDegrees: BoardOrbit.fieldOfViewDegrees, focusDistance: orbit.distance)
    }

    static func freePose(_ camera: BoardCamera, field: BoardFieldType) -> BoardViewPose? {
        guard let eye = camera.eye, let yaw = camera.yawDegrees else { return nil }
        let height = BoardFreeCamera.clampedHeight(camera.eyeHeightMeters ?? 1.7)
        let position = BoardOrbit.world(BoardFreeCamera.clampedEye(eye), field: field, y: height)
        let pitch = min(BoardFreeCamera.pitchRange.upperBound, max(BoardFreeCamera.pitchRange.lowerBound, camera.pitchDegrees ?? -15))
        let forward = BoardViewPose.direction(yaw: yaw, pitch: pitch)
        return BoardViewPose(eye: position, forward: forward, fieldOfViewDegrees: camera.fieldOfViewDegrees ?? freeFieldOfView,
                             focusDistance: focus(eye: position, forward: forward, field: field))
    }

    /// Through the subject's eyes: head height of its (scaled) figure, a little behind the head,
    /// looking along its facing, at the ball, at another element or in a fixed direction. The look
    /// direction is averaged over ±0.2 s during playback so turns do not jitter.
    static func pointOfViewPose(_ camera: BoardCamera, in document: BoardDocument, time: Double?) -> BoardViewPose? {
        guard let subjectID = camera.subjectID else { return nil }
        let field = document.fieldType
        let elements = document.elements(at: time)
        guard let subject = elements.first(where: { $0.id == subjectID }), subject.kind.isPoint else { return nil }
        let scale = BoardOrbit.figureScale(field) * max(0.1, subject.size)
        let standing = subject.kind.isPerson || subject.kind.isStaff || subject.kind == .mannequin
        let head = BoardOrbit.world(subject.position, field: field, y: (standing ? figureEyeHeight : 0.6) * scale)

        /// Eye position for a head position and look direction: a little behind the head.
        func eye(_ head: SIMD3<Double>, _ direction: SIMD3<Double>) -> SIMD3<Double> {
            let horizontal = SIMD3(direction.x, 0, direction.z)
            return simd_length(horizontal) > 1e-6 ? head - simd_normalize(horizontal) * (0.18 * scale) : head
        }

        func look(_ layout: [BoardElement]) -> SIMD3<Double>? {
            guard let me = layout.first(where: { $0.id == subjectID }) else { return nil }
            let head = BoardOrbit.world(me.position, field: field, y: (standing ? figureEyeHeight : 0.6) * scale)
            // Aim from the eye (two passes: the eye sits behind the head along the look direction).
            func aimed(_ target: SIMD3<Double>) -> SIMD3<Double> {
                let first = aim(from: head, at: target, fallbackYaw: me.rotation)
                return aim(from: eye(head, first), at: target, fallbackYaw: me.rotation)
            }
            switch camera.lookAt ?? .facing {
            case .facing:
                return BoardViewPose.direction(yaw: me.rotation, pitch: -8)
            case .fixed(let yaw):
                return BoardViewPose.direction(yaw: yaw, pitch: -8)
            case .ball:
                let balls = layout.filter { $0.kind == .ball }
                guard let ball = balls.min(by: { simd_distance(BoardOrbit.world($0.position, field: field), head) < simd_distance(BoardOrbit.world($1.position, field: field), head) }) else {
                    return BoardViewPose.direction(yaw: me.rotation, pitch: -8)
                }
                return aimed(BoardOrbit.world(ball.position, field: field, y: 0.17 * BoardOrbit.figureScale(field)))
            case .element(let id):
                guard let other = layout.first(where: { $0.id == id }) else { return BoardViewPose.direction(yaw: me.rotation, pitch: -8) }
                let otherScale = BoardOrbit.figureScale(field) * max(0.1, other.size)
                return aimed(BoardOrbit.world(other.position, field: field, y: 0.9 * otherScale))
            }
        }

        var forward = look(elements) ?? BoardViewPose.direction(yaw: subject.rotation, pitch: -8)
        // Smooth turns during playback. Two extra samples are enough and keep the per-frame cost of
        // resolving the whole layout down.
        if let time, document.isAnimated, needsSmoothing(camera) {
            var sum = forward
            for offset in [-0.15, 0.15] {
                if let direction = look(document.elements(at: max(0, min(document.duration, time + offset)))) { sum += direction }
            }
            if simd_length(sum) > 1e-6 { forward = simd_normalize(sum) }
        }
        let eye = eye(head, forward)
        return BoardViewPose(eye: eye, forward: forward, fieldOfViewDegrees: camera.fieldOfViewDegrees ?? pointOfViewFieldOfView,
                             focusDistance: focus(eye: eye, forward: forward, field: field), hiddenSubjects: [subjectID])
    }

    /// A fixed look never jitters, so it needs no smoothing.
    private static func needsSmoothing(_ camera: BoardCamera) -> Bool {
        if case .fixed = camera.lookAt ?? .facing { return false }
        return true
    }

    private static func aim(from: SIMD3<Double>, at: SIMD3<Double>, fallbackYaw: Double) -> SIMD3<Double> {
        let delta = at - from
        guard simd_length(SIMD3(delta.x, 0, delta.z)) > 0.05 else { return BoardViewPose.direction(yaw: fallbackYaw, pitch: -30) }
        let (yaw, pitch) = BoardViewPose.angles(of: delta)
        return BoardViewPose.direction(yaw: yaw, pitch: max(-60, min(20, pitch)))
    }

    /// Distance to where the look ray meets the ground, bounded by the field size.
    static func focus(eye: SIMD3<Double>, forward: SIMD3<Double>, field: BoardFieldType) -> Double {
        let size = Double(max(field.meters.width, field.meters.height))
        guard forward.y < -0.02 else { return size * 0.6 }
        return min(size * 1.2, max(2, eye.y / -forward.y))
    }
}

// MARK: - Free camera controls

/// Walk-around camera maths: look, move, change height and reset, all clamped.
enum BoardFreeCamera {
    static let heightRange = 0.5...40.0
    static let pitchRange = -85.0...35.0
    /// How far outside the lines the eye may go, as a fraction of the field.
    static let margin = 0.25

    static func clampedHeight(_ height: Double) -> Double {
        min(heightRange.upperBound, max(heightRange.lowerBound, height))
    }

    static func clampedEye(_ eye: BoardPoint) -> BoardPoint {
        BoardPoint(min(1 + margin, max(-margin, eye.x)), min(1 + margin, max(-margin, eye.y)))
    }

    /// A free camera matching a resolved pose (used when switching into free mode).
    static func camera(from pose: BoardViewPose, base: BoardCamera, field: BoardFieldType) -> BoardCamera {
        var camera = base
        camera.mode = .free
        camera.subjectID = nil
        camera.eye = clampedEye(BoardOrbit.board(pose.eye, field: field))
        camera.eyeHeightMeters = clampedHeight(pose.eye.y)
        let (yaw, pitch) = BoardViewPose.angles(of: pose.forward)
        camera.yawDegrees = yaw
        camera.pitchDegrees = min(pitchRange.upperBound, max(pitchRange.lowerBound, pitch))
        camera.fieldOfViewDegrees = BoardCameraResolver.freeFieldOfView
        return camera
    }

    /// One-finger look: horizontal drag turns, vertical drag tilts (points).
    static func looked(_ camera: BoardCamera, by translation: CGSize) -> BoardCamera {
        var result = camera
        result.yawDegrees = ((camera.yawDegrees ?? 0) - Double(translation.width) * 0.25).truncatingRemainder(dividingBy: 360)
        result.pitchDegrees = min(pitchRange.upperBound, max(pitchRange.lowerBound, (camera.pitchDegrees ?? -15) + Double(translation.height) * 0.2))
        return result
    }

    /// Moves the eye `forward` and `right` metres relative to the look direction, clamped to the field margin.
    static func moved(_ camera: BoardCamera, field: BoardFieldType, forward: Double, right: Double) -> BoardCamera {
        guard let eye = camera.eye else { return camera }
        let yaw = (camera.yawDegrees ?? 0) * .pi / 180
        let dx = cos(yaw) * forward - sin(yaw) * right
        let dz = sin(yaw) * forward + cos(yaw) * right
        var result = camera
        result.eye = clampedEye(BoardPoint(eye.x + dx / Double(field.meters.width), eye.y + dz / Double(field.meters.height)))
        return result
    }

    /// Pinch: spreading the fingers (factor > 1) lowers the eye.
    static func raised(_ camera: BoardCamera, by factor: Double) -> BoardCamera {
        var result = camera
        result.eyeHeightMeters = clampedHeight((camera.eyeHeightMeters ?? 1.7) / max(0.01, factor))
        return result
    }

    /// Walking speed for the joystick and two-finger move: faster when high up and on big fields.
    static func speed(_ camera: BoardCamera, field: BoardFieldType) -> Double {
        let size = Double(max(field.meters.width, field.meters.height))
        return max(3, min(40, size * 0.12 + (camera.eyeHeightMeters ?? 1.7) * 0.8))
    }

    /// A raised view from behind the goal nearest to `near` (or the u = 0 end), looking up the field.
    static func reset(_ base: BoardCamera, field: BoardFieldType, near: BoardPoint?) -> BoardCamera {
        var camera = base
        camera.mode = .free
        camera.subjectID = nil
        let size = Double(max(field.meters.width, field.meters.height))
        let height = min(22, max(4, size * 0.11))
        camera.eyeHeightMeters = height
        camera.fieldOfViewDegrees = BoardCameraResolver.freeFieldOfView
        if field == .footballHalf {
            camera.eye = BoardPoint(0.5, -0.08)
            camera.yawDegrees = 90
            camera.pitchDegrees = -atan(height / (Double(field.meters.height) * 0.55)) * 180 / .pi
        } else {
            let farEnd = (near?.x ?? 0) > 0.5
            camera.eye = BoardPoint(farEnd ? 1.08 : -0.08, 0.5)
            camera.yawDegrees = farEnd ? 180 : 0
            camera.pitchDegrees = -atan(height / (Double(field.meters.width) * 0.55)) * 180 / .pi
        }
        return camera
    }
}
