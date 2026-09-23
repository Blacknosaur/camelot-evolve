import SceneKit
import UIKit
import simd

// MARK: - Orbit camera maths

/// How a camera angle frames the field in a viewport: the distance at `distanceScale` 1 and a
/// sideways/vertical eye offset (in camera-plane units per metre of distance) that centres the
/// projected field. It is solved once per preset, viewport or gesture end, not per frame, so
/// orbiting does not make the camera breathe in and out.
struct BoardFraming: Equatable, Sendable {
    var distance: Double
    var offsetX: Double = 0
    var offsetY: Double = 0
}

/// Pure orbit-camera maths shared by the interactive view, offscreen renderer and tests.
/// World units are metres: x along the field length (`meters.width`), z along its width
/// (`meters.height`), y up, with the field centred on the origin.
struct BoardOrbit: Sendable {
    static let fieldOfViewDegrees = 34.0
    static let elevationRange = 12.0...89.0
    static let distanceScaleRange = 0.15...2.2
    /// Fraction of the half viewport the framed field may fill.
    static let fillX = 0.95, fillY = 0.93

    let field: BoardFieldType
    let camera: BoardCamera
    let viewport: CGSize
    let framing: BoardFraming
    let tanHalfWidth: Double
    let tanHalfHeight: Double
    let forward: SIMD3<Double>
    let right: SIMD3<Double>
    let up: SIMD3<Double>
    let distance: Double
    let target: SIMD3<Double>
    let eye: SIMD3<Double>

    /// `framing` nil solves it for this camera angle and viewport.
    init(field: BoardFieldType, camera: BoardCamera, viewport: CGSize, framing: BoardFraming? = nil) {
        self.field = field
        let camera = BoardOrbit.clamped(camera)
        self.camera = camera
        let viewport = CGSize(width: max(1, viewport.width), height: max(1, viewport.height))
        self.viewport = viewport
        (tanHalfWidth, tanHalfHeight) = BoardOrbit.tangents(aspect: Double(viewport.width / viewport.height))
        (forward, right, up) = BoardOrbit.basis(field: field, azimuth: camera.azimuthDegrees, elevation: camera.elevationDegrees, viewport: viewport)
        let framing = framing ?? BoardOrbit.framing(field: field, camera: camera, viewport: viewport)
        self.framing = framing
        distance = framing.distance * camera.distanceScale
        target = BoardOrbit.world(camera.target, field: field)
        eye = target - forward * distance + (right * framing.offsetX + up * framing.offsetY) * distance
    }

    static func clamped(_ camera: BoardCamera) -> BoardCamera {
        var result = camera
        result.elevationDegrees = min(elevationRange.upperBound, max(elevationRange.lowerBound, camera.elevationDegrees))
        result.distanceScale = min(distanceScaleRange.upperBound, max(distanceScaleRange.lowerBound, camera.distanceScale))
        result.azimuthDegrees = camera.azimuthDegrees.truncatingRemainder(dividingBy: 360)
        result.target = camera.target.clamped()
        return result
    }

    /// The fixed angle is the shorter viewport side, so portrait phones keep a natural perspective.
    static func tangents(aspect: Double) -> (Double, Double) {
        let t = tan(fieldOfViewDegrees * .pi / 360)
        return aspect >= 1 ? (t * aspect, t) : (t, t / max(0.01, aspect))
    }

    /// Whether the field's length axis runs down the screen, as in the 2D top view.
    static func runsDownScreen(_ field: BoardFieldType, viewport: CGSize) -> Bool {
        viewport.height > viewport.width && field.rotatesInPortrait
    }

    /// Azimuth 0 tilts the top view towards the viewer: the camera sits at the bottom edge of the
    /// 2D top view for this viewport (the v = 1 side, or the u = 1 end when the field turns in portrait).
    static func basis(field: BoardFieldType, azimuth: Double, elevation: Double, viewport: CGSize) -> (forward: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>) {
        let base = runsDownScreen(field, viewport: viewport) ? 0.0 : 90
        let a = (base - azimuth) * .pi / 180, e = elevation * .pi / 180
        let toEye = SIMD3(cos(e) * cos(a), sin(e), cos(e) * sin(a))
        let forward = -toEye
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        return (forward, right, simd_cross(right, forward))
    }

    /// Size of standing figures relative to life size: small fields show real proportions,
    /// big pitches exaggerate so players stay readable (consistent with the 2D markers).
    static func figureScale(_ field: BoardFieldType) -> Double {
        let meters = field.meters
        return max(1, Double(min(meters.width, meters.height)) / 100 * 7.5 / 1.8)
    }

    /// Points that must stay in view: field corners with a small apron, on the ground and at figure height.
    static func framedPoints(_ field: BoardFieldType) -> [SIMD3<Double>] {
        let meters = field.meters
        let margin = 0.025 * Double(max(meters.width, meters.height))
        let hx = Double(meters.width) / 2 + margin, hz = Double(meters.height) / 2 + margin
        let height = 2.4 * figureScale(field)
        var points: [SIMD3<Double>] = []
        for x in [-hx, hx] { for z in [-hz, hz] { for y in [0, height] { points.append(SIMD3(x, y, z)) } } }
        return points
    }

    /// Solves distance and eye offset so the projected field fills the viewport (within
    /// `fillX`/`fillY`) and is centred in both directions.
    static func framing(field: BoardFieldType, camera: BoardCamera, viewport: CGSize) -> BoardFraming {
        let camera = clamped(camera)
        let (tanX, tanY) = tangents(aspect: Double(max(1, viewport.width) / max(1, viewport.height)))
        let (forward, right, up) = basis(field: field, azimuth: camera.azimuthDegrees, elevation: camera.elevationDegrees, viewport: viewport)
        let points = framedPoints(field)
        let size = Double(max(field.meters.width, field.meters.height))
        var result = BoardFraming(distance: 2 * size)
        for _ in 0..<60 {
            let d = result.distance
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            for q in points {
                let depth = max(1e-3, simd_dot(q, forward) + d)
                let x = (simd_dot(q, right) - result.offsetX * d) / (depth * tanX)
                let y = (simd_dot(q, up) - result.offsetY * d) / (depth * tanY)
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            let centreX = (minX + maxX) / 2, centreY = (minY + maxY) / 2
            let grow = max((maxX - minX) / 2 / fillX, (maxY - minY) / 2 / fillY)
            result.offsetX += centreX * tanX * 0.8
            result.offsetY += centreY * tanY * 0.8
            // Keep the nearest points in front of the camera while converging.
            let nearest = points.map { simd_dot($0, forward) }.min() ?? 0
            result.distance = max(-nearest + 0.05 * size, d * (1 + (grow - 1) * 0.8))
            if abs(grow - 1) < 1e-5 && abs(centreX) < 1e-5 && abs(centreY) < 1e-5 { break }
        }
        return result
    }

    static func world(_ p: BoardPoint, field: BoardFieldType, y: Double = 0) -> SIMD3<Double> {
        SIMD3((p.x - 0.5) * Double(field.meters.width), y, (p.y - 0.5) * Double(field.meters.height))
    }

    static func board(_ world: SIMD3<Double>, field: BoardFieldType) -> BoardPoint {
        BoardPoint(world.x / Double(field.meters.width) + 0.5, world.z / Double(field.meters.height) + 0.5)
    }

    /// Screen position (points, y down) of a world point; nil when behind the camera.
    func project(_ world: SIMD3<Double>) -> CGPoint? {
        let v = world - eye
        let depth = simd_dot(v, forward)
        guard depth > 1e-6 else { return nil }
        let x = simd_dot(v, right) / (depth * tanHalfWidth)
        let y = simd_dot(v, up) / (depth * tanHalfHeight)
        return CGPoint(x: (x + 1) / 2 * viewport.width, y: (1 - y) / 2 * viewport.height)
    }

    func rayDirection(through screen: CGPoint) -> SIMD3<Double> {
        let x = Double(screen.x / viewport.width) * 2 - 1
        let y = 1 - Double(screen.y / viewport.height) * 2
        return simd_normalize(forward + right * (x * tanHalfWidth) + up * (y * tanHalfHeight))
    }

    /// Intersection of the ray through a screen point with the ground (y = 0).
    func groundPoint(at screen: CGPoint) -> SIMD3<Double>? {
        let direction = rayDirection(through: screen)
        guard direction.y < -1e-4 else { return nil }
        let t = -eye.y / direction.y
        return t > 0 ? eye + direction * t : nil
    }

    func boardPoint(at screen: CGPoint) -> BoardPoint? {
        groundPoint(at: screen).map { BoardOrbit.board($0, field: field) }
    }

    /// Camera transform for SceneKit (right, up, back, eye columns).
    var transform: simd_float4x4 {
        let back = -forward
        return simd_float4x4(columns: (
            SIMD4(Float(right.x), Float(right.y), Float(right.z), 0),
            SIMD4(Float(up.x), Float(up.y), Float(up.z), 0),
            SIMD4(Float(back.x), Float(back.y), Float(back.z), 0),
            SIMD4(Float(eye.x), Float(eye.y), Float(eye.z), 1)
        ))
    }

    // MARK: Gestures

    /// One-finger orbit: horizontal drag turns around the target, vertical drag tilts.
    static func orbited(_ camera: BoardCamera, by translation: CGSize) -> BoardCamera {
        var result = camera
        result.azimuthDegrees = camera.azimuthDegrees - Double(translation.width) * 0.35
        result.elevationDegrees = camera.elevationDegrees + Double(translation.height) * 0.25
        return clamped(result)
    }

    /// Pinch zoom that keeps the ground point under `anchor` fixed on screen.
    static func zoomed(_ camera: BoardCamera, field: BoardFieldType, viewport: CGSize, framing: BoardFraming? = nil, by factor: Double, anchor: CGPoint) -> BoardCamera {
        let before = BoardOrbit(field: field, camera: camera, viewport: viewport, framing: framing)
        var result = before.camera
        result.distanceScale = camera.distanceScale / max(0.01, factor)
        result = clamped(result)
        guard let grip = before.groundPoint(at: anchor) else { return result }
        let after = BoardOrbit(field: field, camera: result, viewport: viewport, framing: before.framing)
        guard let landed = after.groundPoint(at: anchor) else { return result }
        return shifted(result, field: field, by: grip - landed)
    }

    /// Two-finger pan: the ground point under `from` follows the fingers to `to`.
    static func panned(_ camera: BoardCamera, field: BoardFieldType, viewport: CGSize, framing: BoardFraming? = nil, from: CGPoint, to: CGPoint) -> BoardCamera {
        let orbit = BoardOrbit(field: field, camera: camera, viewport: viewport, framing: framing)
        guard let grip = orbit.groundPoint(at: from), let landed = orbit.groundPoint(at: to) else { return orbit.camera }
        // Near the horizon a small finger move covers huge ground distances; cap each step.
        var delta = grip - landed
        let limit = 0.25 * Double(max(field.meters.width, field.meters.height))
        if simd_length(delta) > limit { delta = simd_normalize(delta) * limit }
        return shifted(orbit.camera, field: field, by: delta)
    }

    private static func shifted(_ camera: BoardCamera, field: BoardFieldType, by delta: SIMD3<Double>) -> BoardCamera {
        var result = camera
        let target = world(camera.target, field: field) + SIMD3(delta.x, 0, delta.z)
        result.target = board(target, field: field).clamped()
        return result
    }
}

/// Render quality knobs. Phones get smaller shadow maps, fewer shadow taps, 2x antialiasing and a
/// smaller ground texture; Macs (and the simulator) can afford more. Settable for benchmarks.
struct Board3DQuality: Sendable, Equatable {
    var antialiasing: SCNAntialiasingMode
    var shadowMapSize: CGSize
    var shadowSampleCount: Int
    var shadowRadius: CGFloat
    /// Largest ground texture dimension in pixels.
    var groundTextureLimit: CGFloat
    var maxAnisotropy: Int
    /// Whether small props (cones, markers, hoops, ladders) cast shadows as well as figures.
    var propsCastShadows: Bool
    /// Movement below this many metres does not rebuild a line mesh (0 rebuilds every frame).
    var lineRebuildTolerance: Double = 0.02

    static let high = Board3DQuality(antialiasing: .multisampling4X, shadowMapSize: CGSize(width: 2048, height: 2048), shadowSampleCount: 8,
                                     shadowRadius: 2.5, groundTextureLimit: 4096, maxAnisotropy: 8, propsCastShadows: true)
    static let phone = Board3DQuality(antialiasing: .multisampling2X, shadowMapSize: CGSize(width: 1024, height: 1024), shadowSampleCount: 4,
                                      shadowRadius: 1.8, groundTextureLimit: 4096, maxAnisotropy: 8, propsCastShadows: false)

    #if targetEnvironment(simulator)
    static let automatic = Board3DQuality.high
    #else
    static let automatic = ProcessInfo.processInfo.isiOSAppOnMac ? Board3DQuality.high : Board3DQuality.phone
    #endif

    nonisolated(unsafe) static var current = Board3DQuality.automatic
}

// MARK: - Line description

/// Everything the 3D scene needs to draw a line-like element or an area border.
struct Board3DLineSpec: Equatable {
    var vertices: [BoardPoint]
    var control: BoardPoint? = nil
    var style = BoardLineStyle(endCap: .none)
    /// Metres removed from each end, so attached ends stop at the edge of the element.
    var startTrim: Double = 0
    var endTrim: Double = 0

    init(vertices: [BoardPoint], control: BoardPoint? = nil, style: BoardLineStyle = BoardLineStyle(endCap: .none)) {
        self.vertices = vertices
        self.control = control
        self.style = style
    }

    /// Resolved line of `element`; `radius` gives the 3D footprint of an attached element.
    static func make(_ element: BoardElement, radius: (UUID) -> Double = { _ in 0 }) -> Board3DLineSpec? {
        guard element.isLineLike else { return nil }
        var spec = Board3DLineSpec(vertices: element.lineVertices, control: element.curveControl, style: element.resolvedLineStyle)
        spec.startTrim = element.startAttachment.map(radius) ?? 0
        spec.endTrim = element.endAttachment.map(radius) ?? 0
        return spec
    }
}

// MARK: - Scene

/// Builds and updates the SceneKit scene for a board. Nodes are keyed by element id and
/// only transforms (or one line's mesh) change between frames, so playback is cheap.
/// Not thread-safe: use one instance from one thread at a time.
final class TacticalBoard3DScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let elementsNode = SCNNode()
    private let environmentNode = SCNNode()
    private let selectionNode = SCNNode()
    /// Onion-skin ghosts live in their own root so they never mix with element nodes.
    let ghostsNode = SCNNode()
    private let keyLight = SCNNode()

    private(set) var field: BoardFieldType?
    private(set) var style: BoardFieldStyle?
    private var entries: [UUID: Entry] = [:]
    private var materials: [String: SCNMaterial] = [:]
    lazy var figureGeometry = Board3DShapes.figure()
    /// Offscreen renders set this: they are already off the main thread, so they can wait for a
    /// photo to be read and decoded instead of skipping it for this pass.
    var loadsPhotosSynchronously = false
    private var backdrop = UIColor.black

    private struct PathKey: Equatable {
        var element: BoardElement
        var line: Board3DLineSpec?

        /// Rebuilding a line mesh is only worth it when its shape really changed. During playback
        /// attached and followed lines move every frame by tiny amounts; a millimetre-scale tolerance
        /// keeps the mesh and skips the rebuild.
        func matchesShape(of other: PathKey, tolerance: Double) -> Bool {
            let a = element, b = other.element
            guard a.kind == b.kind, a.colorHex == b.colorHex, a.opacity == b.opacity, a.size == b.size,
                  a.lineStyle == b.lineStyle, a.arrowStyle == b.arrowStyle, a.isCurved == b.isCurved,
                  a.isDoubleHeaded == b.isDoubleHeaded, a.hasBlockEnd == b.hasBlockEnd, a.zoneShape == b.zoneShape,
                  a.showsLength == b.showsLength, a.borderPattern == b.borderPattern, a.showsBorder == b.showsBorder,
                  a.arcHeightMeters == b.arcHeightMeters, a.startHeightMeters == b.startHeightMeters, a.endHeightMeters == b.endHeightMeters,
                  abs(a.rotation - b.rotation) < 0.05, a.points.count == b.points.count,
                  line?.startTrim == other.line?.startTrim, line?.endTrim == other.line?.endTrim else { return false }
            for (p, q) in zip(a.allPoints, b.allPoints) where abs(p.x - q.x) > tolerance || abs(p.y - q.y) > tolerance { return false }
            return true
        }
    }

    private struct Entry {
        let node: SCNNode
        /// Appearance that requires rebuilding the node when it changes.
        let look: String
        /// Last resolved path (element plus attachment trims); its mesh is rebuilt only when this changes.
        var path: PathKey?
    }

    init() {
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(BoardOrbit.fieldOfViewDegrees)
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(environmentNode)
        scene.rootNode.addChildNode(elementsNode)
        selectionNode.isHidden = true
        selectionNode.name = "selection"
        scene.rootNode.addChildNode(selectionNode)
        ghostsNode.name = "ghosts"
        scene.rootNode.addChildNode(ghostsNode)
    }

    var elementCount: Int { entries.count }
    func node(for id: UUID) -> SCNNode? { entries[id]?.node }
    var backgroundColor: UIColor { backdrop }

    /// Element id owning a hit-tested node, if any.
    func elementID(of node: SCNNode) -> UUID? {
        var current: SCNNode? = node
        while let candidate = current {
            if candidate.parent === elementsNode, let name = candidate.name { return UUID(uuidString: name) }
            current = candidate.parent
        }
        return nil
    }

    // MARK: Update

    func update(document: BoardDocument, time: Double?, selectedID: UUID?) {
        let style = document.fieldStyle
        if field != document.fieldType || self.style != style {
            buildEnvironment(field: document.fieldType, style: style)
            for entry in entries.values { entry.node.removeFromParentNode() }
            entries.removeAll()
            selectionElement = nil
        }
        let field = document.fieldType
        let elements = document.elements(at: time).sorted { $0.kind.zOrder < $1.kind.zOrder }
        var points: [UUID: BoardElement] = [:]
        for element in elements where element.kind.isPoint { points[element.id] = element }
        let radius: (UUID) -> Double = { id in points[id].map { TacticalBoard3DScene.footprintRadius($0, field: field) } ?? 0 }
        var seen = Set<UUID>()
        for element in elements {
            seen.insert(element.id)
            let look = lookKey(element)
            let path = element.kind.isPoint ? nil : PathKey(element: element, line: Board3DLineSpec.make(element, radius: radius))
            if var entry = entries[element.id], entry.look == look {
                if element.kind.isPoint {
                    applyTransform(entry.node, element: element, field: field)
                } else if let path, let previous = entry.path, !previous.matchesShape(of: path, tolerance: pathTolerance(field)) {
                    rebuildPathGeometry(entry.node, path: path, field: field)
                    entry.path = path
                    entries[element.id] = entry
                }
            } else {
                if entries[element.id] != nil { billboardsNeedPruning = true }
                entries[element.id]?.node.removeFromParentNode()
                let node = SCNNode()
                node.name = element.id.uuidString
                if let path { rebuildPathGeometry(node, path: path, field: field) } else { buildPointNode(node, element: element, field: field) }
                elementsNode.addChildNode(node)
                entries[element.id] = Entry(node: node, look: look, path: path)
            }
        }
        for id in entries.keys where !seen.contains(id) {
            entries[id]?.node.removeFromParentNode()
            entries[id] = nil
            billboardsNeedPruning = true
        }
        for id in hiddenSubjects { entries[id]?.node.isHidden = true }
        updateSelection(elements.first { $0.id == selectedID }, field: field)
    }

    /// Places the SceneKit camera at any resolved pose (orbit, free or point of view).
    func applyPose(_ pose: BoardViewPose, viewport: CGSize) {
        let field = self.field ?? .footballFull
        let size = Double(max(field.meters.width, field.meters.height))
        cameraNode.simdTransform = pose.transform
        // Camera and fog properties are only written when they really change: every write makes
        // SceneKit rebuild render state, which showed up while orbiting.
        if let scnCamera = cameraNode.camera {
            let direction: SCNCameraProjectionDirection = viewport.width >= viewport.height ? .vertical : .horizontal
            if scnCamera.projectionDirection != direction { scnCamera.projectionDirection = direction }
            if abs(scnCamera.fieldOfView - CGFloat(pose.fieldOfViewDegrees)) > 0.01 { scnCamera.fieldOfView = CGFloat(pose.fieldOfViewDegrees) }
            let near = max(0.05, min(pose.focusDistance * 0.2, pose.eye.y * 0.5))
            if abs(scnCamera.zNear - near) > near * 0.05 { scnCamera.zNear = near }
            let far = pose.focusDistance + size * 14
            if abs(scnCamera.zFar - far) > far * 0.05 { scnCamera.zFar = far }
        }
        // Distance fog melts the surround into the backdrop instead of showing a horizon.
        let fogStart = max(pose.focusDistance, pose.fieldOfViewDegrees > BoardOrbit.fieldOfViewDegrees + 1 ? size * 0.9 : 0)
        let start = CGFloat(fogStart + size * 0.25), end = CGFloat(fogStart + size * 1.8)
        if abs(scene.fogStartDistance - start) > start * 0.02 {
            scene.fogStartDistance = start
            scene.fogEndDistance = end
        }
        applyLabelScale(distance: pose.focusDistance, field: field)
        faceBillboards(pose)
        hiddenSubjects = pose.hiddenSubjects
    }

    /// Elements whose nodes are hidden because the camera looks through their eyes.
    private(set) var hiddenSubjects: Set<UUID> = [] {
        didSet {
            guard hiddenSubjects != oldValue else { return }
            for id in oldValue.subtracting(hiddenSubjects) { entries[id]?.node.isHidden = false }
            for id in hiddenSubjects { entries[id]?.node.isHidden = true }
        }
    }

    /// Billboards are turned towards the camera by hand when the pose changes: cheaper and more
    /// predictable than an `SCNBillboardConstraint` on every badge, which SceneKit evaluates per frame.
    private var billboards: [SCNNode] = []
    private var billboardOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private var billboardsNeedPruning = false

    private func faceBillboards(_ pose: BoardViewPose) {
        let right = pose.right, up = pose.up, back = -pose.forward
        let basis = simd_float3x3(SIMD3(Float(right.x), Float(right.y), Float(right.z)),
                                  SIMD3(Float(up.x), Float(up.y), Float(up.z)),
                                  SIMD3(Float(back.x), Float(back.y), Float(back.z)))
        let orientation = simd_quatf(basis)
        if billboardsNeedPruning {
            billboardsNeedPruning = false
            let root = scene.rootNode
            billboards.removeAll { node in
                var current: SCNNode? = node
                while let candidate = current {
                    if candidate === root { return false }
                    current = candidate.parent
                }
                return true
            }
        }
        guard simd_length(orientation.vector - billboardOrientation.vector) > 1e-5 else { return }
        billboardOrientation = orientation
        for node in billboards { node.simdWorldOrientation = orientation }
    }

    private var labelScale: Float = 1

    /// Badges and labels grow when the camera pulls back so numbers keep a legible size on a
    /// phone with the whole field in view, and settle to their natural size close up.
    private func applyLabelScale(distance: Double, field: BoardFieldType) {
        let natural = 0.62 * BoardOrbit.figureScale(field)
        let wanted = 0.019 * distance
        let scale = Float(min(2.2, max(1, wanted / natural)))
        guard abs(scale - labelScale) > 0.001 else { return }
        labelScale = scale
        let fs = Float(BoardOrbit.figureScale(field))
        for entry in entries.values {
            entry.node.childNode(withName: "label", recursively: false)?.simdScale = SIMD3(repeating: scale)
            entry.node.childNode(withName: "length-label", recursively: false)?.simdScale = SIMD3(repeating: scale * fs)
        }
    }

    private func lookKey(_ element: BoardElement) -> String {
        switch element.kind {
        case .player, .goalkeeper, .opponent: "\(element.kind.rawValue)|\(element.colorHex)|\(element.number ?? -1)|\(element.label)|\(photo(for: element)?.version ?? "")"
        case .text: "text|\(element.colorHex)|\(element.label)"
        case .zone, .polygon, .arrow, .line, .polyline: "\(element.kind.rawValue)|path"
        case .coach, .referee: "\(element.kind.rawValue)|\(element.label)"
        case .stepMarker: "stepMarker|\(element.colorHex)|\(element.number ?? -1)"
        case .wall: "wall|\(element.colorHex)|\(element.wallCount)"
        case .ladder: "ladder|\(element.colorHex)|\(ladderRungs(element))"
        default: "\(element.kind.rawValue)|\(element.colorHex)"
        }
    }

    /// A linked squad player's photo and a version key that changes whenever the stored file does.
    /// The live view never blocks on disk: an undecoded photo is warmed in the background and the
    /// node is rebuilt when `SquadPhotoStore.didWarmPhoto` arrives. Offscreen renders (thumbnails
    /// and exports) run off the main thread and wait for the decode, so they never miss a face.
    func photo(for element: BoardElement) -> (image: CGImage, version: String)? {
        guard element.kind.isPerson, let id = element.playerID else { return nil }
        let found = loadsPhotosSynchronously ? SquadPhotoStore.imageWithVersion(for: id) : SquadPhotoStore.cachedImage(for: id)
        guard let found else { return nil }
        return (found.image, "\(id.uuidString)-\(found.version)")
    }

    /// Ladder length follows the 2D footprint (20 element units × size); rungs keep a 0.45 m pitch at figure scale.
    func ladderRungs(_ element: BoardElement) -> Int {
        guard let field else { return 8 }
        let length = 2 * element.visualRadiusMeters(field: field)
        return max(2, min(60, Int((length / (0.45 * BoardOrbit.figureScale(field))).rounded())))
    }

    private func applyTransform(_ node: SCNNode, element: BoardElement, field: BoardFieldType) {
        let p = BoardOrbit.world(element.position, field: field)
        // Elements following an aerial line rise and drop with it.
        node.simdPosition = SIMD3(Float(p.x), Float(element.heightMeters ?? 0), Float(p.z))
        node.simdEulerAngles = SIMD3(0, Float(-element.rotation * .pi / 180), 0)
        let scale: Double
        switch element.kind {
        case .goal: scale = 1 // Built at its real size for the field.
        case .ladder: scale = BoardOrbit.figureScale(field) // Size changes the rung count, not the width.
        default: scale = BoardOrbit.figureScale(field) * max(0.1, element.size)
        }
        node.simdScale = SIMD3(repeating: Float(scale))
    }

    // MARK: Environment

    private struct Ambience {
        var keyIntensity: CGFloat
        var keyColor: UIColor
        var keyElevation: Double
        var keyAzimuth: Double
        var shadowAlpha: CGFloat
        var ambientIntensity: CGFloat
        var ambientColor: UIColor
        var environmentIntensity: CGFloat
        var sky: UIColor
        var floodlights: Bool
    }

    private func ambience(_ style: BoardFieldStyle) -> Ambience {
        switch style {
        case .grass:
            Ambience(keyIntensity: 1350, keyColor: UIColor(red: 1, green: 0.95, blue: 0.86, alpha: 1), keyElevation: 52, keyAzimuth: 35, shadowAlpha: 0.5,
                     ambientIntensity: 380, ambientColor: UIColor(red: 0.78, green: 0.85, blue: 1, alpha: 1), environmentIntensity: 1.1, sky: UIColor(red: 0.62, green: 0.74, blue: 0.9, alpha: 1), floodlights: false)
        case .night:
            Ambience(keyIntensity: 420, keyColor: UIColor(red: 0.8, green: 0.86, blue: 1, alpha: 1), keyElevation: 70, keyAzimuth: 20, shadowAlpha: 0.45,
                     ambientIntensity: 160, ambientColor: UIColor(red: 0.6, green: 0.7, blue: 1, alpha: 1), environmentIntensity: 0.5, sky: UIColor(red: 0.16, green: 0.2, blue: 0.32, alpha: 1), floodlights: true)
        case .classic:
            Ambience(keyIntensity: 900, keyColor: .white, keyElevation: 66, keyAzimuth: 30, shadowAlpha: 0.3,
                     ambientIntensity: 750, ambientColor: .white, environmentIntensity: 1.3, sky: UIColor(white: 0.85, alpha: 1), floodlights: false)
        case .chalk:
            Ambience(keyIntensity: 700, keyColor: .white, keyElevation: 72, keyAzimuth: 30, shadowAlpha: 0.28,
                     ambientIntensity: 820, ambientColor: .white, environmentIntensity: 1.2, sky: UIColor(white: 0.8, alpha: 1), floodlights: false)
        case .court:
            Ambience(keyIntensity: 1000, keyColor: UIColor(red: 1, green: 0.9, blue: 0.76, alpha: 1), keyElevation: 74, keyAzimuth: 50, shadowAlpha: 0.4,
                     ambientIntensity: 520, ambientColor: UIColor(red: 1, green: 0.9, blue: 0.8, alpha: 1), environmentIntensity: 1.0, sky: UIColor(red: 0.95, green: 0.85, blue: 0.72, alpha: 1), floodlights: false)
        }
    }

    private func buildEnvironment(field: BoardFieldType, style: BoardFieldStyle) {
        self.field = field
        self.style = style
        environmentNode.childNodes.forEach { $0.removeFromParentNode() }
        materials.removeAll()
        let meters = field.meters
        let length = Double(meters.width), width = Double(meters.height)
        let size = max(length, width)
        let light = ambience(style)
        let textures = Board3DTextures.shared

        let tone = textures.surfaceTone(field: field, style: style)
        let ink = UIColor(red: 0.043, green: 0.046, blue: 0.054, alpha: 1)
        // Grass pitches sit on darker grass that fades into the distance, like a real ground; a
        // near-black floor made the pitch float and turned its soft edge into a green halo.
        let grass = style != .court
        backdrop = grass ? ink.blended(with: tone.scaled(0.4), 0.5) : ink.blended(with: tone.scaled(0.25), 0.1)
        // The surround continues the pitch's own grass tone, so the edge disappears into one lawn.
        let surroundInner = grass ? tone.scaled(0.92) : ink.scaled(0.6)
        let surroundOuter = grass ? tone.scaled(0.5).blended(with: ink, 0.35) : ink.scaled(0.5)

        // Ground: the shared 2D surface texture with a feathered edge.
        let quality = Board3DQuality.current
        let apron = max(2, 0.06 * size)
        // A narrow blend: enough to hide the texture edge, not a visible haze.
        let feather = 0.02 * size
        let pixelsPerMeter = min(28, quality.groundTextureLimit / CGFloat(size + 2 * (apron + feather)))
        let ground = SCNNode(geometry: SCNPlane(width: CGFloat(length + 2 * (apron + feather)), height: CGFloat(width + 2 * (apron + feather))))
        ground.name = "ground"
        ground.eulerAngles.x = -.pi / 2
        let groundMaterial = SCNMaterial()
        groundMaterial.lightingModel = .physicallyBased
        groundMaterial.diffuse.contents = textures.ground(field: field, style: style, pixelsPerMeter: pixelsPerMeter, apronMeters: CGFloat(apron), featherMeters: CGFloat(feather), surround: surroundInner)
        groundMaterial.diffuse.mipFilter = .linear
        groundMaterial.diffuse.maxAnisotropy = CGFloat(quality.maxAnisotropy)
        groundMaterial.roughness.contents = style == .court ? 0.45 : 0.92
        groundMaterial.metalness.contents = 0.0
        ground.geometry?.firstMaterial = groundMaterial
        environmentNode.addChildNode(ground)

        // Surround floor fading into the backdrop.
        let floor = SCNNode(geometry: SCNPlane(width: CGFloat(size * 24), height: CGFloat(size * 24)))
        floor.name = "surround"
        floor.eulerAngles.x = -.pi / 2
        floor.position.y = -0.03
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .physicallyBased
        floorMaterial.diffuse.contents = textures.surround(inner: surroundInner, outer: surroundOuter)
        floorMaterial.roughness.contents = style == .court ? 0.45 : 0.92
        floorMaterial.metalness.contents = 0.0
        floor.geometry?.firstMaterial = floorMaterial
        environmentNode.addChildNode(floor)

        let haze = backdrop.blended(with: tone.scaled(0.55), 0.18).blended(with: .white, style == .night ? 0.02 : 0.06)
        scene.background.contents = textures.sky(zenith: ink.scaled(0.7), horizon: haze, ground: backdrop)
        scene.fogColor = backdrop
        scene.fogDensityExponent = 1
        scene.lightingEnvironment.contents = textures.environment(top: light.sky, horizon: light.sky.blended(with: tone, 0.5), bottom: backdrop)
        scene.lightingEnvironment.intensity = light.environmentIntensity

        // Warm key light with soft shadow maps sized for phones.
        let key = SCNLight()
        key.type = .directional
        key.intensity = light.keyIntensity
        key.color = light.keyColor
        key.castsShadow = true
        key.shadowMode = .forward
        key.shadowColor = UIColor.black.withAlphaComponent(light.shadowAlpha)
        key.shadowMapSize = quality.shadowMapSize
        key.shadowSampleCount = quality.shadowSampleCount
        key.shadowRadius = quality.shadowRadius
        key.automaticallyAdjustsShadowProjection = false
        key.orthographicScale = CGFloat(size * 0.62)
        key.zNear = 1
        key.zFar = CGFloat(size * 4)
        keyLight.light = key
        let elevation = light.keyElevation * .pi / 180, azimuth = light.keyAzimuth * .pi / 180
        let toLight = SIMD3<Float>(Float(cos(elevation) * cos(azimuth)), Float(sin(elevation)), Float(cos(elevation) * sin(azimuth)))
        keyLight.simdPosition = toLight * Float(size * 1.8)
        keyLight.simdLook(at: .zero)
        environmentNode.addChildNode(keyLight)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = light.ambientIntensity
        ambient.light?.color = light.ambientColor
        environmentNode.addChildNode(ambient)

        if light.floodlights {
            for (sx, sz) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                let spot = SCNLight()
                spot.type = .spot
                spot.intensity = 5200
                spot.color = UIColor(red: 1, green: 0.97, blue: 0.9, alpha: 1)
                spot.spotInnerAngle = 30
                spot.spotOuterAngle = 95
                spot.attenuationStartDistance = CGFloat(size * 0.3)
                spot.attenuationEndDistance = CGFloat(size * 1.6)
                spot.attenuationFalloffExponent = 1.5
                let node = SCNNode()
                node.light = spot
                node.simdPosition = SIMD3(Float(sx * (length / 2 + apron)), Float(size * 0.32), Float(sz * (width / 2 + apron)))
                node.simdLook(at: SIMD3(Float(sx * length * 0.1), 0, Float(sz * width * 0.1)))
                environmentNode.addChildNode(node)
            }
        }
    }

    // MARK: Materials

    func material(_ key: String, _ make: () -> SCNMaterial) -> SCNMaterial {
        if let existing = materials[key] { return existing }
        let created = make()
        // The key is kept on the material so derived materials (ghosts) can name their own cache
        // entry after it instead of after an object address, which another material can inherit.
        created.name = key
        materials[key] = created
        return created
    }

    func bodyMaterial(_ hex: String, kind: BoardElementKind) -> SCNMaterial {
        material("body-\(hex)-\(kind == .opponent)") {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = BoardPalette.uiColor(hex)
            m.roughness.contents = kind == .opponent ? 0.62 : 0.34
            m.metalness.contents = 0.0
            m.clearCoat.contents = kind == .opponent ? 0.0 : 0.35
            m.clearCoatRoughness.contents = 0.25
            m.emission.contents = Board3DTextures.shared.chestMask()
            m.emission.intensity = 0.28
            return m
        }
    }

    func solidMaterial(_ hex: String, roughness: Double = 0.4) -> SCNMaterial {
        material("solid-\(hex)-\(roughness)") {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = BoardPalette.uiColor(hex)
            m.roughness.contents = roughness
            m.metalness.contents = 0.0
            return m
        }
    }

    func flatMaterial(_ key: String, image: Any?, blend: SCNBlendMode = .alpha) -> SCNMaterial {
        material(key) {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = image
            m.diffuse.mipFilter = .linear
            m.blendMode = blend
            m.writesToDepthBuffer = false
            m.isDoubleSided = false
            return m
        }
    }

    private func pathMaterial(_ hex: String, alpha: Double = 1) -> SCNMaterial {
        material("path-\(hex)-\(alpha)") {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = BoardPalette.uiColor(hex)
            m.emission.contents = BoardPalette.uiColor(hex).withAlphaComponent(1)
            m.emission.intensity = 0.25
            m.roughness.contents = 0.5
            m.metalness.contents = 0.0
            if alpha < 1 {
                m.transparency = CGFloat(alpha)
                m.blendMode = .alpha
                m.writesToDepthBuffer = false
            }
            return m
        }
    }

    private func fillMaterial(_ hex: String, opacity: Double) -> SCNMaterial {
        material("fill-\(hex)-\(Int(opacity * 100))") {
            let m = SCNMaterial()
            m.lightingModel = .lambert
            m.diffuse.contents = BoardPalette.uiColor(hex)
            m.transparency = CGFloat(min(1, max(0.05, opacity)))
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            return m
        }
    }

    // MARK: Nodes

    /// Long equipment is modelled along local z; turn it so its length runs along local x like in 2D
    /// (and its face points to -z, like the goals).
    private func turned(_ child: SCNNode) -> SCNNode {
        let holder = SCNNode()
        child.simdEulerAngles.y = .pi / 2
        holder.addChildNode(child)
        return holder
    }

    /// Ground footprint radius of a point element in metres (edge of its base ring), used to
    /// stop attached line ends there.
    static func footprintRadius(_ element: BoardElement, field: BoardFieldType) -> Double {
        let scale = BoardOrbit.figureScale(field) * max(0.1, element.size)
        switch element.kind {
        case .player, .goalkeeper, .opponent: return 0.56 * scale
        case .ball: return 0.3 * scale
        case .cone: return 0.3 * scale
        case .marker: return 0.42 * scale
        case .miniGoal: return 1.25 * scale
        case .mannequin: return 0.45 * scale
        case .text: return 0.6 * scale
        case .coach, .referee: return 0.56 * scale
        case .tallCone, .domeCone, .pole, .hurdle, .ladder, .ring, .wall, .goal, .popUpGoal, .rebounder, .flag, .ballCart, .stepMarker:
            return 0.8 * element.visualRadiusMeters(field: field)
        case .arrow, .zone, .polygon, .line, .polyline: return 0
        }
    }

    /// Small ground props add shadow-pass draw calls for very little visual gain on a phone.
    private static let propKinds: Set<BoardElementKind> = [.cone, .marker, .domeCone, .ring, .ladder, .stepMarker, .tallCone, .hurdle, .ballCart, .pole]

    private func buildPointNode(_ node: SCNNode, element: BoardElement, field: BoardFieldType) {
        defer {
            if Self.propKinds.contains(element.kind) && !Board3DQuality.current.propsCastShadows {
                node.enumerateHierarchy { child, _ in child.castsShadow = false }
            }
        }
        switch element.kind {
        case .player, .goalkeeper, .opponent:
            let base = SCNNode(geometry: SCNPlane(width: 1.35, height: 1.35))
            base.eulerAngles.x = -.pi / 2
            base.position.y = 0.012
            base.geometry?.firstMaterial = flatMaterial("base-\(element.colorHex)-\(element.kind == .opponent)", image: Board3DTextures.shared.baseRing(colorHex: element.colorHex, dashed: element.kind == .opponent))
            base.castsShadow = false
            node.addChildNode(base)

            let body = SCNNode(geometry: figureGeometry.copy() as? SCNGeometry)
            body.geometry?.firstMaterial = bodyMaterial(element.colorHex, kind: element.kind)
            body.simdScale = SIMD3(1, 1, 0.84)
            node.addChildNode(body)

            if let photo = photo(for: element),
               let image = Board3DTextures.shared.photoBadge(photo: photo.image, version: photo.version, number: element.number, label: element.label, colorHex: element.colorHex, kind: element.kind) {
                // Photos read best a little larger than number pills.
                node.addChildNode(billboard(image: image, key: "photo-\(photo.version)-\(element.kind.rawValue)-\(element.colorHex)-\(element.number ?? -1)-\(element.label)", height: element.label.isEmpty ? 1.05 : 1.4, bottom: 1.8))
            } else if element.number != nil || !element.label.isEmpty,
               let image = Board3DTextures.shared.badge(number: element.number, label: element.label, colorHex: element.colorHex, kind: element.kind) {
                node.addChildNode(billboard(image: image, key: "badge-\(element.kind.rawValue)-\(element.colorHex)-\(element.number ?? -1)-\(element.label)", height: element.label.isEmpty ? 0.62 : 1.05, bottom: 1.86))
            }
        case .ball:
            let basketball = field.usesBasketball
            let sphere = SCNSphere(radius: basketball ? 0.2 : 0.17)
            sphere.segmentCount = 28
            sphere.firstMaterial = ballMaterial(basketball: basketball)
            let ball = SCNNode(geometry: sphere)
            ball.position.y = Float(sphere.radius)
            node.addChildNode(ball)
            node.addChildNode(contactShadow(radius: sphere.radius * 1.8))
        case .cone:
            let cone = SCNCone(topRadius: 0.025, bottomRadius: 0.19, height: 0.46)
            cone.radialSegmentCount = 24
            cone.firstMaterial = solidMaterial(element.colorHex, roughness: 0.35)
            let coneNode = SCNNode(geometry: cone)
            coneNode.position.y = 0.25
            node.addChildNode(coneNode)
            let rim = SCNCylinder(radius: 0.24, height: 0.03)
            rim.radialSegmentCount = 24
            rim.firstMaterial = solidMaterial(element.colorHex, roughness: 0.7)
            let rimNode = SCNNode(geometry: rim)
            rimNode.position.y = 0.015
            node.addChildNode(rimNode)
        case .marker:
            let disc = SCNCylinder(radius: 0.36, height: 0.035)
            disc.radialSegmentCount = 28
            disc.firstMaterial = solidMaterial(element.colorHex, roughness: 0.5)
            let discNode = SCNNode(geometry: disc)
            discNode.position.y = 0.018
            node.addChildNode(discNode)
        case .miniGoal:
            node.addChildNode(miniGoal(colorHex: element.colorHex))
        case .mannequin:
            // Copy before colouring: the shared geometry is reused by every mannequin, so
            // setting its material in place would repaint the ones already built.
            let body = SCNNode(geometry: sharedMannequin.copy() as? SCNGeometry)
            body.geometry?.firstMaterial = solidMaterial(element.colorHex, roughness: 0.45)
            body.simdScale = SIMD3(0.42, 1, 1)
            body.position.y = 1.02
            node.addChildNode(body)
            let pole = SCNNode(geometry: sharedPole)
            pole.position.y = 0.14
            node.addChildNode(pole)
            node.addChildNode(contactShadow(radius: 0.55))
        case .text:
            if let image = Board3DTextures.shared.textLabel(element.label, colorHex: element.colorHex) {
                node.addChildNode(billboard(image: image, key: "text-\(element.colorHex)-\(element.label)", height: 0.62, bottom: 0.25))
            }
        case .tallCone: node.addChildNode(tallCone(colorHex: element.colorHex))
        case .domeCone: node.addChildNode(domeCone(colorHex: element.colorHex))
        case .pole: node.addChildNode(slalomPole(colorHex: element.colorHex))
        case .hurdle: node.addChildNode(turned(hurdle(colorHex: element.colorHex)))
        case .ladder: node.addChildNode(ladder(colorHex: element.colorHex, rungs: ladderRungs(element)))
        case .ring: node.addChildNode(speedRing(colorHex: element.colorHex))
        case .wall: node.addChildNode(turned(mannequinWall(colorHex: element.colorHex, count: element.wallCount)))
        case .goal:
            // A real 7.32 m goal on football pitches; smaller surfaces keep it proportionate (as in 2D).
            let width = Float(2 * min(3.66, 8 * field.elementUnitMeters) * max(0.1, element.size))
            node.addChildNode(goal(width: width, height: width / 3, depth: width * 0.27, bar: CGFloat(width) * 0.0085, frameHex: element.colorHex))
        case .popUpGoal: node.addChildNode(popUpGoal(colorHex: element.colorHex))
        case .rebounder: node.addChildNode(turned(rebounder(colorHex: element.colorHex)))
        case .flag: node.addChildNode(flag(colorHex: element.colorHex))
        case .ballCart: node.addChildNode(ballCart(basketball: field.usesBasketball))
        case .coach, .referee: node.addChildNode(staffFigure(referee: element.kind == .referee, label: element.label))
        case .stepMarker: node.addChildNode(stepMarker(colorHex: element.colorHex, number: element.number))
        case .arrow, .line, .polyline, .zone, .polygon:
            return
        }
        applyTransform(node, element: element, field: field)
    }

    lazy var sharedMannequin: SCNGeometry = {
        let capsule = SCNCapsule(capRadius: 0.26, height: 1.7)
        capsule.radialSegmentCount = 20
        return capsule
    }()

    lazy var sharedPole: SCNGeometry = {
        let pole = SCNCylinder(radius: 0.05, height: 0.28)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(white: 0.15, alpha: 1)
        m.metalness.contents = 0.6
        m.roughness.contents = 0.35
        pole.firstMaterial = m
        return pole
    }()

    func contactShadow(radius: CGFloat) -> SCNNode {
        let plane = SCNNode(geometry: SCNPlane(width: radius * 2, height: radius * 2))
        plane.eulerAngles.x = -.pi / 2
        plane.position.y = 0.01
        plane.castsShadow = false
        plane.geometry?.firstMaterial = flatMaterial("shadow", image: Board3DTextures.shared.baseRing(colorHex: "000000", dashed: false))
        return plane
    }

    func billboard(image: CGImage, key: String, height: CGFloat, bottom: Float) -> SCNNode {
        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        let plane = SCNPlane(width: height * aspect, height: height)
        let m = flatMaterial(key, image: image)
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        plane.firstMaterial = m
        let node = SCNNode(geometry: plane)
        node.pivot = SCNMatrix4MakeTranslation(0, Float(-height / 2), 0)
        node.name = "billboard"
        let holder = SCNNode()
        holder.name = "label"
        holder.position.y = bottom
        holder.simdScale = SIMD3(repeating: labelScale)
        holder.addChildNode(node)
        node.castsShadow = false
        node.simdWorldOrientation = billboardOrientation
        node.renderingOrder = 100
        billboards.append(node)
        return holder
    }

    private func miniGoal(colorHex: String) -> SCNNode {
        let goal = SCNNode()
        let width: Float = 2.4, height: Float = 1.0, depth: Float = 0.9, bar: CGFloat = 0.05
        let frame = solidMaterial(colorHex, roughness: 0.3)
        func tube(_ from: SIMD3<Float>, _ to: SIMD3<Float>) {
            let cylinder = SCNCylinder(radius: bar, height: CGFloat(simd_distance(from, to)))
            cylinder.radialSegmentCount = 10
            cylinder.firstMaterial = frame
            let node = SCNNode(geometry: cylinder)
            node.simdPosition = (from + to) / 2
            let direction = simd_normalize(to - from)
            node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: direction)
            goal.addChildNode(node)
        }
        let fl = SIMD3<Float>(-width / 2, 0, -depth / 2), fr = SIMD3<Float>(width / 2, 0, -depth / 2)
        let bl = SIMD3<Float>(-width / 2, 0, depth / 2), br = SIMD3<Float>(width / 2, 0, depth / 2)
        let lift = SIMD3<Float>(0, height, 0)
        tube(fl, fl + lift); tube(fr, fr + lift); tube(fl + lift, fr + lift)
        tube(bl, br); tube(fl, bl); tube(fr, br)
        tube(fl + lift, bl); tube(fr + lift, br)
        // Net: back slope and two side triangles, translucent and double sided.
        let net = material("net") {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = Board3DTextures.shared.net()
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(4, 3, 1)
            m.transparency = 0.55
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            return m
        }
        var mesh: [SCNVector3] = []
        var uvs: [CGPoint] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            for (p, uv) in [(a, CGPoint(x: 0, y: 0)), (b, CGPoint(x: 1, y: 0)), (c, CGPoint(x: 1, y: 1)), (a, CGPoint(x: 0, y: 0)), (c, CGPoint(x: 1, y: 1)), (d, CGPoint(x: 0, y: 1))] {
                mesh.append(SCNVector3(p.x, p.y, p.z)); uvs.append(uv)
            }
        }
        quad(fl + lift, fr + lift, br, bl)
        quad(fl, fl + lift, bl, bl)
        quad(fr, fr + lift, br, br)
        let indices = (0..<UInt32(mesh.count)).map { $0 }
        let netGeometry = SCNGeometry(sources: [SCNGeometrySource(vertices: mesh), SCNGeometrySource(textureCoordinates: uvs)], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        netGeometry.firstMaterial = net
        let netNode = SCNNode(geometry: netGeometry)
        netNode.castsShadow = false
        goal.addChildNode(netNode)
        return goal
    }

    // MARK: Paths

    /// Movement below this (normalised) does not change the drawn line: about 2 cm on a full pitch.
    private func pathTolerance(_ field: BoardFieldType) -> Double {
        Board3DQuality.current.lineRebuildTolerance / Double(max(field.meters.width, field.meters.height))
    }

    /// Visual unit matching the 2D renderer: one percent of the field's shorter side.
    func unit(_ field: BoardFieldType) -> Double {
        Double(min(field.meters.width, field.meters.height)) / 100
    }

    func planar(_ p: BoardPoint, _ field: BoardFieldType) -> SIMD2<Double> {
        let w = BoardOrbit.world(p, field: field)
        return SIMD2(w.x, w.z)
    }

    private func centreline(_ spec: Board3DLineSpec, field: BoardFieldType) -> [SIMD2<Double>] {
        if let control = spec.control, spec.vertices.count == 2 {
            return Board3DPath.quadratic(planar(spec.vertices[0], field), planar(control, field), planar(spec.vertices[1], field), step: 0.3 * unit(field))
        }
        return spec.vertices.map { planar($0, field) }
    }

    /// How many line or area meshes have been rebuilt (watched by the playback benchmark).
    private(set) var pathRebuilds = 0

    private func rebuildPathGeometry(_ node: SCNNode, path: PathKey, field: BoardFieldType) {
        pathRebuilds += 1
        node.childNodes.forEach { $0.removeFromParentNode() }
        let element = path.element
        let u = unit(field)
        if element.kind.isArea {
            let outline = areaOutline(element, field: field)
            var fill = Board3DMesh()
            fill.addFill(outline, y: 0.02)
            if !fill.isEmpty, element.opacity > 0.001 {
                let geometry = fill.geometry()
                geometry.firstMaterial = fillMaterial(element.colorHex, opacity: element.opacity)
                let fillNode = SCNNode(geometry: geometry)
                fillNode.castsShadow = false
                node.addChildNode(fillNode)
            }
            if let pattern = element.resolvedBorderPattern {
                var rim = Board3DMesh()
                addLine(&rim, points: outline, spec: Board3DLineSpec(vertices: [], style: BoardLineStyle(pattern: pattern, endCap: .none)), halfWidth: 0.22 * u, closed: true, unit: u)
                if !rim.isEmpty {
                    let geometry = rim.geometry()
                    geometry.firstMaterial = pathMaterial(element.colorHex, alpha: 0.95)
                    let rimNode = SCNNode(geometry: geometry)
                    rimNode.castsShadow = false
                    node.addChildNode(rimNode)
                }
            }
        } else if let spec = path.line {
            let centre = centreline(spec, field: field)
            var mesh = Board3DMesh()
            let height: ((Double) -> Double)? = element.isAerial ? { element.lineHeightMeters(at: $0) } : nil
            addLine(&mesh, points: centre, spec: spec, halfWidth: 0.4 * u * spec.style.width, closed: false, unit: u, height: height)
            guard !mesh.isEmpty else { return }
            let geometry = mesh.geometry()
            geometry.firstMaterial = pathMaterial(element.colorHex, alpha: spec.style.strokeOpacity)
            let line = SCNNode(geometry: geometry)
            line.castsShadow = false
            node.addChildNode(line)
            if let height { addArcShadow(node, centre: centre, height: height, unit: u) }
            if element.showsLength == true { addLengthLabel(node, centreline: centre) }
        }
    }

    /// Zone or polygon outline in metres. Zones turn by `rotation` (clockwise on the top view)
    /// around their centre; polygons already store rotated points.
    /// Soft ground shadow under an arc: a translucent strip that widens and fades as the line climbs.
    private func addArcShadow(_ node: SCNNode, centre: [SIMD2<Double>], height: (Double) -> Double, unit u: Double) {
        guard centre.count >= 2 else { return }
        let dense = Board3DPath.densified(centre, step: 1.2 * u)
        let total = Board3DPath.length(dense)
        guard total > 0 else { return }
        var mesh = Board3DMesh()
        var travelled = 0.0
        var points: [SIMD2<Double>] = []
        var widths: [Double] = []
        for (index, point) in dense.enumerated() {
            if index > 0 { travelled += simd_distance(dense[index - 1], point) }
            points.append(point)
            widths.append(0.35 * u + height(travelled / total) * 0.06)
        }
        // One quad per segment, widening with height.
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            var tangent = b - a
            if simd_length(tangent) < 1e-9 { continue }
            tangent = simd_normalize(tangent)
            let side = SIMD2(-tangent.y, tangent.x)
            mesh.addFill([a + side * widths[index], b + side * widths[index + 1], b - side * widths[index + 1], a - side * widths[index]], y: 0.015)
        }
        guard !mesh.isEmpty else { return }
        let geometry = mesh.geometry()
        geometry.firstMaterial = material("arc-shadow") {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor(white: 0, alpha: 1)
            m.transparency = 0.22
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            return m
        }
        let shadow = SCNNode(geometry: geometry)
        shadow.castsShadow = false
        shadow.renderingOrder = -1
        node.addChildNode(shadow)
    }

    /// Distance pill (metres of the drawn line, ends included) floating at the line's midpoint.
    private func addLengthLabel(_ node: SCNNode, centreline: [SIMD2<Double>]) {
        let length = Board3DPath.length(centreline)
        guard length > 0, let middle = Board3DPath.slice(centreline, from: length / 2, to: length / 2 + 1e-6).first else { return }
        let text = length < 10 ? String(format: "%.1f m", length) : String(format: "%.0f m", length)
        guard let image = Board3DTextures.shared.textLabel(text, colorHex: BoardPalette.white) else { return }
        let fs = Float(BoardOrbit.figureScale(field ?? .footballFull))
        let label = billboard(image: image, key: "length-\(text)", height: 0.62, bottom: 0.2)
        label.simdPosition = SIMD3(Float(middle.x), 0.2 * fs, Float(middle.y))
        label.simdScale = SIMD3(repeating: labelScale * fs)
        label.name = "length-label"
        node.addChildNode(label)
    }

    private func areaOutline(_ element: BoardElement, field: BoardFieldType) -> [SIMD2<Double>] {
        if element.kind == .polygon { return element.allPoints.map { planar($0, field) } }
        let a = planar(element.position, field), b = planar(element.opposite, field)
        let center = (a + b) / 2, half = simd_abs(b - a) / 2
        let corners: [SIMD2<Double>]
        if element.zoneShape == .ellipse {
            corners = (0..<56).map { index in
                let angle = Double(index) / 56 * 2 * .pi
                return SIMD2(half.x * cos(angle), half.y * sin(angle))
            }
        } else {
            corners = [SIMD2(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(half.x, half.y), SIMD2(-half.x, half.y)]
        }
        let r = element.rotation * .pi / 180, c = cos(r), s = sin(r)
        return corners.map { center + SIMD2($0.x * c - $0.y * s, $0.x * s + $0.y * c) }
    }

    /// Builds a styled line (pattern, shape, caps) into `mesh`.
    private func addLine(_ mesh: inout Board3DMesh, points: [SIMD2<Double>], spec: Board3DLineSpec, halfWidth: Double, closed: Bool, unit u: Double,
                         height: ((Double) -> Double)? = nil) {
        guard points.count >= 2 else { return }
        var path = points
        if closed, let first = points.first { path.append(first) }
        let y = 0.05
        let style = spec.style
        let headLength = 3 * u * style.width, headHalfWidth = headLength * 0.55
        path = Board3DPath.trimmed(path, start: spec.startTrim, end: spec.endTrim)
        guard path.count >= 2 else { return }
        let shaftStart = style.startCap == .arrow ? headLength * 0.6 : 0
        let shaftEnd = style.endCap == .arrow ? headLength * 0.6 : 0
        var shaft = Board3DPath.trimmed(path, start: shaftStart, end: shaftEnd)
        if style.shape != .straight, shaft.count >= 2 {
            shaft = Board3DPath.waved(Board3DPath.densified(shaft, step: 0.3 * u), amplitude: 1.1 * u * style.width, wavelength: 3.2 * u, zigzag: style.shape == .zigzag)
        }
        // Aerial lines are lifted onto their arc; flat ones sit just above the grass.
        let aerial = height != nil
        // A flight line is a slim tube: seen end-on (a keeper watching a lob) a wide ribbon would
        // fill the view.
        let halfWidth = aerial ? halfWidth * 0.55 : halfWidth
        let lift: ([SIMD2<Double>]) -> [SIMD3<Double>] = { flat in
            guard let height else { return flat.map { SIMD3($0.x, y, $0.y) } }
            // A straight line has only its two ends: it needs samples along the way to bend.
            return Board3DPath.lifted(Board3DPath.densified(flat, step: 0.8 * u), height: { max(y, height($0)) })
        }
        let shaft3D = lift(shaft)
        let total = Board3DPath.length(shaft3D)
        switch style.pattern {
        case .solid:
            if closed && style.startCap == .none && style.endCap == .none, shaft3D.count > 2 {
                mesh.addStrip(Array(shaft3D.dropLast()), halfWidth: halfWidth, closed: true, aerial: aerial)
            } else {
                mesh.addStrip(shaft3D, halfWidth: halfWidth, aerial: aerial)
            }
        case .dashed:
            let on = 2.4 * u, off = 1.9 * u
            var cursor = 0.0
            while cursor < total {
                mesh.addStrip(Board3DPath.slice(shaft3D, from: cursor, to: min(total, cursor + on)), halfWidth: halfWidth, aerial: aerial)
                cursor += on + off
            }
        case .dotted:
            let spacing = max(halfWidth * 3.2, 1.2 * u)
            var cursor = 0.0
            while cursor <= total {
                if let point = Board3DPath.slice(shaft3D, from: cursor, to: min(total, cursor + 0.001)).first {
                    mesh.addDisc(center: SIMD2(point.x, point.z), radius: halfWidth * 1.15, y: point.y)
                }
                cursor += spacing
            }
        }
        // Caps follow the 3D tangents, so an arrow at the end of a lob points down into the goal.
        let full3D = lift(path)
        let capEnds: [(BoardLineCap, SIMD3<Double>, SIMD3<Double>)] = [
            (style.startCap, full3D[0], full3D.count > 1 ? full3D[0] - full3D[1] : SIMD3(1, 0, 0)),
            (style.endCap, full3D[full3D.count - 1], full3D.count > 1 ? full3D[full3D.count - 1] - full3D[full3D.count - 2] : SIMD3(1, 0, 0)),
        ]
        for (cap, tip, direction) in capEnds {
            guard simd_length(direction) > 1e-9 else { continue }
            switch cap {
            case .none: break
            case .arrow: mesh.addArrowHead(tip: tip, direction: direction, length: headLength, halfWidth: headHalfWidth)
            case .bar: mesh.addBar(center: SIMD2(tip.x, tip.z), direction: SIMD2(direction.x, direction.z), halfLength: headLength * 0.7, halfWidth: halfWidth * 1.3, y: tip.y)
            case .dot: mesh.addDisc(center: SIMD2(tip.x, tip.z), radius: halfWidth * 2.2, y: tip.y)
            }
        }
    }

    // MARK: Onion skin

    /// Hit tests use this mask for elements; ghosts are excluded.
    static let elementCategory = 1
    static let ghostCategory = 2

    private var ghostNodes: [String: (node: SCNNode, look: String, element: BoardElement)] = [:]
    private var ghostTrails: [String: SCNNode] = [:]

    var ghostCount: Int { ghostsNode.childNodes.filter { $0.name?.hasPrefix("ghost-") == true }.count }

    func clearGhosts() {
        ghostsNode.childNodes.forEach { $0.removeFromParentNode() }
        ghostNodes.removeAll()
        ghostTrails.removeAll()
        billboardsNeedPruning = true
    }

    /// Rebuilds the translucent previous (cool) and next (warm) copies of elements whose pose
    /// differs from `live`, each with a faint dotted ground trail to the live element. Call only
    /// when the frame, the toggle or the document changes.
    func updateGhosts(previous: [BoardElement], next: [BoardElement], live: [BoardElement]) {
        guard let field else { clearGhosts(); return }
        let current = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Ghost nodes are reused: only their transforms change while the same pair of frames is shown,
        // which keeps scrubbing with onion skin cheap.
        var reused = Set<String>()
        for (elements, warm) in [(previous, false), (next, true)] {
            let tint = warm ? UIColor(red: 1, green: 0.62, blue: 0.3, alpha: 1) : UIColor(red: 0.42, green: 0.7, blue: 1, alpha: 1)
            for ghost in elements.sorted(by: { $0.kind.zOrder < $1.kind.zOrder }) {
                guard let now = current[ghost.id], ghost.pose != now.pose else { continue }
                let name = "ghost-\(warm ? "next" : "previous")-\(ghost.id.uuidString)"
                reused.insert(name)
                if let existing = ghostNodes[name], existing.look == lookKey(ghost) {
                    if ghost.kind.isPoint { applyTransform(existing.node, element: ghost, field: field) }
                    else if existing.element != ghost {
                        rebuildPathGeometry(existing.node, path: PathKey(element: ghost, line: Board3DLineSpec.make(ghost)), field: field)
                        ghostify(existing.node, tint: tint, key: warm ? "next" : "previous")
                    }
                    ghostNodes[name] = (existing.node, existing.look, ghost)
                    addGhostTrail(from: ghost.pivot, to: now.pivot, tint: tint, key: warm ? "next" : "previous", field: field, name: name)
                    continue
                }
                ghostNodes[name]?.node.removeFromParentNode()
                let node = SCNNode()
                node.name = name
                if ghost.kind.isPoint {
                    buildPointNode(node, element: ghost, field: field)
                    node.childNode(withName: "label", recursively: false)?.removeFromParentNode()
                } else {
                    rebuildPathGeometry(node, path: PathKey(element: ghost, line: Board3DLineSpec.make(ghost)), field: field)
                    node.childNode(withName: "length-label", recursively: false)?.removeFromParentNode()
                }
                ghostify(node, tint: tint, key: warm ? "next" : "previous")
                node.opacity = 0.28
                ghostsNode.addChildNode(node)
                ghostNodes[name] = (node, lookKey(ghost), ghost)
                addGhostTrail(from: ghost.pivot, to: now.pivot, tint: tint, key: warm ? "next" : "previous", field: field, name: name)
            }
        }
        for (name, entry) in ghostNodes where !reused.contains(name) {
            entry.node.removeFromParentNode()
            ghostNodes[name] = nil
            billboardsNeedPruning = true
        }
    }

    private func ghostify(_ root: SCNNode, tint: UIColor, key: String) {
        root.enumerateHierarchy { node, _ in
            node.castsShadow = false
            node.categoryBitMask = Self.ghostCategory
            guard let geometry = node.geometry else { return }
            // Share vertex data; only the materials are ghost variants (cached per original material).
            let copy = geometry.copy() as? SCNGeometry ?? geometry
            copy.materials = geometry.materials.map { ghostMaterial($0, tint: tint, key: key) }
            node.geometry = copy
        }
    }

    private func ghostMaterial(_ original: SCNMaterial, tint: UIColor, key: String) -> SCNMaterial {
        let make: () -> SCNMaterial = {
            let m = original.copy() as? SCNMaterial ?? SCNMaterial()
            m.multiply.contents = tint
            m.emission.contents = tint.withAlphaComponent(1)
            m.emission.intensity = 0.45
            m.writesToDepthBuffer = false
            m.blendMode = .alpha
            return m
        }
        // Only a material with a cache key of its own can be cached; anything else (a one-off
        // material built inline) gets a fresh ghost rather than whatever shared an address with it.
        guard let name = original.name else { return make() }
        return material("ghost-\(key)-\(name)", make)
    }

    private func addGhostTrail(from: BoardPoint, to: BoardPoint, tint: UIColor, key: String, field: BoardFieldType, name: String) {
        ghostTrails[name]?.removeFromParentNode()
        ghostTrails[name] = nil
        let a = planar(from, field), b = planar(to, field)
        guard simd_distance(a, b) > 0.5 * unit(field) else { return }
        var mesh = Board3DMesh()
        addLine(&mesh, points: [a, b], spec: Board3DLineSpec(vertices: [], style: BoardLineStyle(pattern: .dotted, endCap: .none, width: 0.6)), halfWidth: 0.16 * unit(field), closed: false, unit: unit(field))
        guard !mesh.isEmpty else { return }
        let geometry = mesh.geometry()
        geometry.firstMaterial = material("ghost-trail-\(key)") {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = tint
            m.transparency = 0.55
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            return m
        }
        let trail = SCNNode(geometry: geometry)
        trail.name = "trail"
        ghostTrails[name] = trail
        trail.castsShadow = false
        trail.categoryBitMask = Self.ghostCategory
        ghostsNode.addChildNode(trail)
    }

    // MARK: Selection

    private var selectionElement: BoardElement?
    /// Field position the current outline was built around, so a drag can move the node instead of
    /// rebuilding the mesh on every frame.
    private var selectionAnchor: SIMD3<Double> = .zero

    /// True when `b` is `a` moved: everything that shapes the outline is identical and every extra
    /// point moved with the position. This is exactly what a drag produces.
    private static func isTranslation(_ a: BoardElement, _ b: BoardElement) -> Bool {
        guard a.points.count == b.points.count else { return false }
        let dx = b.position.x - a.position.x, dy = b.position.y - a.position.y
        var moved = a
        moved.position = b.position
        for (p, q) in zip(a.points, b.points) where abs(p.x + dx - q.x) > 1e-9 || abs(p.y + dy - q.y) > 1e-9 { return false }
        moved.points = b.points
        return moved == b
    }

    private func updateSelection(_ element: BoardElement?, field: BoardFieldType) {
        guard let element else { selectionNode.isHidden = true; selectionElement = nil; return }
        selectionNode.isHidden = false
        guard element != selectionElement else { return }
        // Dragging changes only the position, frame after frame: move the outline we already have
        // rather than building the same mesh again at a new place.
        if let previous = selectionElement, Self.isTranslation(previous, element) {
            selectionElement = element
            let p = BoardOrbit.world(element.position, field: field)
            selectionNode.simdPosition = SIMD3(Float(p.x - selectionAnchor.x), 0, Float(p.z - selectionAnchor.z))
            return
        }
        selectionElement = element
        selectionAnchor = BoardOrbit.world(element.position, field: field)
        selectionNode.simdPosition = .zero
        selectionNode.childNodes.forEach { $0.removeFromParentNode() }
        let fs = BoardOrbit.figureScale(field)
        let u = unit(field)
        let glow = flatMaterial("selection", image: Board3DTextures.shared.selectionRing(), blend: .add)
        if element.kind.isPoint {
            let diameter: Double
            switch element.kind {
            case .player, .goalkeeper, .opponent, .mannequin, .coach, .referee: diameter = 1.9 * fs * max(0.3, element.size)
            case .miniGoal: diameter = 3.6 * fs * max(0.3, element.size)
            case .text: diameter = 2.4 * fs * max(0.3, element.size)
            case .ball, .cone, .marker: diameter = 1.2 * fs * max(0.3, element.size)
            default: diameter = 2.3 * element.visualRadiusMeters(field: field)
            }
            let size = CGFloat(diameter)
            let ring = SCNNode(geometry: SCNPlane(width: size, height: size))
            ring.geometry?.firstMaterial = glow
            ring.eulerAngles.x = -.pi / 2
            ring.castsShadow = false
            ring.renderingOrder = 50
            let p = BoardOrbit.world(element.position, field: field, y: 0.03)
            ring.simdPosition = SIMD3(Float(p.x), Float(p.y), Float(p.z))
            selectionNode.addChildNode(ring)
        } else {
            let outline: [SIMD2<Double>]
            let closed = element.kind.isArea
            if closed {
                outline = areaOutline(element, field: field)
            } else {
                outline = Board3DLineSpec.make(element).map { centreline($0, field: field) } ?? element.allPoints.map { planar($0, field) }
            }
            var mesh = Board3DMesh()
            addLine(&mesh, points: outline, spec: Board3DLineSpec(vertices: []), halfWidth: 1.4 * u, closed: closed, unit: u)
            guard !mesh.isEmpty else { return }
            let geometry = mesh.geometry()
            geometry.firstMaterial = material("selection-path") {
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = BoardPalette.uiColor(BoardPalette.lime)
                m.transparency = 0.3
                m.blendMode = .add
                m.writesToDepthBuffer = false
                return m
            }
            let glowNode = SCNNode(geometry: geometry)
            glowNode.castsShadow = false
            glowNode.renderingOrder = 50
            selectionNode.addChildNode(glowNode)
        }
    }
}
