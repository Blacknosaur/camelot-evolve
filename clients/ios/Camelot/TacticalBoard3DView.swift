import Metal
import SceneKit
import SwiftUI

/// Real 3D view of a board, rendered with SceneKit. Three camera modes (see `BoardCameraMode`):
/// - Orbit: one finger orbits (or drags an element), pinch zooms toward the fingers, two fingers pan,
///   double tap resets to the preset.
/// - Free: one finger looks around, the joystick or two fingers walk, pinch changes eye height,
///   double tap goes behind the nearest goal.
/// - Point of view: through an element's eyes; one finger looks around and springs back (unless the
///   look direction is fixed). The editor enters it by writing `camera.pointOfView(subject:)` into
///   the binding; the view glides there in 0.5 s.
/// Tap selects and dragging an element moves it in every mode. Camera changes reach the binding
/// when a gesture ends, so stage camera keys capture any mode.
struct TacticalBoard3DView: View {
    let document: BoardDocument
    /// Playback time for animated boards; nil shows the editable layout.
    let time: Double?
    let selectedID: UUID?
    @Binding var camera: BoardCamera
    /// Tap on an element (nil when tapping empty ground).
    var onSelect: (UUID?) -> Void = { _ in }
    /// Drag of an element along the ground; `ended` is true on release (record history then).
    var onMove: (_ id: UUID, _ position: BoardPoint, _ ended: Bool) -> Void = { _, _, _ in }
    /// Animation frame being edited: shows translucent previous/next poses (only without playback).
    var onionFrame: Int? = nil
    /// Room kept clear for the editor's own chrome around the camera controls.
    var controlsInsets = EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12)

    @State private var controller = Board3DCameraController()

    var body: some View {
        Board3DSceneView(document: document, time: time, selectedID: selectedID, camera: $camera, onSelect: onSelect, onMove: onMove,
                         onionFrame: time == nil ? onionFrame : nil, controller: controller)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("3D board")
            // Deliberately not `elements(at:)`: the body is re-evaluated on every playback tick.
            .accessibilityValue(controller.profile ?? "\(document.elements.count) elements")
            .accessibilityIdentifier("board-3d-view")
            .overlay(alignment: .topTrailing) {
                Board3DCameraControls(controller: controller)
                    .padding(.top, controlsInsets.top)
                    .padding(.trailing, controlsInsets.trailing)
            }
            .overlay(alignment: .bottomLeading) {
                if controller.mode == .free && !controller.isPlaying {
                    Board3DJoystick { controller.joystick($0) }
                        .padding(.leading, controlsInsets.leading)
                        .padding(.bottom, controlsInsets.bottom)
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.25), value: controller.mode)
    }
}

struct Board3DSceneView: UIViewRepresentable {
    let document: BoardDocument
    let time: Double?
    let selectedID: UUID?
    @Binding var camera: BoardCamera
    let onSelect: (UUID?) -> Void
    let onMove: (UUID, BoardPoint, Bool) -> Void
    let onionFrame: Int?
    var controller: Board3DCameraController? = nil

    func makeCoordinator() -> Board3DCoordinator { Board3DCoordinator() }

    func makeUIView(context: Context) -> Board3DSCNView {
        let coordinator = context.coordinator
        coordinator.parent = self
        let view = Board3DSCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.scene = coordinator.builder.scene
        view.pointOfView = coordinator.builder.cameraNode
        view.antialiasingMode = Board3DQuality.current.antialiasing
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.isJitteringEnabled = false
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.onLayout = { [weak coordinator] in coordinator?.layoutChanged() }
        coordinator.attach(view)
        coordinator.update(from: self)
        view.backgroundColor = coordinator.builder.backgroundColor
        return view
    }

    func updateUIView(_ view: Board3DSCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(from: self)
    }
}

/// Holds a notification observer and removes it when its owner goes away.
final class ObserverToken {
    private let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

final class Board3DSCNView: SCNView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

@MainActor
final class Board3DCoordinator: NSObject, UIGestureRecognizerDelegate, SCNSceneRendererDelegate {
    let builder = TacticalBoard3DScene()
    var parent: Board3DSceneView?
    private weak var view: Board3DSCNView?
    private weak var controller: Board3DCameraController?

    private var document = BoardDocument()
    private var time: Double?
    private var selectedID: UUID?
    private var hasDocument = false
    /// Camera currently shown; the binding only receives it when a gesture ends.
    private var liveCamera = BoardViewAngle.tilted.defaultCamera
    private var boundCamera: BoardCamera?
    private var activeGestures = 0
    /// Orbit framing for the current angle and viewport; nil re-solves it. Kept fixed during gestures.
    private var framing: BoardFraming?
    private var framedViewport: CGSize = .zero
    /// True while the next tap chooses the point-of-view focus target.
    private(set) var pickingFocus = false
    /// Temporary point-of-view look-around (degrees), sprung back when the finger lifts.
    private var lookOffset = (yaw: 0.0, pitch: 0.0)
    /// Last pose put on screen.
    private(set) var currentPose: BoardViewPose?

    private var gestureStart = BoardViewAngle.tilted.defaultCamera
    private var drag: (id: UUID, grip: SIMD3<Double>, start: BoardPoint)?
    private var panLocation: CGPoint?
    private var joystickVector = CGPoint.zero
    private var joystickLink: CADisplayLink?
    private var joystickTimestamp: CFTimeInterval?
    private var photoObserver: ObserverToken?

    private func photosWarmed() {
        guard hasDocument else { return }
        builder.update(document: document, time: time, selectedID: selectedID)
        view?.setNeedsDisplay()
    }

    /// True while playback drives the camera; camera gestures are ignored then.
    private(set) var playingCamera = false
    var appliedCamera: BoardCamera { liveCamera }
    private var viewport: CGSize { view?.bounds.size ?? .zero }

    // MARK: Profiling (launch with -board3dProfile)

    /// Frame intervals and per-frame work. SceneKit calls the render delegate on its own thread, so
    /// the log is lock-protected and the summary is published from the main actor.
    private final class FrameLog: @unchecked Sendable {
        private let lock = NSLock()
        private var intervals: [Double] = []
        private var lastFrame: CFTimeInterval?
        var swiftUIUpdates = 0
        var sceneUpdates = 0
        var poseUpdates = 0

        func record(_ time: CFTimeInterval) {
            lock.lock()
            if let lastFrame { intervals.append((time - lastFrame) * 1000) }
            lastFrame = time
            lock.unlock()
        }

        /// Frame intervals since the last call, sorted.
        func drain() -> [Double] {
            lock.lock()
            let values = intervals.sorted()
            intervals.removeAll(keepingCapacity: true)
            lock.unlock()
            return values
        }
    }

    private let profiling = ProcessInfo.processInfo.arguments.contains("-board3dProfile")
    private let frameLog = FrameLog()
    private var lastProfileReport = CACurrentMediaTime()

    nonisolated func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        frameLog.record(time)
    }

    /// Publishes a one-second summary (only with -board3dProfile).
    private func publishProfile() {
        guard profiling else { return }
        let now = CACurrentMediaTime()
        guard now - lastProfileReport > 1 else { return }
        lastProfileReport = now
        let sorted = frameLog.drain()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let text = String(format: "fps %.0f | frame med %.1f p95 %.1f max %.1f ms | frames %d swiftui %d scene %d pose %d",
                          median > 0 ? 1000 / median : 0, median, p95, sorted.last ?? 0, sorted.count,
                          frameLog.swiftUIUpdates, frameLog.sceneUpdates, frameLog.poseUpdates)
        frameLog.swiftUIUpdates = 0; frameLog.sceneUpdates = 0; frameLog.poseUpdates = 0
        controller?.setProfile(text)
    }

    func attach(_ view: Board3DSCNView) {
        self.view = view
        if profiling { view.delegate = self }
        // A squad photo that was not decoded yet is warmed off the main thread; rebuild the nodes
        // that were drawn without it once it lands.
        photoObserver = ObserverToken(NotificationCenter.default.addObserver(forName: SquadPhotoStore.didWarmPhoto, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.photosWarmed() }
        })
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let oneFinger = UIPanGestureRecognizer(target: self, action: #selector(handleOneFinger(_:)))
        oneFinger.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFinger(_:)))
        pan.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        for recognizer in [tap, doubleTap, oneFinger, pan, pinch] {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
    }

    func update(from representable: Board3DSceneView) {
        frameLog.swiftUIUpdates += 1
        publishProfile()
        if let controller = representable.controller, controller !== self.controller {
            self.controller = controller
            controller.coordinator = self
        }
        let newDocument = representable.document
        var contentChanged = false
        var fieldChanged = false
        if !hasDocument || newDocument != document || representable.time != time || representable.selectedID != selectedID {
            fieldChanged = newDocument.fieldType != document.fieldType || !hasDocument
            document = newDocument
            time = representable.time
            selectedID = representable.selectedID
            hasDocument = true
            frameLog.sceneUpdates += 1
            builder.update(document: document, time: time, selectedID: selectedID)
            view?.backgroundColor = builder.backgroundColor
            if fieldChanged { framing = nil }
            contentChanged = true
        }
        let subjectLost = clearDanglingSubject()
        updateOnionSkin(frame: representable.onionFrame)
        let binding = representable.camera
        // Playback with an animated camera drives SceneKit from the camera track, not the binding.
        if let time, Board3DCameraTrack.animates(document) {
            playingCamera = true
            boundCamera = binding
            stopJoystick()
            if viewport.width > 0, viewport.height > 0 {
                show(BoardCameraResolver.pose(for: document, time: time, viewport: viewport), animated: false)
            }
            publish()
            return
        }
        if playingCamera {
            // Playback stopped: settle onto the editor's camera.
            playingCamera = false
            boundCamera = binding
            liveCamera = binding
            lookOffset = (0, 0)
            framing = nil
            applyCamera(duration: 0.35)
            return
        }
        if boundCamera != binding {
            let first = boundCamera == nil
            let modeChanged = boundCamera.map { $0.resolvedMode != binding.resolvedMode || $0.subjectID != binding.subjectID } ?? false
            boundCamera = binding
            if activeGestures == 0 && binding != liveCamera {
                liveCamera = binding
                lookOffset = (0, 0)
                framing = nil
                applyCamera(duration: first ? 0 : (modeChanged ? 0.5 : 0.35))
                return
            }
        }
        // Point of view follows its subject as the document or playback time changes, and a new
        // field type needs a fresh fit even in orbit (full pitch -> futsal keeps the old framing).
        if (contentChanged && (fieldChanged || !liveCamera.isOrbit || currentPose == nil)) || subjectLost {
            applyCamera(duration: (fieldChanged || subjectLost) && currentPose != nil ? 0.35 : 0)
        }
    }

    /// The point-of-view subject was deleted: the resolver already falls back, but the camera (and
    /// the chrome the controller draws from it) would stay in point-of-view mode for ever. Drop the
    /// dangling id here; the binding gets the cleaned camera the next time a gesture commits.
    private func clearDanglingSubject() -> Bool {
        guard liveCamera.resolvedMode == .pointOfView, let subject = liveCamera.subjectID,
              !document.elements(at: time).contains(where: { $0.id == subject }) else { return false }
        liveCamera.mode = liveCamera.hasFreePose ? .free : .orbit
        liveCamera.subjectID = nil
        liveCamera.lookAt = nil
        lookOffset = (0, 0)
        framing = nil
        return true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard playingCamera else { return true }
        return (recognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 1
    }

    /// Layout passes happen for many reasons (overlays, safe area, keyboard); only a new size
    /// re-applies the camera, so an in-flight camera animation is never snapped.
    func layoutChanged() {
        let size = viewport
        guard abs(framedViewport.width - size.width) > 0.5 || abs(framedViewport.height - size.height) > 0.5 else { return }
        applyCamera(duration: 0)
    }

    private var onionKey: (frame: Int, document: BoardDocument)?

    /// Ghosts are rebuilt only when the frame, the toggle or the document changes.
    private func updateOnionSkin(frame: Int?) {
        guard let frame, document.keyframes.indices.contains(frame) else {
            if onionKey != nil { builder.clearGhosts(); onionKey = nil }
            return
        }
        if let key = onionKey, key.frame == frame, key.document == document { return }
        onionKey = (frame, document)
        let skin = document.onionSkin(aroundFrame: frame)
        builder.updateGhosts(previous: skin.previous, next: skin.next, live: document.elements(at: nil))
    }

    // MARK: Camera

    /// The pose for `liveCamera` (orbit framing kept stable; point of view with any look-around).
    private func resolvedPose() -> BoardViewPose? {
        let viewport = self.viewport
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let resized = abs(framedViewport.width - viewport.width) > 0.5 || abs(framedViewport.height - viewport.height) > 0.5
        if framing == nil || resized {
            framing = BoardOrbit.framing(field: document.fieldType, camera: liveCamera.orbiting, viewport: viewport)
            framedViewport = viewport
        }
        var pose = BoardCameraResolver.pose(liveCamera, in: document, time: time, viewport: viewport, framing: framing)
        if liveCamera.resolvedMode == .pointOfView, lookOffset != (0, 0) {
            pose = pose.lookingAround(yaw: lookOffset.yaw, pitch: lookOffset.pitch)
        }
        return pose
    }

    func applyCamera(duration: Double) {
        guard let pose = resolvedPose() else { return }
        show(pose, animated: duration > 0, duration: duration)
        publish()
    }

    private func show(_ pose: BoardViewPose, animated: Bool, duration: Double = 0.35) {
        frameLog.poseUpdates += 1
        publishProfile()
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = duration
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            builder.applyPose(pose, viewport: viewport)
            SCNTransaction.commit()
        } else {
            builder.applyPose(pose, viewport: viewport)
        }
        currentPose = pose
    }

    private func commitCamera() {
        guard activeGestures == 0 else { return }
        boundCamera = liveCamera
        parent?.camera = liveCamera
        publish()
    }

    /// Switches camera (from the overlay controls) with a smooth transition and commits it.
    func request(_ camera: BoardCamera) {
        guard !playingCamera else { return }
        stopJoystick()
        let modeChanged = camera.resolvedMode != liveCamera.resolvedMode || camera.subjectID != liveCamera.subjectID
        liveCamera = camera
        lookOffset = (0, 0)
        framing = nil
        applyCamera(duration: modeChanged ? 0.5 : 0.35)
        commitCamera()
    }

    /// Current camera converted for a mode switch.
    func camera(for mode: BoardCameraMode) -> BoardCamera {
        switch mode {
        case .orbit: return liveCamera.orbiting
        case .free:
            guard let pose = currentPose ?? resolvedPose() else { return liveCamera }
            return BoardFreeCamera.camera(from: pose, base: liveCamera, field: document.fieldType)
        case .pointOfView: return liveCamera
        }
    }

    /// A point-of-view camera on `subject` that remembers the current view as its fallback free pose.
    func pointOfView(on subject: UUID) -> BoardCamera {
        var base = liveCamera
        if let pose = currentPose ?? resolvedPose(), liveCamera.resolvedMode != .pointOfView {
            base = BoardFreeCamera.camera(from: pose, base: liveCamera, field: document.fieldType)
        }
        var camera = base.pointOfView(subject: subject, lookAt: liveCamera.subjectID == subject ? (liveCamera.lookAt ?? .facing) : .facing)
        camera.fieldOfViewDegrees = nil
        return camera
    }

    func armFocusPicking() {
        pickingFocus = liveCamera.resolvedMode == .pointOfView
        publish()
    }

    func setLookAt(_ lookAt: BoardCameraLookAt) {
        pickingFocus = false
        guard liveCamera.resolvedMode == .pointOfView else { return }
        var camera = liveCamera
        if case .fixed = lookAt, let pose = currentPose {
            camera.lookAt = .fixed(yawDegrees: BoardViewPose.angles(of: pose.forward).yaw)
        } else {
            camera.lookAt = lookAt
        }
        request(camera)
    }

    func title(of id: UUID) -> String? {
        guard let element = document.elements(at: time).first(where: { $0.id == id }) else { return nil }
        if !element.label.isEmpty { return element.label }
        if let number = element.number { return "#\(number)" }
        switch element.kind {
        case .referee: return "Referee"
        case .coach: return "Coach"
        case .goalkeeper: return "Keeper"
        case .ball: return "Ball"
        default: return element.kind.rawValue.capitalized
        }
    }

    private func publish() {
        var focus: String?
        if case .element(let id) = liveCamera.lookAt ?? .facing { focus = title(of: id) ?? "target" }
        controller?.sync(mode: playingCamera ? (currentPose?.hiddenSubjects.isEmpty == false ? .pointOfView : .orbit) : liveCamera.resolvedMode,
                         subject: liveCamera.subjectID.flatMap { title(of: $0) },
                         lookAt: liveCamera.lookAt ?? .facing,
                         playing: playingCamera, focus: focus, picking: pickingFocus)
    }

    // MARK: Joystick

    func joystick(_ vector: CGPoint?) {
        guard liveCamera.resolvedMode == .free, !playingCamera else { return }
        guard let vector, hypot(vector.x, vector.y) > 0.05 else { stopJoystick(); return }
        joystickVector = vector
        if joystickLink == nil {
            gestureBegan()
            let link = CADisplayLink(target: self, selector: #selector(joystickTick(_:)))
            link.add(to: .main, forMode: .common)
            joystickLink = link
            joystickTimestamp = nil
        }
    }

    private func stopJoystick() {
        guard let link = joystickLink else { return }
        link.invalidate()
        joystickLink = nil
        joystickVector = .zero
        gestureEnded()
    }

    @objc private func joystickTick(_ link: CADisplayLink) {
        let dt = min(0.05, joystickTimestamp.map { link.timestamp - $0 } ?? 1 / 60)
        joystickTimestamp = link.timestamp
        let speed = BoardFreeCamera.speed(liveCamera, field: document.fieldType)
        liveCamera = BoardFreeCamera.moved(liveCamera, field: document.fieldType, forward: -Double(joystickVector.y) * speed * dt, right: Double(joystickVector.x) * speed * dt)
        applyCamera(duration: 0)
    }

    private func gestureBegan() {
        activeGestures += 1
        view?.rendersContinuously = true
    }

    private func gestureEnded() {
        activeGestures = max(0, activeGestures - 1)
        if activeGestures == 0 { view?.rendersContinuously = false }
        commitCamera()
    }

    // MARK: Hit testing

    private func elementID(at point: CGPoint) -> UUID? {
        guard let view else { return nil }
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true, .categoryBitMask: TacticalBoard3DScene.elementCategory])
        for hit in hits {
            if let id = builder.elementID(of: hit.node) { return id }
        }
        // Small or distant figures: accept a tap near their projected centre.
        guard let pose = currentPose else { return nil }
        let scale = BoardOrbit.figureScale(document.fieldType)
        var best: (UUID, CGFloat)?
        for element in document.elements(at: time) where element.kind.isPoint && !pose.hiddenSubjects.contains(element.id) {
            let world = BoardOrbit.world(element.position, field: document.fieldType, y: element.kind.isPerson ? 0.9 * scale : 0.2)
            guard let screen = pose.project(world, viewport: viewport) else { continue }
            let distance = hypot(screen.x - point.x, screen.y - point.y)
            if distance < 30, distance < (best?.1 ?? .infinity) { best = (element.id, distance) }
        }
        return best?.0
    }

    private func groundPoint(at point: CGPoint) -> SIMD3<Double>? {
        currentPose?.groundPoint(at: point, viewport: viewport)
    }

    // MARK: Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let twoFinger: (UIGestureRecognizer) -> Bool = { $0 is UIPinchGestureRecognizer || (($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches ?? 0) >= 2 }
        return twoFinger(gestureRecognizer) && twoFinger(other)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let id = elementID(at: recognizer.location(in: view))
        // Focus picking: the next tap on an element becomes the point-of-view look-at target.
        if pickingFocus, liveCamera.resolvedMode == .pointOfView, let id, id != liveCamera.subjectID {
            pickingFocus = false
            var camera = liveCamera
            camera.lookAt = .element(id)
            request(camera)
            return
        }
        pickingFocus = false
        parent?.onSelect(id)
        // In point of view, tapping another figure offers to look through its eyes.
        if liveCamera.resolvedMode == .pointOfView, let id, id != liveCamera.subjectID,
           let element = document.elements(at: time).first(where: { $0.id == id }), element.kind.isPerson || element.kind.isStaff {
            controller?.offer(id: id, title: title(of: id) ?? "player")
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        switch liveCamera.resolvedMode {
        case .orbit:
            var camera = document.viewAngle.defaultCamera
            camera.mode = nil
            request(camera)
        case .free:
            let near = currentPose.map { BoardOrbit.board($0.eye, field: document.fieldType) }
            request(BoardFreeCamera.reset(liveCamera, field: document.fieldType, near: near))
        case .pointOfView:
            lookOffset = (0, 0)
            applyCamera(duration: 0.35)
        }
    }

    @objc private func handleOneFinger(_ recognizer: UIPanGestureRecognizer) {
        guard let view else { return }
        let location = recognizer.location(in: view)
        let translation = recognizer.translation(in: view)
        switch recognizer.state {
        case .began:
            gestureBegan()
            gestureStart = liveCamera
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            if let id = elementID(at: start), let element = document.elements(at: time).first(where: { $0.id == id }),
               let grip = groundPoint(at: start) {
                drag = (id, grip, element.position)
                if id != selectedID { parent?.onSelect(id) }
            }
        case .changed:
            if let drag {
                guard let ground = groundPoint(at: location) else { return }
                parent?.onMove(drag.id, moved(drag, to: ground), false)
                return
            }
            let size = CGSize(width: translation.x, height: translation.y)
            switch liveCamera.resolvedMode {
            case .orbit:
                liveCamera = BoardOrbit.orbited(gestureStart, by: size)
            case .free:
                liveCamera = BoardFreeCamera.looked(gestureStart, by: size)
            case .pointOfView:
                if case .fixed(let yaw) = gestureStart.lookAt {
                    liveCamera.lookAt = .fixed(yawDegrees: yaw - Double(size.width) * 0.25)
                    lookOffset = (0, min(60, max(-60, Double(size.height) * 0.2)))
                } else {
                    lookOffset = (-Double(size.width) * 0.25, min(60, max(-60, Double(size.height) * 0.2)))
                }
            }
            applyCamera(duration: 0)
        case .ended, .cancelled, .failed:
            if let drag {
                let ground = groundPoint(at: location) ?? drag.grip
                parent?.onMove(drag.id, moved(drag, to: ground), true)
                self.drag = nil
            } else if liveCamera.isOrbit {
                // The angle changed: settle into a fresh fit for it, smoothly, once the finger lifts.
                framing = nil
                applyCamera(duration: 0.35)
            } else if liveCamera.resolvedMode == .pointOfView {
                // Look-around springs back; a fixed look keeps its new direction but levels out.
                lookOffset = (0, 0)
                applyCamera(duration: 0.35)
            }
            gestureEnded()
        default:
            break
        }
    }

    private func moved(_ drag: (id: UUID, grip: SIMD3<Double>, start: BoardPoint), to ground: SIMD3<Double>) -> BoardPoint {
        let delta = BoardOrbit.board(ground, field: document.fieldType)
        let origin = BoardOrbit.board(drag.grip, field: document.fieldType)
        return BoardPoint(drag.start.x + delta.x - origin.x, drag.start.y + delta.y - origin.y).clamped()
    }

    @objc private func handleTwoFinger(_ recognizer: UIPanGestureRecognizer) {
        guard let view else { return }
        let location = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            gestureBegan()
            panLocation = location
        case .changed:
            if let previous = panLocation, recognizer.numberOfTouches >= 2 {
                switch liveCamera.resolvedMode {
                case .orbit:
                    liveCamera = BoardOrbit.panned(liveCamera, field: document.fieldType, viewport: viewport, framing: framing, from: previous, to: location)
                case .free:
                    // Pull the ground: dragging down walks forward, sideways strafes.
                    let metresPerPoint = BoardFreeCamera.speed(liveCamera, field: document.fieldType) / 320
                    liveCamera = BoardFreeCamera.moved(liveCamera, field: document.fieldType,
                                                       forward: Double(location.y - previous.y) * metresPerPoint,
                                                       right: -Double(location.x - previous.x) * metresPerPoint)
                case .pointOfView:
                    break
                }
                applyCamera(duration: 0)
            }
            panLocation = location
        case .ended, .cancelled, .failed:
            panLocation = nil
            gestureEnded()
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let view else { return }
        switch recognizer.state {
        case .began:
            gestureBegan()
        case .changed:
            switch liveCamera.resolvedMode {
            case .orbit:
                liveCamera = BoardOrbit.zoomed(liveCamera, field: document.fieldType, viewport: view.bounds.size, framing: framing, by: Double(recognizer.scale), anchor: recognizer.location(in: view))
            case .free:
                liveCamera = BoardFreeCamera.raised(liveCamera, by: Double(recognizer.scale))
            case .pointOfView:
                break
            }
            recognizer.scale = 1
            applyCamera(duration: 0)
        case .ended, .cancelled, .failed:
            gestureEnded()
        default:
            break
        }
    }
}

// MARK: - Camera controls

/// Bridge between the SwiftUI camera controls and the SceneKit coordinator.
@MainActor @Observable
final class Board3DCameraController {
    @ObservationIgnored weak var coordinator: Board3DCoordinator?
    private(set) var mode: BoardCameraMode = .orbit
    private(set) var subjectTitle: String?
    private(set) var lookAt: BoardCameraLookAt = .facing
    private(set) var isPlaying = false
    /// Name or number of the focused element, and whether the next tap picks one.
    private(set) var focusTitle: String?
    private(set) var isPickingFocus = false
    /// "View from …" suggestion after tapping another figure in point of view.
    private(set) var offer: (id: UUID, title: String)?
    /// Live profile text (only with -board3dProfile), surfaced as the view's accessibility value.
    private(set) var profile: String?

    func setProfile(_ text: String) { profile = text }
    @ObservationIgnored private var offerTask: Task<Void, Never>?

    func sync(mode: BoardCameraMode, subject: String?, lookAt: BoardCameraLookAt, playing: Bool, focus: String?, picking: Bool) {
        if self.mode != mode { self.mode = mode }
        if subjectTitle != subject { subjectTitle = subject }
        if self.lookAt != lookAt { self.lookAt = lookAt }
        if isPlaying != playing { isPlaying = playing }
        if focusTitle != focus { focusTitle = focus }
        if isPickingFocus != picking { isPickingFocus = picking }
    }

    func armFocusPicking() { coordinator?.armFocusPicking() }

    func select(_ mode: BoardCameraMode) {
        guard let coordinator else { return }
        coordinator.request(coordinator.camera(for: mode))
    }

    func setLookAt(_ lookAt: BoardCameraLookAt) { coordinator?.setLookAt(lookAt) }

    func viewFrom(_ id: UUID) {
        guard let coordinator else { return }
        offer = nil
        coordinator.request(coordinator.pointOfView(on: id))
    }

    func offer(id: UUID, title: String) {
        offer = (id, title)
        offerTask?.cancel()
        offerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.offer = nil
        }
    }

    func joystick(_ vector: CGPoint?) { coordinator?.joystick(vector) }
}

/// Compact glass controls: Orbit | Free, the point-of-view chip with ✕, and its look-at choice.
struct Board3DCameraControls: View {
    let controller: Board3DCameraController

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                if controller.mode == .pointOfView {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill").font(.caption.weight(.semibold))
                        Text(controller.subjectTitle ?? "View").font(.footnote.weight(.semibold)).lineLimit(1)
                        Button {
                            controller.select(.orbit)
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 22, height: 22)
                        }
                        .accessibilityLabel("Exit point of view")
                        .accessibilityIdentifier("board-camera-pov-exit")
                    }
                    .padding(.leading, 10).padding(.trailing, 4).frame(height: 32)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                HStack(spacing: 2) {
                    modeButton(.orbit, symbol: "rotate.3d", title: "Orbit")
                    modeButton(.free, symbol: "figure.walk", title: "Free")
                }
                .padding(2)
                .background(.ultraThinMaterial, in: Capsule())
            }
            if controller.mode == .pointOfView {
                HStack(spacing: 2) {
                    lookButton("Facing", value: .facing, active: controller.lookAt == .facing, id: "facing")
                    lookButton("Ball", value: .ball, active: controller.lookAt == .ball, id: "ball")
                    lookButton("Free look", value: .fixed(yawDegrees: 0), active: { if case .fixed = controller.lookAt { return true } else { return false } }(), id: "fixed")
                    focusButton
                }
                .padding(2)
                .background(.ultraThinMaterial, in: Capsule())
            }
            if let offer = controller.offer {
                Button {
                    controller.viewFrom(offer.id)
                } label: {
                    Label("View from \(offer.title)", systemImage: "eye")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .accessibilityIdentifier("board-camera-view-from")
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
            }
        }
        .foregroundStyle(.primary)
        .environment(\.colorScheme, .dark)
        .disabled(controller.isPlaying)
        .opacity(controller.isPlaying ? 0.5 : 1)
        .animation(.snappy(duration: 0.25), value: controller.offer?.id)
        .animation(.snappy(duration: 0.25), value: controller.mode)
    }

    /// Focus: arms picking, then shows the chosen element with a ✕ to clear it.
    @ViewBuilder private var focusButton: some View {
        if let focus = controller.focusTitle {
            HStack(spacing: 4) {
                Text("Focus \(focus)").font(.caption.weight(.semibold)).lineLimit(1)
                Button { controller.setLookAt(.facing) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                }
                .accessibilityLabel("Clear focus")
                .accessibilityIdentifier("board-camera-focus-clear")
            }
            .padding(.leading, 10).padding(.trailing, 2).frame(height: 26)
            .background(.white.opacity(0.22), in: Capsule())
        } else {
            Button { controller.armFocusPicking() } label: {
                Text(controller.isPickingFocus ? "Tap an item" : "Focus")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(controller.isPickingFocus ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.clear), in: Capsule())
            }
            .accessibilityIdentifier("board-camera-focus")
        }
    }

    private func modeButton(_ mode: BoardCameraMode, symbol: String, title: String) -> some View {
        let active = controller.mode == mode
        return Button {
            controller.select(mode)
        } label: {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .frame(width: 36, height: 28)
                .background(active ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.clear), in: Capsule())
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("board-camera-mode-\(mode.rawValue)")
    }

    private func lookButton(_ title: String, value: BoardCameraLookAt, active: Bool, id: String) -> some View {
        Button {
            controller.setLookAt(value)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).frame(height: 26)
                .background(active ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.clear), in: Capsule())
        }
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("board-camera-look-\(id)")
    }
}

/// Virtual thumbstick for walking in free mode; reports a vector in -1…1 (nil when released).
struct Board3DJoystick: View {
    let onChange: (CGPoint?) -> Void
    @State private var knob = CGSize.zero
    private let radius: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1)
            Circle().fill(.white.opacity(0.85)).frame(width: 34, height: 34).offset(knob)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        }
        .frame(width: radius * 2, height: radius * 2)
        .environment(\.colorScheme, .dark)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let length = hypot(value.translation.width, value.translation.height)
                    let limit = radius - 17
                    let factor = length > limit ? limit / length : 1
                    knob = CGSize(width: value.translation.width * factor, height: value.translation.height * factor)
                    onChange(CGPoint(x: knob.width / limit, y: knob.height / limit))
                }
                .onEnded { _ in
                    withAnimation(.snappy(duration: 0.2)) { knob = .zero }
                    onChange(nil)
                }
        )
        .accessibilityLabel("Walk")
        .accessibilityIdentifier("board-camera-joystick")
    }
}

// MARK: - Camera track

/// Whether playback drives the camera from stage keys (see `BoardCameraResolver.pose(for:time:viewport:)`).
enum Board3DCameraTrack {
    static func animates(_ document: BoardDocument) -> Bool {
        document.viewAngle.is3D && document.animatesCamera
    }
}

// MARK: - Offscreen rendering

/// Offscreen 3D rendering for thumbnails and exports. Callable from any thread; calls are serialised.
enum TacticalBoard3DRenderer {
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var renderer: TacticalBoard3DOffscreen?
    }

    private static let shared = Shared()

    /// A SceneKit renderer plus its whole scene is expensive to keep for the life of the process:
    /// drop it under memory pressure and build a new one on the next render.
    nonisolated(unsafe) private static let memoryWarningObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
    ) { _ in
        shared.lock.lock()
        shared.renderer = nil
        shared.lock.unlock()
    }

    /// Renders one frame of the 3D scene at `size` points × `scale`.
    static func image(document: BoardDocument, time: Double?, size: CGSize, scale: CGFloat) -> CGImage? {
        _ = memoryWarningObserver
        shared.lock.lock()
        defer { shared.lock.unlock() }
        if shared.renderer == nil { shared.renderer = TacticalBoard3DOffscreen() }
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        return shared.renderer?.image(document: document, time: time, pixelSize: pixels)
    }
}

/// One SceneKit renderer plus scene. Reuse it across frames: only transforms change per frame.
final class TacticalBoard3DOffscreen {
    let builder = TacticalBoard3DScene()
    private let renderer: SCNRenderer

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = builder.scene
        renderer.pointOfView = builder.cameraNode
        renderer.autoenablesDefaultLighting = false
        builder.loadsPhotosSynchronously = true
    }

    /// `onionFrame` is for previews and tests only; exports leave it nil, which never shows ghosts.
    func image(document: BoardDocument, time: Double?, pixelSize: CGSize, selectedID: UUID? = nil, onionFrame: Int? = nil) -> CGImage? {
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        builder.update(document: document, time: time, selectedID: selectedID)
        if let onionFrame, time == nil, document.keyframes.indices.contains(onionFrame) {
            let skin = document.onionSkin(aroundFrame: onionFrame)
            builder.updateGhosts(previous: skin.previous, next: skin.next, live: document.elements(at: nil))
        } else {
            builder.clearGhosts()
        }
        // Every camera mode, blended stage keys and point-of-view following; the subject stays hidden.
        builder.applyPose(BoardCameraResolver.pose(for: document, time: time, viewport: pixelSize), viewport: pixelSize)
        SCNTransaction.commit()
        let image = renderer.snapshot(atTime: 0, with: pixelSize, antialiasingMode: .multisampling4X)
        return image.cgImage
    }
}
