import AVFoundation
import SceneKit
import UIKit
import XCTest
import simd
@testable import Camelot

final class TacticalBoard3DTests: XCTestCase {
    /// Wall-clock budgets are only enforced when asked for: this machine runs other builds at the
    /// same time, so a strict ceiling here fails for reasons that have nothing to do with the code.
    /// Run with `TEST_RUNNER_BOARD3D_STRICT_PERF=1` on an idle machine for the real numbers.
    static let strictPerformance = ProcessInfo.processInfo.environment["BOARD3D_STRICT_PERF"] == "1"

    /// Player photos go to a temporary folder, never the real Documents of the hosting app.
    private var photoRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        photoRoot = FileManager.default.temporaryDirectory.appending(path: "board3d-photos-\(UUID().uuidString)", directoryHint: .isDirectory)
        SquadPhotoStore.rootDirectory = photoRoot
    }

    override func tearDownWithError() throws {
        SquadPhotoStore.rootDirectory = URL.documentsDirectory
        if let photoRoot { try? FileManager.default.removeItem(at: photoRoot) }
        try super.tearDownWithError()
    }

    // MARK: Fixtures

    private func sampleDocument(field: BoardFieldType = .footballFull, style: BoardFieldStyle? = nil, angle: BoardViewAngle = .tilted) -> BoardDocument {
        var document = BoardDocument()
        document.fieldType = field
        document.viewAngle = angle
        document.style = style
        var elements: [BoardElement] = []
        let home: [(Double, Double, Int)] = [(0.08, 0.5, 1), (0.22, 0.2, 2), (0.2, 0.4, 4), (0.2, 0.6, 5), (0.22, 0.8, 3), (0.4, 0.35, 8), (0.38, 0.62, 6), (0.52, 0.5, 10), (0.62, 0.18, 7), (0.66, 0.5, 9), (0.62, 0.82, 11)]
        for (x, y, number) in home {
            var player = BoardElement(kind: number == 1 ? .goalkeeper : .player, position: BoardPoint(x, y), colorHex: number == 1 ? BoardPalette.keeper : BoardPalette.home, number: number)
            player.rotation = number == 1 ? 0 : -10
            if number == 9 { player.label = "Nico" }
            elements.append(player)
        }
        for (x, y, number) in [(0.72, 0.4, 4), (0.74, 0.62, 5), (0.58, 0.34, 6), (0.93, 0.5, 1)] {
            var opponent = BoardElement(kind: .opponent, position: BoardPoint(x, y), colorHex: BoardPalette.away, number: number)
            opponent.rotation = 180
            elements.append(opponent)
        }
        elements.append(BoardElement(kind: .ball, position: BoardPoint(0.535, 0.52)))
        var pass = BoardElement(kind: .arrow, position: BoardPoint(0.52, 0.5), points: [BoardPoint(0.62, 0.2)], colorHex: BoardPalette.white)
        pass.arrowStyle = .pass
        var run = BoardElement(kind: .arrow, position: BoardPoint(0.62, 0.82), points: [BoardPoint(0.84, 0.66), BoardPoint(0.78, 0.86)], colorHex: BoardPalette.lime)
        run.arrowStyle = .run; run.isCurved = true
        var dribble = BoardElement(kind: .arrow, position: BoardPoint(0.66, 0.5), points: [BoardPoint(0.82, 0.46)], colorHex: BoardPalette.orange)
        dribble.arrowStyle = .dribble
        var zone = BoardElement(kind: .zone, position: BoardPoint(0.7, 0.28), points: [BoardPoint(0.9, 0.72)], colorHex: BoardPalette.keeper)
        zone.opacity = 0.22
        var ellipse = BoardElement(kind: .zone, position: BoardPoint(0.3, 0.3), points: [BoardPoint(0.45, 0.7)], colorHex: BoardPalette.purple)
        ellipse.zoneShape = .ellipse; ellipse.opacity = 0.18
        var text = BoardElement(kind: .text, position: BoardPoint(0.8, 0.12), colorHex: BoardPalette.white)
        text.label = "Press high"
        elements += [zone, ellipse, pass, run, dribble, text]
        elements.append(BoardElement(kind: .cone, position: BoardPoint(0.45, 0.9), colorHex: BoardPalette.orange))
        elements.append(BoardElement(kind: .cone, position: BoardPoint(0.5, 0.9), colorHex: BoardPalette.orange))
        elements.append(BoardElement(kind: .marker, position: BoardPoint(0.55, 0.9), colorHex: BoardPalette.pink))
        var goal = BoardElement(kind: .miniGoal, position: BoardPoint(0.3, 0.92), colorHex: BoardPalette.white)
        goal.rotation = 0
        elements.append(goal)
        elements.append(BoardElement(kind: .mannequin, position: BoardPoint(0.82, 0.3), colorHex: BoardPalette.lime))
        elements.append(BoardElement(kind: .polygon, position: BoardPoint(0.1, 0.1), points: [BoardPoint(0.25, 0.08), BoardPoint(0.2, 0.2), BoardPoint(0.15, 0.14), BoardPoint(0.08, 0.22)], colorHex: BoardPalette.green))
        document.elements = elements
        return document
    }

    private func phoneDocument() throws -> BoardDocument {
        try JSONDecoder().decode(BoardDocument.self, from: Data(Self.phoneBoardJSON.utf8))
    }

    // MARK: Camera maths

    func testOrbitPlacesEyeAtDistanceAlongElevationAndAzimuthRelativeToViewport() {
        let camera = BoardCamera(azimuthDegrees: 0, elevationDegrees: 30, distanceScale: 1)
        let landscape = CGSize(width: 800, height: 450), portrait = CGSize(width: 390, height: 760)
        let orbit = BoardOrbit(field: .footballFull, camera: camera, viewport: landscape, framing: BoardFraming(distance: 150))
        let offset = orbit.eye - orbit.target
        XCTAssertEqual(simd_length(offset), 150, accuracy: 1e-6)
        XCTAssertEqual(asin(offset.y / orbit.distance) * 180 / .pi, 30, accuracy: 1e-6)
        XCTAssertGreaterThan(offset.z, 0, "Landscape azimuth 0 sits on the v = 1 touchline, like the top view")
        XCTAssertEqual(offset.x, 0, accuracy: 1e-6)
        let centre = orbit.project(orbit.target)!
        XCTAssertEqual(centre.x, 400, accuracy: 1e-6)
        XCTAssertEqual(centre.y, 225, accuracy: 1e-6)
        XCTAssertGreaterThan(orbit.project(BoardOrbit.world(BoardPoint(1, 0.5), field: .footballFull))!.x, 400, "u = 1 is on the right")

        let upright = BoardOrbit(field: .footballFull, camera: camera, viewport: portrait, framing: BoardFraming(distance: 150))
        XCTAssertGreaterThan((upright.eye - upright.target).x, 0, "Portrait azimuth 0 sits behind the u = 1 goal line")
        let half = BoardOrbit(field: .footballHalf, camera: camera, viewport: portrait, framing: BoardFraming(distance: 150))
        XCTAssertGreaterThan((half.eye - half.target).z, 0, "The half pitch does not turn in portrait")
    }

    func testCameraIsClamped() {
        let low = BoardOrbit.clamped(BoardCamera(azimuthDegrees: 400, elevationDegrees: -20, distanceScale: 50, target: BoardPoint(2, -1)))
        XCTAssertEqual(low.elevationDegrees, BoardOrbit.elevationRange.lowerBound)
        XCTAssertEqual(low.distanceScale, BoardOrbit.distanceScaleRange.upperBound)
        XCTAssertEqual(low.target, BoardPoint(1, 0))
        XCTAssertEqual(low.azimuthDegrees, 40, accuracy: 1e-9)
        let high = BoardOrbit.orbited(BoardCamera(azimuthDegrees: 0, elevationDegrees: 80, distanceScale: 1), by: CGSize(width: 0, height: 500))
        XCTAssertEqual(high.elevationDegrees, BoardOrbit.elevationRange.upperBound)
    }

    func testFramingFitsTheFieldSnuglyAndCentred() {
        let viewports = [CGSize(width: 390, height: 600), CGSize(width: 844, height: 330), CGSize(width: 1080, height: 1080), CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)]
        for viewport in viewports {
            for camera in [BoardViewAngle.tilted.defaultCamera, BoardViewAngle.broadcast.defaultCamera, BoardCamera(azimuthDegrees: 57, elevationDegrees: 30, distanceScale: 1)] {
                for field in BoardFieldType.allCases {
                    let orbit = BoardOrbit(field: field, camera: camera, viewport: viewport)
                    let screen = BoardOrbit.framedPoints(field).map { orbit.project($0)! }
                    let minX = screen.map(\.x).min()!, maxX = screen.map(\.x).max()!
                    let minY = screen.map(\.y).min()!, maxY = screen.map(\.y).max()!
                    let label = "\(field) az \(camera.azimuthDegrees) \(viewport)"
                    XCTAssert(minX >= 0 && maxX <= viewport.width && minY >= 0 && maxY <= viewport.height, "\(label) is off screen")
                    XCTAssertEqual((minX + maxX) / 2, viewport.width / 2, accuracy: viewport.width * 0.01, "\(label) is not centred horizontally")
                    XCTAssertEqual((minY + maxY) / 2, viewport.height / 2, accuracy: viewport.height * 0.01, "\(label) is not centred vertically")
                    let fill = max((maxX - minX) / viewport.width / BoardOrbit.fillX, (maxY - minY) / viewport.height / BoardOrbit.fillY)
                    XCTAssertEqual(fill, 1, accuracy: 0.01, "\(label) is not a snug fit")
                }
            }
        }
    }

    func testFixedFramingKeepsDistanceStableWhileOrbiting() {
        let viewport = CGSize(width: 390, height: 600)
        var camera = BoardViewAngle.tilted.defaultCamera
        let framing = BoardOrbit.framing(field: .footballFull, camera: camera, viewport: viewport)
        let start = BoardOrbit(field: .footballFull, camera: camera, viewport: viewport, framing: framing)
        for _ in 0..<10 {
            camera = BoardOrbit.orbited(camera, by: CGSize(width: 25, height: -4))
            let orbit = BoardOrbit(field: .footballFull, camera: camera, viewport: viewport, framing: framing)
            XCTAssertEqual(orbit.distance, start.distance, accuracy: 1e-9)
        }
        XCTAssertNotEqual(BoardOrbit.framing(field: .footballFull, camera: camera, viewport: viewport), framing, "A new angle solves a new fit")
    }

    func testGroundRayRoundTripsToFieldPoint() {
        let viewport = CGSize(width: 390, height: 760)
        let orbit = BoardOrbit(field: .futsal, camera: BoardCamera(azimuthDegrees: 37, elevationDegrees: 41, distanceScale: 0.8, target: BoardPoint(0.4, 0.6)), viewport: viewport)
        for point in [BoardPoint(0.5, 0.5), BoardPoint(0.1, 0.9), BoardPoint(0.8, 0.25)] {
            guard let screen = orbit.project(BoardOrbit.world(point, field: .futsal)), let back = orbit.boardPoint(at: screen) else {
                return XCTFail("\(point) did not project")
            }
            XCTAssertEqual(back.x, point.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-6)
        }
        XCTAssertNil(orbit.groundPoint(at: CGPoint(x: 195, y: -5000)), "Above the horizon misses the ground")
    }

    func testPinchZoomKeepsGroundPointUnderFingers() {
        let viewport = CGSize(width: 390, height: 760)
        let field = BoardFieldType.footballFull
        let start = BoardCamera(azimuthDegrees: 20, elevationDegrees: 35, distanceScale: 1)
        let anchor = CGPoint(x: 250, y: 470)
        let before = BoardOrbit(field: field, camera: start, viewport: viewport)
        let grip = before.groundPoint(at: anchor)!
        let zoomed = BoardOrbit.zoomed(start, field: field, viewport: viewport, by: 1.8, anchor: anchor)
        XCTAssertEqual(zoomed.distanceScale, 1 / 1.8, accuracy: 1e-9)
        let after = BoardOrbit(field: field, camera: zoomed, viewport: viewport)
        let screen = after.project(grip)!
        XCTAssertEqual(screen.x, anchor.x, accuracy: 0.5)
        XCTAssertEqual(screen.y, anchor.y, accuracy: 0.5)
        XCTAssertLessThan(after.distance, before.distance)

        let panned = BoardOrbit.panned(zoomed, field: field, viewport: viewport, from: anchor, to: CGPoint(x: 200, y: 420))
        let moved = BoardOrbit(field: field, camera: panned, viewport: viewport).project(grip)!
        XCTAssertEqual(moved.x, 200, accuracy: 0.5)
        XCTAssertEqual(moved.y, 420, accuracy: 0.5)

        // Zooming out past the limit clamps the distance and keeps the target on the field.
        var far = start
        for _ in 0..<20 { far = BoardOrbit.zoomed(far, field: field, viewport: viewport, by: 0.5, anchor: CGPoint(x: 10, y: 20)) }
        XCTAssertEqual(far.distanceScale, BoardOrbit.distanceScaleRange.upperBound)
        XCTAssert((0...1).contains(far.target.x) && (0...1).contains(far.target.y))
        XCTAssertGreaterThan(BoardOrbit(field: field, camera: far, viewport: viewport).eye.y, 0)
    }

    // MARK: Scene

    func testSceneCreatesOneNodePerElementAndUpdatesWithoutRebuilding() throws {
        var document = sampleDocument()
        let scene = TacticalBoard3DScene()
        scene.update(document: document, time: nil, selectedID: nil)
        XCTAssertEqual(scene.elementCount, document.elements.count)

        let player = try XCTUnwrap(document.elements.first { $0.kind == .player })
        let node = try XCTUnwrap(scene.node(for: player.id))
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        document.keyframes[1].poses[player.id]?.position = BoardPoint(0.9, 0.1)
        scene.update(document: document, time: document.frameStart(1), selectedID: player.id)
        XCTAssertEqual(scene.elementCount, document.elements.count)
        XCTAssert(scene.node(for: player.id) === node, "Moving an element keeps its node")
        let expected = BoardOrbit.world(BoardPoint(0.9, 0.1), field: document.fieldType)
        XCTAssertEqual(Double(node.simdPosition.x), expected.x, accuracy: 1e-3)
        XCTAssertEqual(Double(node.simdPosition.z), expected.z, accuracy: 1e-3)

        let removed = document.elements.removeLast()
        scene.update(document: document, time: nil, selectedID: nil)
        XCTAssertNil(scene.node(for: removed.id))
        XCTAssertEqual(scene.elementCount, document.elements.count)
    }

    func testRotationAndSizeApplyToNodeTransform() throws {
        var document = BoardDocument()
        document.fieldType = .futsal
        document.viewAngle = .tilted
        var player = BoardElement(kind: .player, position: BoardPoint(0.25, 0.75), number: 4)
        player.rotation = 90
        player.size = 1.5
        document.elements = [player]
        let scene = TacticalBoard3DScene()
        scene.update(document: document, time: nil, selectedID: nil)
        let node = try XCTUnwrap(scene.node(for: player.id))
        XCTAssertEqual(Double(node.simdScale.x), 1.5 * BoardOrbit.figureScale(.futsal), accuracy: 1e-4)
        // Rotation is clockwise on the top view: the +x front turns towards +z (down the board).
        let front = node.simdConvertVector(SIMD3(1, 0, 0), to: nil)
        XCTAssertEqual(Double(front.z) / Double(simd_length(front)), 1, accuracy: 1e-3)
        XCTAssertEqual(Double(front.x), 0, accuracy: 1e-3)
    }

    func testTriangulatesConcavePolygon() {
        let points: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(2, 1), SIMD2(0, 4)]
        let triangles = Board3DMesh.triangulate(points)
        XCTAssertEqual(triangles.count, 3)
        let area = triangles.reduce(0.0) { sum, t in
            let a = points[t.0], b = points[t.1], c = points[t.2]
            return sum + abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
        XCTAssertEqual(area, 16 - 6, accuracy: 1e-9)
    }

    // MARK: Training library

    private static let trainingKinds: [BoardElementKind] = [.tallCone, .domeCone, .pole, .hurdle, .ladder, .ring, .wall, .goal, .popUpGoal, .rebounder, .flag, .ballCart, .coach, .referee, .stepMarker]

    private func trainingDocument(field: BoardFieldType = .footballHalf) -> BoardDocument {
        var document = BoardDocument()
        document.fieldType = field
        document.viewAngle = .tilted
        let colours = [BoardPalette.orange, BoardPalette.keeper, BoardPalette.pink, BoardPalette.lime, BoardPalette.home, BoardPalette.orange, BoardPalette.away,
                       BoardPalette.white, BoardPalette.home, BoardPalette.green, BoardPalette.keeper, BoardPalette.white, BoardPalette.white, BoardPalette.white, BoardPalette.purple]
        for (index, kind) in Self.trainingKinds.enumerated() {
            let column = index % 5, row = index / 5
            var element = BoardElement(kind: kind, position: BoardPoint(0.15 + Double(column) * 0.175, 0.25 + Double(row) * 0.25), colorHex: colours[index])
            if kind == .stepMarker { element.number = 3 }
            if kind == .wall { element.count = 4 }
            if kind == .hurdle || kind == .ladder { element.rotation = 90 }
            element.rotation += kind == .coach || kind == .referee ? 200 : 0
            document.elements.append(element)
        }
        return document
    }

    func testTrainingElementsBuildOneNodeEachWithTransforms() throws {
        var document = trainingDocument()
        for index in document.elements.indices {
            document.elements[index].rotation = 30
            document.elements[index].size = 1.3
        }
        let scene = TacticalBoard3DScene()
        scene.update(document: document, time: nil, selectedID: document.elements[0].id)
        XCTAssertEqual(scene.elementCount, Self.trainingKinds.count)
        let fs = BoardOrbit.figureScale(document.fieldType)
        for element in document.elements {
            let node = try XCTUnwrap(scene.node(for: element.id), "\(element.kind)")
            XCTAssertFalse(node.childNodes.isEmpty, "\(element.kind) has geometry")
            let expected = BoardOrbit.world(element.position, field: document.fieldType)
            XCTAssertEqual(Double(node.simdPosition.x), expected.x, accuracy: 1e-3, "\(element.kind)")
            XCTAssertEqual(Double(node.simdPosition.z), expected.z, accuracy: 1e-3, "\(element.kind)")
            XCTAssertEqual(Double(node.simdEulerAngles.y), -30 * .pi / 180, accuracy: 1e-4, "\(element.kind) turns")
            let scale: Double = switch element.kind {
            case .goal: 1
            case .ladder: fs
            default: fs * 1.3
            }
            XCTAssertEqual(Double(node.simdScale.x), scale, accuracy: 1e-4, "\(element.kind) size")
        }
        XCTAssertNotNil(TacticalBoard3DRenderer.image(document: document, time: nil, size: CGSize(width: 300, height: 200), scale: 1))
    }

    private func capsuleCount(_ node: SCNNode) -> Int {
        node.childNodes(passingTest: { child, _ in child.geometry is SCNCapsule }).count
    }

    func testWallHonoursCountAndLadderSizeChangesItsLength() throws {
        var document = trainingDocument()
        let wallIndex = try XCTUnwrap(document.elements.firstIndex { $0.kind == .wall })
        let ladderIndex = try XCTUnwrap(document.elements.firstIndex { $0.kind == .ladder })
        let scene = TacticalBoard3DScene()
        document.elements[wallIndex].count = 3
        scene.update(document: document, time: nil, selectedID: nil)
        XCTAssertEqual(capsuleCount(try XCTUnwrap(scene.node(for: document.elements[wallIndex].id))), 3)
        let rungs = scene.ladderRungs(document.elements[ladderIndex])
        document.elements[wallIndex].count = 6
        document.elements[ladderIndex].size = 2
        scene.update(document: document, time: nil, selectedID: nil)
        XCTAssertEqual(capsuleCount(try XCTUnwrap(scene.node(for: document.elements[wallIndex].id))), 6)
        XCTAssertLessThanOrEqual(abs(scene.ladderRungs(document.elements[ladderIndex]) - rungs * 2), 1, "Doubling size doubles the ladder")
        document.elements[wallIndex].count = 40
        scene.update(document: document, time: nil, selectedID: nil)
        XCTAssertEqual(capsuleCount(try XCTUnwrap(scene.node(for: document.elements[wallIndex].id))), 6, "Clamped to six")
    }

    func testLineShowsLengthLabel() throws {
        var document = BoardDocument()
        document.fieldType = .futsal
        document.viewAngle = .tilted
        var line = BoardElement(kind: .line, position: BoardPoint(0.25, 0.5), points: [BoardPoint(0.75, 0.5)])
        line.showsLength = true
        let plain = BoardElement(kind: .polyline, position: BoardPoint(0.1, 0.1), points: [BoardPoint(0.2, 0.2), BoardPoint(0.3, 0.1)])
        document.elements = [line, plain]
        let scene = TacticalBoard3DScene()
        scene.update(document: document, time: nil, selectedID: nil)
        XCTAssertNotNil(scene.node(for: line.id)?.childNode(withName: "length-label", recursively: false), "20 m line is labelled")
        XCTAssertNil(scene.node(for: plain.id)?.childNode(withName: "length-label", recursively: false))
    }

    // MARK: Follow paths and onion skin

    /// A player follows a curved line (facing its direction) while the ball runs round a rectangle zone.
    private func followDocument() -> (document: BoardDocument, player: UUID, ball: UUID, line: UUID, zone: UUID) {
        var document = BoardDocument()
        document.fieldType = .footballHalf
        document.viewAngle = .tilted
        var line = BoardElement(kind: .line, position: BoardPoint(0.2, 0.75), points: [BoardPoint(0.8, 0.7), BoardPoint(0.5, 0.25)], colorHex: BoardPalette.lime)
        line.isCurved = true
        var zone = BoardElement(kind: .zone, position: BoardPoint(0.25, 0.1), points: [BoardPoint(0.75, 0.35)], colorHex: BoardPalette.keeper)
        zone.opacity = 0.18
        let player = BoardElement(kind: .player, position: BoardPoint(0.2, 0.75), colorHex: BoardPalette.home, number: 7)
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.25, 0.1))
        document.elements = [line, zone, player, ball]
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        document.keyframes[0].duration = 2
        document.keyframes[0].paths = [
            player.id: BoardFollowPath(pathID: line.id, facesDirection: true),
            ball.id: BoardFollowPath(pathID: zone.id),
        ]
        document.keyframes[1].poses[player.id]?.position = BoardPoint(0.8, 0.7)
        return (document, player.id, ball.id, line.id, zone.id)
    }

    private func distanceToPath(_ point: BoardPoint, _ samples: [BoardPoint], field: BoardFieldType) -> Double {
        let p = BoardOrbit.world(point, field: field)
        return zip(samples, samples.dropFirst()).map { a, b in
            let wa = BoardOrbit.world(a, field: field), wb = BoardOrbit.world(b, field: field)
            let ab = wb - wa
            let t = max(0, min(1, simd_dot(p - wa, ab) / max(1e-9, simd_dot(ab, ab))))
            return simd_distance(p, wa + ab * t)
        }.min() ?? .infinity
    }

    func testFollowPathMovesNodesAlongThePathWithoutRebuildingGeometry() throws {
        let (document, playerID, ballID, lineID, zoneID) = followDocument()
        let field = document.fieldType
        let scene = TacticalBoard3DScene()
        scene.update(document: document, time: 0, selectedID: nil)
        let lineGeometry = try XCTUnwrap(scene.node(for: lineID)?.childNodes.first?.geometry)
        let zoneGeometry = try XCTUnwrap(scene.node(for: zoneID)?.childNodes.first?.geometry)
        let playerNode = try XCTUnwrap(scene.node(for: playerID))
        var previous = playerNode.simdPosition
        for time in [0.5, 1.0, 1.5] {
            scene.update(document: document, time: time, selectedID: nil)
            let resolved = document.elements(at: time)
            for (id, pathIndex) in [(playerID, 0), (ballID, 1)] {
                let element = try XCTUnwrap(resolved.first { $0.id == id })
                let node = try XCTUnwrap(scene.node(for: id))
                let expected = BoardOrbit.world(element.position, field: field)
                XCTAssertEqual(Double(node.simdPosition.x), expected.x, accuracy: 1e-3)
                XCTAssertEqual(Double(node.simdPosition.z), expected.z, accuracy: 1e-3)
                let path = try XCTUnwrap(document.keyframes[0].paths?[id])
                let onPath = distanceToPath(BoardOrbit.board(SIMD3(Double(node.simdPosition.x), 0, Double(node.simdPosition.z)), field: field), document.pathSamples(pathID: path.pathID, frame: 0, count: 256), field: field)
                XCTAssertLessThan(onPath, 0.25, "\(pathIndex == 0 ? "player" : "ball") at \(time) s lies on its path")
                if id == playerID {
                    XCTAssertEqual(Double(node.simdEulerAngles.y), -element.rotation * .pi / 180, accuracy: 1e-3, "Facing follows the path")
                }
            }
            XCTAssertNotEqual(playerNode.simdPosition, previous, "The player moves")
            previous = playerNode.simdPosition
            XCTAssert(scene.node(for: playerID) === playerNode)
            XCTAssert(scene.node(for: lineID)?.childNodes.first?.geometry === lineGeometry, "Path meshes are not rebuilt per frame")
            XCTAssert(scene.node(for: zoneID)?.childNodes.first?.geometry === zoneGeometry)
        }
        XCTAssertNotEqual(document.elements(at: 0.5).first { $0.id == playerID }?.rotation, document.elements(at: 1.5).first { $0.id == playerID }?.rotation, "Facing turns along the curve")
    }

    func testOnionSkinGhostsOnlyChangedElementsAndNeverInExports() throws {
        var document = BoardDocument()
        document.fieldType = .futsal
        document.viewAngle = .tilted
        let runner = BoardElement(kind: .player, position: BoardPoint(0.3, 0.5), colorHex: BoardPalette.home, number: 4)
        let cone = BoardElement(kind: .cone, position: BoardPoint(0.6, 0.6), colorHex: BoardPalette.orange)
        document.elements = [runner, cone]
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        document.keyframes[1].poses[runner.id]?.position = BoardPoint(0.7, 0.3)
        let scene = TacticalBoard3DScene()
        document.showFrame(0)
        scene.update(document: document, time: nil, selectedID: nil)
        var skin = document.onionSkin(aroundFrame: 0)
        scene.updateGhosts(previous: skin.previous, next: skin.next, live: document.elements(at: nil))
        XCTAssertEqual(scene.ghostCount, 1, "Only the runner moves into frame 2")
        XCTAssertEqual(scene.elementCount, 2, "Ghosts are not elements")
        var categories = Set<Int>()
        scene.ghostsNode.enumerateHierarchy { node, _ in categories.insert(node.categoryBitMask) }
        categories.remove(scene.ghostsNode.categoryBitMask)
        XCTAssertEqual(categories, [TacticalBoard3DScene.ghostCategory], "Ghosts are excluded from hit tests")
        XCTAssertNotNil(scene.ghostsNode.childNode(withName: "trail", recursively: false), "A dotted trail joins ghost and element")

        document.showFrame(1)
        skin = document.onionSkin(aroundFrame: 1)
        scene.update(document: document, time: nil, selectedID: nil)
        scene.updateGhosts(previous: skin.previous, next: skin.next, live: document.elements(at: nil))
        XCTAssertEqual(scene.ghostCount, 1)
        XCTAssertTrue(scene.ghostsNode.childNodes.contains { $0.name?.hasPrefix("ghost-previous-") == true })

        let offscreen = try XCTUnwrap(TacticalBoard3DOffscreen())
        _ = offscreen.image(document: document, time: nil, pixelSize: CGSize(width: 64, height: 64), onionFrame: 1)
        XCTAssertEqual(offscreen.builder.ghostCount, 1)
        _ = offscreen.image(document: document, time: nil, pixelSize: CGSize(width: 64, height: 64))
        XCTAssertEqual(offscreen.builder.ghostCount, 0, "Exports never show ghosts")
    }

    // MARK: Camera animation

    /// Three stages; camera keys on stages 1 and 2 (stage 0 holds the first key).
    private func cameraDocument() -> BoardDocument {
        var document = sampleDocument(field: .footballFull, style: .grass, angle: .tilted)
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        document.insertKeyframe(after: 1)
        for index in document.keyframes.indices { document.keyframes[index].duration = 1.5 }
        document.keyframes[1].camera = BoardCamera(azimuthDegrees: 0, elevationDegrees: 40, distanceScale: 1)
        document.keyframes[2].camera = BoardCamera(azimuthDegrees: 50, elevationDegrees: 24, distanceScale: 0.55, target: BoardPoint(0.6, 0.5))
        return document
    }

    func testOffscreenFramesFollowTheCameraTrack() throws {
        let document = cameraDocument()
        XCTAssertTrue(document.animatesCamera)
        let offscreen = try XCTUnwrap(TacticalBoard3DOffscreen())
        let size = CGSize(width: 320, height: 180)
        var eyes: [SIMD3<Double>] = []
        for time in [0, document.frameStart(1), document.frameStart(1) + 0.75, document.frameStart(2), document.duration] {
            _ = offscreen.image(document: document, time: time, pixelSize: size)
            let expected = BoardOrbit(field: document.fieldType, camera: document.camera(at: time), viewport: size).eye
            let transform = offscreen.builder.cameraNode.simdTransform
            let eye = SIMD3<Double>(Double(transform.columns.3.x), Double(transform.columns.3.y), Double(transform.columns.3.z))
            XCTAssertLessThan(simd_distance(eye, expected), 0.05, "Camera at \(time) s")
            eyes.append(eye)
        }
        XCTAssertGreaterThan(simd_distance(eyes[1], eyes[3]), 1, "The camera moves between the keys")
        // Stills keep the board's camera.
        _ = offscreen.image(document: document, time: nil, pixelSize: size)
        let still = BoardOrbit(field: document.fieldType, camera: document.cameraOrDefault, viewport: size).eye
        let transform = offscreen.builder.cameraNode.simdTransform
        XCTAssertLessThan(simd_distance(SIMD3(Double(transform.columns.3.x), Double(transform.columns.3.y), Double(transform.columns.3.z)), still), 0.05)
    }

    func testCameraAnimatedVideoExportHasExpectedDuration() async throws {
        let document = cameraDocument()
        let directory = FileManager.default.temporaryDirectory.appending(path: "board3d-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = BoardExportRequest(document: document, name: "Camera move")
        request.format = .mp4
        request.framing = .square
        let url = try await TacticalBoardExporter.export(request, to: directory)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, document.duration, accuracy: 0.05)
    }

    @MainActor
    func testLiveViewAppliesInterpolatedCameraDuringPlaybackWithoutNewNodes() throws {
        let document = cameraDocument()
        let coordinator = Board3DCoordinator()
        let view = Board3DSCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        coordinator.attach(view)
        func representable(_ time: Double?) -> Board3DSceneView {
            Board3DSceneView(document: document, time: time, selectedID: nil, camera: .constant(document.cameraOrDefault), onSelect: { _ in }, onMove: { _, _, _ in }, onionFrame: nil)
        }
        coordinator.update(from: representable(0))
        let nodes = coordinator.builder.scene.rootNode.childNodes(passingTest: { _, _ in true }).count
        for time in stride(from: 0.0, through: document.duration, by: 0.4) {
            coordinator.update(from: representable(time))
            let expected = BoardCameraResolver.pose(for: document, time: time, viewport: view.bounds.size).eye
            let transform = coordinator.builder.cameraNode.simdTransform
            XCTAssertLessThan(simd_distance(SIMD3(Double(transform.columns.3.x), Double(transform.columns.3.y), Double(transform.columns.3.z)), expected), 0.05)
            XCTAssertTrue(coordinator.playingCamera)
        }
        XCTAssertEqual(coordinator.builder.scene.rootNode.childNodes(passingTest: { _, _ in true }).count, nodes, "Playback creates no nodes")
        coordinator.update(from: representable(nil))
        XCTAssertFalse(coordinator.playingCamera, "Stopping playback hands the camera back to the binding")
        XCTAssertEqual(coordinator.appliedCamera, document.cameraOrDefault)
        XCTAssertEqual(coordinator.currentPose?.hiddenSubject, nil)
    }

    // MARK: Camera modes

    /// An attack towards the u = 0 goal, watched by the home keeper there.
    private func attackDocument() -> (document: BoardDocument, keeper: UUID, striker: UUID, ball: UUID) {
        var document = BoardDocument()
        document.fieldType = .footballFull
        document.viewAngle = .broadcast
        var keeper = BoardElement(kind: .goalkeeper, position: BoardPoint(0.04, 0.5), colorHex: BoardPalette.keeper, number: 1)
        keeper.rotation = 0
        var elements = [keeper]
        for (x, y, number) in [(0.16, 0.3, 4), (0.15, 0.5, 5), (0.16, 0.7, 3), (0.3, 0.42, 6)] {
            var defender = BoardElement(kind: .player, position: BoardPoint(x, y), colorHex: BoardPalette.home, number: number)
            defender.rotation = 0
            elements.append(defender)
        }
        var striker = BoardElement(kind: .opponent, position: BoardPoint(0.45, 0.55), colorHex: BoardPalette.away, number: 9)
        striker.rotation = 180
        var winger = BoardElement(kind: .opponent, position: BoardPoint(0.34, 0.18), colorHex: BoardPalette.away, number: 11)
        winger.rotation = 160
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.43, 0.54))
        let referee = BoardElement(kind: .referee, position: BoardPoint(0.5, 0.35))
        elements += [striker, winger, ball, referee]
        document.elements = elements
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        document.keyframes[0].duration = 2
        document.keyframes[1].poses[striker.id]?.position = BoardPoint(0.2, 0.5)
        document.keyframes[1].poses[ball.id]?.position = BoardPoint(0.18, 0.49)
        document.keyframes[1].poses[winger.id]?.position = BoardPoint(0.14, 0.2)
        return (document, keeper.id, striker.id, ball.id)
    }

    func testResolverFreeAndPointOfViewPoses() throws {
        let (document, keeperID, strikerID, ballID) = attackDocument()
        let viewport = CGSize(width: 390, height: 600)
        var free = document.cameraOrDefault
        free.mode = .free
        free.eye = BoardPoint(0.5, 1.1)
        free.eyeHeightMeters = 12
        free.yawDegrees = -90
        free.pitchDegrees = -20
        let freePose = BoardCameraResolver.pose(free, in: document, time: nil, viewport: viewport)
        let expectedEye = BoardOrbit.world(BoardPoint(0.5, 1.1), field: .footballFull, y: 12)
        XCTAssertLessThan(simd_distance(freePose.eye, expectedEye), 1e-9)
        XCTAssertEqual(freePose.forward.z, -cos(20 * .pi / 180), accuracy: 1e-9, "Yaw -90 looks towards v = 0")
        XCTAssertEqual(BoardViewPose.angles(of: freePose.forward).pitch, -20, accuracy: 1e-9)
        XCTAssertEqual(freePose.fieldOfViewDegrees, BoardCameraResolver.freeFieldOfView)

        let keeper = try XCTUnwrap(document.elements.first { $0.id == keeperID })
        let facing = BoardCameraResolver.pose(document.cameraOrDefault.pointOfView(subject: keeperID), in: document, time: nil, viewport: viewport)
        let head = BoardOrbit.world(keeper.position, field: .footballFull, y: BoardCameraResolver.figureEyeHeight * BoardOrbit.figureScale(.footballFull))
        XCTAssertLessThan(simd_distance(SIMD2(facing.eye.x, facing.eye.z), SIMD2(head.x, head.z)), BoardOrbit.figureScale(.footballFull) * 0.3, "Eye at the subject")
        XCTAssertEqual(facing.eye.y, head.y, accuracy: 1e-9, "Eye at head height of the figure")
        XCTAssertLessThan(facing.eye.x, head.x, "A little behind the head")
        XCTAssertGreaterThan(facing.forward.x, 0.95, "Rotation 0 looks towards u = 1")
        XCTAssertEqual(facing.hiddenSubject, keeperID)
        XCTAssertEqual(facing.fieldOfViewDegrees, BoardCameraResolver.pointOfViewFieldOfView)

        let atBall = BoardCameraResolver.pose(document.cameraOrDefault.pointOfView(subject: strikerID, lookAt: .ball), in: document, time: nil, viewport: viewport)
        let ball = try XCTUnwrap(document.elements.first { $0.id == ballID })
        let toBall = BoardOrbit.world(ball.position, field: .footballFull, y: 0.17 * BoardOrbit.figureScale(.footballFull)) - atBall.eye
        XCTAssertGreaterThan(simd_dot(simd_normalize(SIMD2(toBall.x, toBall.z)), simd_normalize(SIMD2(atBall.forward.x, atBall.forward.z))), 0.999, "Turns towards the ball")
        XCTAssertLessThan(atBall.forward.y, -0.5, "and looks down at it")
        let atElement = BoardCameraResolver.pose(document.cameraOrDefault.pointOfView(subject: strikerID, lookAt: .element(keeperID)), in: document, time: nil, viewport: viewport)
        XCTAssertLessThan(atElement.forward.x, -0.9, "Looks back at the keeper")
        let fixed = BoardCameraResolver.pose(document.cameraOrDefault.pointOfView(subject: strikerID, lookAt: .fixed(yawDegrees: 90)), in: document, time: nil, viewport: viewport)
        XCTAssertGreaterThan(fixed.forward.z, 0.95)
    }

    func testPointOfViewFollowsItsSubjectAlongAFollowPath() throws {
        let (document, playerID, _, _, _) = followDocument()
        var camera = document.cameraOrDefault.pointOfView(subject: playerID)
        camera.lookAt = .facing
        let viewport = CGSize(width: 800, height: 450)
        var previous: BoardViewPose?
        for time in stride(from: 0.0, through: 2.0, by: 0.25) {
            let pose = BoardCameraResolver.pose(camera, in: document, time: time, viewport: viewport)
            let subject = try XCTUnwrap(document.elements(at: time).first { $0.id == playerID })
            let at = BoardOrbit.world(subject.position, field: document.fieldType)
            XCTAssertLessThan(simd_distance(SIMD2(pose.eye.x, pose.eye.z), SIMD2(at.x, at.z)), BoardOrbit.figureScale(document.fieldType) * 0.3, "Eye stays on the subject at \(time) s")
            if let previous, time > 0.1, time < 1.9 { XCTAssertGreaterThan(simd_distance(previous.eye, pose.eye), 0.1, "The eye moves") }
            previous = pose
        }
    }

    func testOrbitToPointOfViewKeysBlendSmoothly() throws {
        var (document, keeperID, _, _) = attackDocument()
        document.insertKeyframe(after: 1)
        for index in document.keyframes.indices { document.keyframes[index].duration = 1.5 }
        document.keyframes[0].camera = BoardViewAngle.broadcast.defaultCamera
        document.keyframes[1].camera = document.cameraOrDefault.pointOfView(subject: keeperID, lookAt: .ball)
        document.keyframes[2].camera = BoardCamera(azimuthDegrees: 200, elevationDegrees: 35, distanceScale: 0.8)
        XCTAssertEqual(document.camera(at: 0.2).resolvedMode, .orbit)
        XCTAssertEqual(document.camera(at: document.frameStart(1)).resolvedMode, .pointOfView)
        let viewport = CGSize(width: 1920, height: 1080)
        let size = Double(max(document.fieldType.meters.width, document.fieldType.meters.height))
        var previous: BoardViewPose?
        var largestStep = 0.0, largestTurn = 0.0
        for frame in 0...Int(document.duration * 30) {
            let pose = BoardCameraResolver.pose(for: document, time: Double(frame) / 30, viewport: viewport)
            for value in [pose.eye.x, pose.eye.y, pose.eye.z, pose.forward.x, pose.forward.y, pose.forward.z, pose.fieldOfViewDegrees] {
                XCTAssertTrue(value.isFinite, "Finite at frame \(frame)")
            }
            XCTAssertEqual(simd_length(pose.forward), 1, accuracy: 1e-6)
            if let previous {
                largestStep = max(largestStep, simd_distance(previous.eye, pose.eye))
                largestTurn = max(largestTurn, acos(max(-1, min(1, simd_dot(previous.forward, pose.forward)))) * 180 / .pi)
            }
            previous = pose
        }
        XCTAssertLessThan(largestStep, size * 0.05, "No eye jumps between 30 fps samples")
        XCTAssertLessThan(largestTurn, 8, "No direction jumps between 30 fps samples")
    }

    func testDeletedPointOfViewSubjectFallsBack() throws {
        var (document, keeperID, _, _) = attackDocument()
        let viewport = CGSize(width: 390, height: 600)
        let orbitOnly = document.cameraOrDefault.pointOfView(subject: keeperID)
        document.removeElement(keeperID)
        let fallback = BoardCameraResolver.pose(orbitOnly, in: document, time: nil, viewport: viewport)
        let orbit = BoardCameraResolver.orbitPose(document.cameraOrDefault, field: document.fieldType, viewport: viewport, framing: nil)
        XCTAssertLessThan(simd_distance(fallback.eye, orbit.eye), 1e-6, "No free pose: the default orbit")
        XCTAssertNil(fallback.hiddenSubject)
        var withFree = BoardFreeCamera.reset(document.cameraOrDefault, field: document.fieldType, near: nil)
        withFree = withFree.pointOfView(subject: keeperID)
        let freeFallback = BoardCameraResolver.pose(withFree, in: document, time: nil, viewport: viewport)
        XCTAssertLessThan(simd_distance(freeFallback.eye, try XCTUnwrap(BoardCameraResolver.freePose(withFree, field: document.fieldType)).eye), 1e-9, "The last free pose")
    }

    func testLegacyCameraDecodesAsOrbitAndNewFieldsRoundTrip() throws {
        let legacy = #"{"azimuthDegrees":14,"elevationDegrees":22,"distanceScale":1,"target":{"x":0.5,"y":0.5}}"#
        let camera = try JSONDecoder().decode(BoardCamera.self, from: Data(legacy.utf8))
        XCTAssertEqual(camera.resolvedMode, .orbit)
        XCTAssertNil(camera.subjectID)
        var pov = camera.pointOfView(subject: UUID(), lookAt: .element(UUID()))
        pov.fieldOfViewDegrees = 70
        XCTAssertEqual(try JSONDecoder().decode(BoardCamera.self, from: JSONEncoder().encode(pov)), pov)
        let fixed = camera.pointOfView(subject: UUID(), lookAt: .fixed(yawDegrees: 45))
        XCTAssertEqual(try JSONDecoder().decode(BoardCamera.self, from: JSONEncoder().encode(fixed)), fixed)
        XCTAssertEqual(try decodeLegacyBoard().elements.count, 27, "Old boards still decode")
    }

    private func decodeLegacyBoard() throws -> BoardDocument { try phoneDocument() }

    func testOffscreenPointOfViewHidesTheSubject() throws {
        var (document, keeperID, _, _) = attackDocument()
        document.camera = document.cameraOrDefault.pointOfView(subject: keeperID, lookAt: .ball)
        let offscreen = try XCTUnwrap(TacticalBoard3DOffscreen())
        try assertRendered(offscreen.image(document: document, time: nil, pixelSize: CGSize(width: 480, height: 320)), width: 480, height: 320)
        XCTAssertEqual(offscreen.builder.node(for: keeperID)?.isHidden, true)
        XCTAssertEqual(offscreen.builder.hiddenSubjects, [keeperID])
        document.camera = document.cameraOrDefault.orbiting
        _ = offscreen.image(document: document, time: nil, pixelSize: CGSize(width: 48, height: 32))
        XCTAssertEqual(offscreen.builder.node(for: keeperID)?.isHidden, false, "Back in orbit the keeper shows again")
    }

    func testFreeCameraLookMoveAndHeightClamp() {
        let field = BoardFieldType.footballFull
        var camera = BoardFreeCamera.reset(BoardViewAngle.tilted.defaultCamera, field: field, near: BoardPoint(0.9, 0.5))
        XCTAssertEqual(camera.resolvedMode, .free)
        XCTAssertEqual(camera.yawDegrees, 180, "Behind the u = 1 goal looking back up the field")
        XCTAssertGreaterThan(camera.eye?.x ?? 0, 1)
        camera = BoardFreeCamera.looked(camera, by: CGSize(width: 0, height: 5000))
        XCTAssertEqual(camera.pitchDegrees, BoardFreeCamera.pitchRange.upperBound)
        camera = BoardFreeCamera.looked(camera, by: CGSize(width: 0, height: -9000))
        XCTAssertEqual(camera.pitchDegrees, BoardFreeCamera.pitchRange.lowerBound)
        camera = BoardFreeCamera.raised(camera, by: 0.001)
        XCTAssertEqual(camera.eyeHeightMeters, BoardFreeCamera.heightRange.upperBound)
        camera = BoardFreeCamera.raised(camera, by: 1000)
        XCTAssertEqual(camera.eyeHeightMeters, BoardFreeCamera.heightRange.lowerBound)
        let start = camera.eye!
        camera.yawDegrees = 180
        let walked = BoardFreeCamera.moved(camera, field: field, forward: 10.5, right: 0)
        XCTAssertEqual(walked.eye!.x, start.x - 0.1, accuracy: 1e-9, "Forward follows the look direction")
        XCTAssertEqual(walked.eye!.y, start.y, accuracy: 1e-9)
        let strafed = BoardFreeCamera.moved(walked, field: field, forward: 0, right: 6.8)
        XCTAssertEqual(strafed.eye!.y, start.y - 0.1, accuracy: 1e-9, "Looking towards u = 0, right is towards v = 0")
        let far = BoardFreeCamera.moved(camera, field: field, forward: -10_000, right: 10_000)
        XCTAssertEqual(far.eye!.x, 1 + BoardFreeCamera.margin)
        XCTAssertEqual(far.eye!.y, -BoardFreeCamera.margin)
    }

    // MARK: Squad photos

    /// A generated square "portrait" stored for `id`; removed again at teardown.
    private func storePhoto(for id: UUID, hue: CGFloat) throws {
        let size = CGSize(width: 256, height: 256)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: hue, saturation: 0.35, brightness: 0.75, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.95, green: 0.78, blue: 0.65, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 78, y: 48, width: 100, height: 120))
            UIColor(hue: hue, saturation: 0.8, brightness: 0.35, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 28, y: 170, width: 200, height: 170))
        }
        try SquadPhotoStore.store(try XCTUnwrap(image.jpegData(compressionQuality: 0.9)), for: id)
        addTeardownBlock { SquadPhotoStore.delete(for: id) }
    }

    func testLinkedPlayerShowsPhotoBadgeAndRebuildsWhenThePhotoChanges() throws {
        let playerID = UUID()
        try storePhoto(for: playerID, hue: 0.6)
        var document = BoardDocument()
        document.fieldType = .futsal
        document.viewAngle = .tilted
        var player = BoardElement(kind: .player, position: .center, colorHex: BoardPalette.home, number: 9, label: "Nico")
        player.playerID = playerID
        document.elements = [player]
        let scene = TacticalBoard3DScene()
        // Finding 7: the live scene never reads and decodes a JPEG in its draw pass. The first pass
        // has no photo, the store warms it off-main and says so, and the next pass shows it.
        let warmed = expectation(forNotification: SquadPhotoStore.didWarmPhoto, object: nil)
        scene.update(document: document, time: nil, selectedID: nil)
        XCTAssertNil(scene.photo(for: player), "A cold cache is not decoded on the drawing thread")
        wait(for: [warmed], timeout: 5)

        scene.update(document: document, time: nil, selectedID: nil)
        let node = try XCTUnwrap(scene.node(for: player.id))
        let first = try XCTUnwrap(scene.photo(for: player))
        scene.update(document: document, time: 1, selectedID: nil)
        XCTAssert(scene.node(for: player.id) === node, "The same photo keeps the node")
        try storePhoto(for: playerID, hue: 0.05)
        XCTAssertNotNil(SquadPhotoStore.image(for: playerID), "Warm the replacement as the background task would")
        let second = try XCTUnwrap(scene.photo(for: player))
        XCTAssertNotEqual(first.version, second.version)
        scene.update(document: document, time: nil, selectedID: nil)
        XCTAssert(scene.node(for: player.id) !== node, "A new photo rebuilds the badge")
        let png = try XCTUnwrap(TacticalBoardExporter.imageData(document: document, size: CGSize(width: 200, height: 120), scale: 1, jpeg: false))
        XCTAssertNotNil(UIImage(data: png))

        // Offscreen renders are already off the main thread, so they wait for the photo instead of
        // exporting a face-less badge.
        let offscreen = try XCTUnwrap(TacticalBoard3DOffscreen())
        SquadPhotoStore.rootDirectory = photoRoot  // empties the decoded cache
        XCTAssertNotNil(offscreen.builder.photo(for: player), "Exports read the photo even on a cold cache")
    }

    // MARK: Rendering

    private func assertRendered(_ image: CGImage?, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(image, file: file, line: line)
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let cg = CGContext(data: &pixels, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        var colours = Set<Int>()
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[offset]) / 16, g = Int(pixels[offset + 1]) / 16, b = Int(pixels[offset + 2]) / 16
            colours.insert(r * 256 + g * 16 + b)
        }
        XCTAssertGreaterThan(colours.count, 8, "The render is (nearly) one flat colour", file: file, line: line)
    }

    func testOffscreenImageHasPixelSizeAndContent() throws {
        let image = TacticalBoard3DRenderer.image(document: sampleDocument(), time: nil, size: CGSize(width: 320, height: 180), scale: 2)
        try assertRendered(image, width: 640, height: 360)
    }

    func testPhoneBoardDecodesAndRendersIn3D() throws {
        let document = try phoneDocument()
        XCTAssertEqual(document.viewAngle, .broadcast)
        XCTAssertEqual(document.elements.count, 27)
        XCTAssertEqual(document.keyframes.count, 2)
        let scene = TacticalBoard3DScene()
        scene.update(document: document, time: 0, selectedID: nil)
        XCTAssertEqual(scene.elementCount, document.elements(at: 0).count)
        try assertRendered(TacticalBoard3DRenderer.image(document: document, time: 0.5, size: CGSize(width: 390, height: 760), scale: 1), width: 390, height: 760)
        let png = TacticalBoardExporter.imageData(document: document, size: CGSize(width: 240, height: 150), scale: 2, jpeg: false)
        XCTAssertEqual(png.flatMap { UIImage(data: $0) }?.cgImage?.width, 480)
    }

    func testThreeDVideoExportHasExpectedDurationAndSize() async throws {
        var document = sampleDocument(field: .futsal)
        document.insertKeyframe(after: nil)
        document.keyframes[0].duration = 0.5
        let directory = FileManager.default.temporaryDirectory.appending(path: "board3d-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = BoardExportRequest(document: document, name: "3D clip")
        request.format = .mp4
        request.framing = .square
        let started = Date()
        let url = try await TacticalBoardExporter.export(request, to: directory)
        let elapsed = Date().timeIntervalSince(started)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1080))
        print("board3d: 3D 1080x1080 mp4, \(Int(0.5 * 30)) frames in \(String(format: "%.2f", elapsed)) s")
    }

    func testGIFAndJPEGExportIn3D() async throws {
        let document = sampleDocument(field: .footballHalf, style: .night, angle: .broadcast)
        let directory = FileManager.default.temporaryDirectory.appending(path: "board3d-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = BoardExportRequest(document: document, name: "3D still")
        request.format = .jpeg
        request.imageScale = 1
        let jpeg = try await TacticalBoardExporter.export(request, to: directory)
        XCTAssertEqual(UIImage(contentsOfFile: jpeg.path)?.cgImage?.width, 640)
        request.format = .gif
        let gif = try await TacticalBoardExporter.export(request, to: directory)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), Int((TacticalBoardExporter.stillClipDuration * 12).rounded(.up)))
    }

    /// Timing of offscreen frames (printed; asserts only a generous ceiling for CI noise).
    func testOffscreenFrameTiming() throws {
        let document = try phoneDocument()
        let offscreen = try XCTUnwrap(TacticalBoard3DOffscreen())
        _ = offscreen.image(document: document, time: 0, pixelSize: CGSize(width: 1920, height: 1080))
        let started = Date()
        let frames = 20
        for frame in 0..<frames {
            _ = offscreen.image(document: document, time: Double(frame) / 30, pixelSize: CGSize(width: 1920, height: 1080))
        }
        let perFrame = Date().timeIntervalSince(started) / Double(frames)
        print("board3d: offscreen 1920x1080 frame \(String(format: "%.1f", perFrame * 1000)) ms, nodes \(offscreen.builder.scene.rootNode.childNodes(passingTest: { _, _ in true }).count)")
        XCTAssertLessThan(perFrame, 1.0)
    }

    /// Writes a gallery of renders for visual review when BOARD3D_SHOTS_DIR is set.
    func testRenderGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["BOARD3D_SHOTS_DIR"] else { throw XCTSkip("Set BOARD3D_SHOTS_DIR to write the gallery") }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let portrait = CGSize(width: 390, height: 700), landscape = CGSize(width: 844, height: 390)
        func write(_ name: String, _ document: BoardDocument, _ size: CGSize, time: Double? = nil) throws {
            let image = try XCTUnwrap(TacticalBoard3DRenderer.image(document: document, time: time, size: size, scale: 2))
            try XCTUnwrap(UIImage(cgImage: image).pngData()).write(to: directory.appending(path: "\(name).png"))
        }
        let square = CGSize(width: 540, height: 540)
        for angle in [BoardViewAngle.tilted, .broadcast] {
            var phone = try phoneDocument()
            phone.viewAngle = angle
            try write("phone-\(angle.rawValue)-portrait", phone, portrait, time: 0)
            try write("phone-\(angle.rawValue)-landscape", phone, landscape, time: 0)
            try write("phone-\(angle.rawValue)-square", phone, square, time: 0)
        }
        var phone = try phoneDocument()
        phone.camera = BoardCamera(azimuthDegrees: 145, elevationDegrees: 28, distanceScale: 0.55, target: BoardPoint(0.35, 0.45))
        try write("phone-custom-portrait", phone, portrait, time: 0)
        try write("phone-custom-landscape", phone, landscape, time: 0)
        for style in BoardFieldStyle.allCases {
            try write("sample-\(style.rawValue)-tilted-landscape", sampleDocument(style: style, angle: .tilted), landscape)
            try write("sample-\(style.rawValue)-broadcast-portrait", sampleDocument(style: style, angle: .broadcast), portrait)
        }
        var close = sampleDocument(style: .grass)
        close.camera = BoardCamera(azimuthDegrees: 60, elevationDegrees: 24, distanceScale: 0.3, target: BoardPoint(0.6, 0.5))
        try write("sample-grass-close-landscape", close, landscape)
        var selected = close
        selected.camera?.azimuthDegrees = 100
        let scene = try XCTUnwrap(TacticalBoard3DOffscreen())
        let id = try XCTUnwrap(selected.elements.first { $0.number == 9 }?.id)
        let selectedImage = try XCTUnwrap(scene.image(document: selected, time: nil, pixelSize: CGSize(width: 1688, height: 780), selectedID: id))
        try XCTUnwrap(UIImage(cgImage: selectedImage).pngData()).write(to: directory.appending(path: "sample-selected-landscape.png"))
        // A lofted long shot: the arc, its ground shadow and the ball riding it.
        var (lob, _, _, _, keeperID) = aerialDocument()
        lob.camera = BoardCamera(azimuthDegrees: 88, elevationDegrees: 16, distanceScale: 0.75, target: BoardPoint(0.78, 0.55))
        for (index, time) in [0.0, 0.5, 0.9, 1.3].enumerated() {
            try write("arc-\(index)", lob, landscape, time: time)
        }
        try write("arc-top", { var d = lob; d.camera = BoardCamera(azimuthDegrees: 20, elevationDegrees: 42, distanceScale: 0.8, target: BoardPoint(0.75, 0.55)); return d }(), landscape, time: 0.6)
        // The keeper's view, focused on the ball as it flies in.
        var focus = lob
        focus.camera = focus.cameraOrDefault.pointOfView(subject: keeperID, lookAt: .ball)
        for (index, time) in [0.0, 0.6, 1.1, 1.5].enumerated() {
            try write("pov-focus-\(index)", focus, landscape, time: time)
        }

        // Point of view: the keeper watches the attack (looking at the ball), then a walk-around.
        var attack = attackDocument()
        attack.document.camera = attack.document.cameraOrDefault.pointOfView(subject: attack.keeper, lookAt: .ball)
        for (index, time) in [0.0, 0.7, 1.4, 2.0].enumerated() {
            try write("pov-\(index)", attack.document, landscape, time: time)
        }
        try write("pov-portrait", attack.document, portrait, time: 1.4)
        var strikerView = attack.document
        strikerView.camera = strikerView.cameraOrDefault.pointOfView(subject: attack.striker, lookAt: .facing)
        try write("pov-striker", strikerView, landscape, time: 1.0)
        var walk = attack.document
        let freeStart = BoardFreeCamera.reset(walk.cameraOrDefault, field: walk.fieldType, near: nil)
        for index in 0..<4 {
            var camera = BoardFreeCamera.moved(freeStart, field: walk.fieldType, forward: Double(index) * 12, right: Double(index) * 4)
            camera = BoardFreeCamera.raised(camera, by: 1 + Double(index) * 0.35)
            camera = BoardFreeCamera.looked(camera, by: CGSize(width: Double(index) * 40, height: 0))
            walk.camera = camera
            try write("free-\(index)", walk, landscape, time: 0)
        }
        // Camera animation: a strip through the camera move.
        let cameraMove = cameraDocument()
        for index in 0..<6 {
            try write("camera-\(index)", cameraMove, landscape, time: cameraMove.duration * Double(index) / 5)
        }
        // Follow paths: a strip of frames through the transition.
        var follow = followDocument().document
        follow.camera = BoardCamera(azimuthDegrees: 0, elevationDegrees: 40, distanceScale: 0.9)
        for (index, time) in [0.0, 0.5, 1.0, 1.5, 2.0].enumerated() {
            try write("follow-\(index)", follow, landscape, time: time)
        }
        // Onion skin: editing the middle of three frames.
        var onion = sampleDocument(field: .futsal, style: .court)
        onion.insertKeyframe(after: nil)
        onion.insertKeyframe(after: 0)
        onion.insertKeyframe(after: 1)
        for index in onion.elements.indices where onion.elements[index].kind == .player || onion.elements[index].kind == .ball {
            let id = onion.elements[index].id
            onion.keyframes[0].poses[id]?.position = onion.elements[index].position.offset(dx: -0.06, dy: 0.05)
            onion.keyframes[2].poses[id]?.position = onion.elements[index].position.offset(dx: 0.08, dy: -0.04)
        }
        onion.showFrame(1)
        onion.camera = BoardCamera(azimuthDegrees: 0, elevationDegrees: 38, distanceScale: 0.75)
        let onionRenderer = try XCTUnwrap(TacticalBoard3DOffscreen())
        let onionImage = try XCTUnwrap(onionRenderer.image(document: onion, time: nil, pixelSize: CGSize(width: 1688, height: 780), onionFrame: 1))
        try XCTUnwrap(UIImage(cgImage: onionImage).pngData()).write(to: directory.appending(path: "onion-3d.png"))

        // Training library: every new element, overview and close-ups.
        var training = trainingDocument()
        try write("training-tilted-landscape", training, landscape)
        try write("training-tilted-portrait", training, portrait)
        for (row, y) in [0.25, 0.5, 0.75].enumerated() {
            training.camera = BoardCamera(azimuthDegrees: 0, elevationDegrees: 24, distanceScale: 0.5, target: BoardPoint(0.5, y))
            try write("training-close-row\(row + 1)", training, landscape)
        }
        // Squad photos on badges, zoomed out and close.
        var squad = sampleDocument(style: .grass)
        let hues: [CGFloat] = [0.05, 0.12, 0.3, 0.55, 0.62, 0.75, 0.9, 0.02, 0.4, 0.2, 0.68]
        for (index, elementIndex) in squad.elements.indices.filter({ squad.elements[$0].kind == .player || squad.elements[$0].kind == .goalkeeper }).enumerated() {
            let id = UUID()
            try storePhoto(for: id, hue: hues[index % hues.count])
            squad.elements[elementIndex].playerID = id
        }
        try write("photos-tilted-landscape", squad, landscape)
        try write("photos-broadcast-portrait", { var d = squad; d.viewAngle = .broadcast; return d }(), portrait)
        squad.camera = BoardCamera(azimuthDegrees: 10, elevationDegrees: 24, distanceScale: 0.35, target: BoardPoint(0.5, 0.5))
        try write("photos-close-landscape", squad, landscape)
        var lengths = sampleDocument(style: .grass)
        for index in lengths.elements.indices where lengths.elements[index].isLineLike { lengths.elements[index].showsLength = true }
        lengths.camera = BoardCamera(azimuthDegrees: 0, elevationDegrees: 40, distanceScale: 0.6, target: BoardPoint(0.62, 0.55))
        try write("lines-with-lengths", lengths, landscape)
        for field in [BoardFieldType.futsal, .basketball, .footballHalf, .blank] {
            try write("field-\(field.rawValue)-tilted-portrait", sampleDocument(field: field, angle: .tilted), portrait)
            try write("field-\(field.rawValue)-broadcast-landscape", sampleDocument(field: field, angle: .broadcast), landscape)
        }
    }

    // MARK: Phone fixture

    /// A real board saved on the phone: broadcast angle, 27 elements, 2 keyframes.
    private static let phoneBoardJSON = """
{"viewAngle":"broadcast","elements":[{"label":"","isCurved":false,"rotation":0,"points":[],"position":{"y":0.1878775168746633,"x":0.703625300344178},"\
arrowStyle":"pass","opacity":0.3,"zoneShape":"rectangle","size":1,"isDoubleHeaded":false,"number":1,"colorHex":"2F80ED","hasBlockEnd":false,"kind":"pl\
ayer","id":"4E6DE079-8DCC-44E9-A9E3-EF9233EA96F4"},{"label":"","isCurved":false,"rotation":0,"points":[],"position":{"y":0.7800073137603177,"x":0.7847\
838957963291},"arrowStyle":"pass","opacity":0.3,"zoneShape":"rectangle","size":1,"isDoubleHeaded":false,"number":2,"colorHex":"2F80ED","hasBlockEnd":f\
alse,"kind":"player","id":"C7DDDDB9-D933-4DE8-9B6F-9A585B812600"},{"label":"","isCurved":false,"rotation":0,"points":[],"position":{"y":0.181010343746\
73497,"x":0.5175488454706927},"arrowStyle":"pass","opacity":0.3,"zoneShape":"rectangle","size":1,"isDoubleHeaded":false,"number":3,"colorHex":"2F80ED"\
,"hasBlockEnd":false,"kind":"player","id":"EE2E5E3E-C2F2-4897-8827-241C6490872E"},{"label":"","isCurved":false,"rotation":0,"points":[],"position":{"y\
":0.7838104691254834,"x":0.5520307874481941},"arrowStyle":"pass","opacity":0.3,"zoneShape":"rectangle","size":1,"isDoubleHeaded":false,"number":4,"col\
orHex":"2F80ED","hasBlockEnd":false,"kind":"player","id":"B9291756-3122-4A41-B72B-6C5B14AAE585"},{"points":[],"hasBlockEnd":false,"arrowStyle":"pass",\
"kind":"goalkeeper","isDoubleHeaded":false,"label":"","colorHex":"F2C94C","number":1,"id":"68978292-AED6-4863-9665-3805EED99CDD","zoneShape":"rectangl\
e","size":1,"isCurved":false,"rotation":0,"position":{"y":0.5022988505747127,"x":0.936807881773399},"opacity":0.3},{"points":[],"hasBlockEnd":false,"a\
rrowStyle":"pass","kind":"opponent","isDoubleHeaded":false,"label":"","colorHex":"EB5757","id":"204AC15B-131D-44A7-8475-418DD9F67174","zoneShape":"rec\
tangle","size":1,"isCurved":false,"rotation":0,"position":{"y":0.2641379310344828,"x":0.32879036672140116},"opacity":0.3},{"points":[],"hasBlockEnd":f\
alse,"arrowStyle":"pass","kind":"opponent","isDoubleHeaded":false,"label":"","colorHex":"EB5757","id":"B5B7EA36-7211-4D9C-BCE2-81E2A752D061","zoneShap\
e":"rectangle","size":1,"isCurved":false,"rotation":0,"position":{"y":0.6022098004388257,"x":0.33590290112492593},"opacity":0.3},{"points":[],"hasBloc\
kEnd":false,"arrowStyle":"pass","kind":"player","isDoubleHeaded":false,"label":"","colorHex":"EB5757","number":1,"id":"775F5B64-2EFE-46DA-AF96-DD8FA11\
D6923","zoneShape":"rectangle","size":1,"isCurved":false,"rotation":0,"position":{"y":0.5384673565510366,"x":0.45424482109227854},"opacity":0.3},{"pos\
ition":{"y":0.7657454811409466,"x":0.4264179988158673},"zoneShape":"rectangle","opacity":0.3,"hasBlockEnd":false,"rotation":0,"id":"AE527FBA-EBCE-4564\
-8A1C-BC9CC5DF1A2F","isDoubleHeaded":false,"label":"","number":2,"kind":"player","colorHex":"EB5757","points":[],"arrowStyle":"pass","isCurved":false,\
"size":1},{"position":{"y":0.18101034374673497,"x":0.3820840734162225},"zoneShape":"rectangle","opacity":0.3,"hasBlockEnd":false,"rotation":0,"id":"33\
5B189E-C0FC-47FD-91DA-82C1F782D005","isDoubleHeaded":false,"label":"","number":3,"kind":"player","colorHex":"EB5757","points":[],"arrowStyle":"pass","\
isCurved":false,"size":1},{"position":{"y":0.5675862068965517,"x":0.6610859332238642},"zoneShape":"rectangle","opacity":0.3,"hasBlockEnd":false,"rotat\
ion":0,"id":"736073C2-05D2-45FD-9153-CA0134BC4303","isDoubleHeaded":false,"label":"","kind":"marker","colorHex":"F2C94C","points":[],"arrowStyle":"pas\
s","isCurved":false,"size":1},{"position":{"y":0.21968751388593655,"x":0.8501116720672056},"zoneShape":"rectangle","opacity":0.3,"hasBlockEnd":false,"\
rotation":0,"id":"62A0354C-C752-4E7F-B4E3-8D940F5819D8","isDoubleHeaded":false,"label":"","kind":"miniGoal","colorHex":"FFFFFF","points":[],"arrowStyl\
e":"pass","isCurved":false,"size":1},{"rotation":0,"zoneShape":"rectangle","colorHex":"9A9AA0","hasBlockEnd":false,"label":"","kind":"mannequin","id":\
"8D91F949-20A1-413D-97D0-1D9DD31C4F81","isDoubleHeaded":false,"points":[],"isCurved":false,"position":{"y":0.7496551724137931,"x":0.8867848932676519},\
"size":1,"arrowStyle":"pass","opacity":0.3},{"rotation":0,"zoneShape":"rectangle","colorHex":"FFFFFF","hasBlockEnd":false,"label":"","kind":"arrow","i\
d":"F1144FB2-0924-443D-A411-E166CE009863","isDoubleHeaded":false,"points":[{"y":0.23195402298850581,"x":0.5473431855500821}],"isCurved":false,"positio\
n":{"y":0.733103448275862,"x":0.7664915161466885},"size":1,"arrowStyle":"pass","opacity":0.3},{"rotation":0,"zoneShape":"rectangle","colorHex":"FFFFFF\
","hasBlockEnd":false,"label":"","kind":"arrow","id":"ACAB6570-ECCC-4332-BEB5-545CF3B2C1E4","isDoubleHeaded":false,"points":[{"y":0.49262836490528417,\
"x":0.5}],"isCurved":false,"position":{"y":0.21816091954022998,"x":0.6646590038314175},"size":1,"arrowStyle":"dribble","opacity":0.3},{"rotation":0,"z\
oneShape":"rectangle","colorHex":"F2C94C","hasBlockEnd":false,"label":"","kind":"zone","id":"B60D33D0-674A-44D7-8F7A-4EA9D83022F3","isDoubleHeaded":fa\
lse,"points":[{"y":0.732183908045977,"x":0.3579704433497537}],"isCurved":false,"position":{"y":0.9482758620689655,"x":0.08522605363984664},"size":1,"a\
rrowStyle":"pass","opacity":0.3},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[{"x":0.01448194197750135\
6,"y":0.5004753944206457},{"x":0.054505624629958505,"y":0.07642357120468074},{"x":0.2553711775952282,"y":0.19256667564019292}],"zoneShape":"rectangle"\
,"arrowStyle":"pass","label":"","kind":"polygon","id":"0503FF77-32C0-4E5D-9840-94C3349D322A","colorHex":"F2C94C","opacity":0.3,"position":{"x":0.23952\
134209474812,"y":0.5278718158421573}},{"isDoubleHeaded":true,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[{"x":0.6051078270388\
615,"y":0.7524137931034482}],"zoneShape":"rectangle","arrowStyle":"pass","label":"","kind":"arrow","id":"F9939479-81CC-422D-B2BE-EBDF3E49C316","colorH\
ex":"FFFFFF","opacity":0.3,"position":{"x":0.8882297217288336,"y":0.536605370389719}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurv\
ed":true,"size":1,"points":[{"x":0.7490704558910597,"y":0.11255354717375404},{"x":0.9799763173475429,"y":0.06976804931564101}],"zoneShape":"rectangle"\
,"arrowStyle":"pass","label":"","kind":"arrow","id":"D85FA263-3756-43C5-B333-779643E9251D","colorHex":"FFFFFF","opacity":0.3,"position":{"x":0.9016726\
874657908,"y":0.39471264367816095}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[],"zoneShape":"rectan\
gle","arrowStyle":"pass","label":"","kind":"cone","id":"CC6D53B5-6707-48AA-8EA9-6FFDDE1DA8A4","colorHex":"FF8A3D","opacity":0.3,"position":{"x":0.7599\
408866995074,"y":0.4250574712643678}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[],"zoneShape":"rect\
angle","arrowStyle":"pass","label":"","kind":"cone","id":"0DD54E6E-D64D-461F-A917-5952DE9A2366","colorHex":"FF8A3D","opacity":0.3,"position":{"x":0.59\
02072232089994,"y":0.555621147215547}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[],"zoneShape":"rec\
tangle","arrowStyle":"pass","label":"","kind":"cone","id":"DE428FEC-5E7A-4AE4-966E-B309AD350FAA","colorHex":"FF8A3D","opacity":0.3,"position":{"x":0.6\
77027827116637,"y":0.8598735764287954}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[{"y":0.0728735632\
1839084,"x":0.2632840722495895}],"zoneShape":"rectangle","arrowStyle":"run","label":"","kind":"arrow","id":"DCA66269-1B9D-45B3-8DC6-6655481FA401","col\
orHex":"FFFFFF","opacity":0.3,"position":{"y":0.058160919540230005,"x":0.9320437876299945}},{"id":"909E106D-0D0E-4B3A-A024-B7D6A2DD08AC","position":{"\
x":0.9469315818281335,"y":0.8572413793103448},"points":[],"size":1,"colorHex":"FFFFFF","hasBlockEnd":false,"label":"","rotation":0,"isDoubleHeaded":fa\
lse,"zoneShape":"rectangle","opacity":0.3,"isCurved":false,"kind":"miniGoal","arrowStyle":"pass"},{"id":"5D3CBE6A-868F-40FD-BF6F-1816E912AAB0","positi\
on":{"x":0.8010311986863712,"y":0.32114942528735635},"points":[],"size":1,"colorHex":"FFFFFF","hasBlockEnd":false,"label":"","rotation":0,"isDoubleHea\
ded":false,"zoneShape":"rectangle","opacity":0.3,"isCurved":false,"kind":"ball","arrowStyle":"pass"},{"id":"A186E899-CE9B-40D7-8A6C-898D79FE0776","pos\
ition":{"x":0.6351568975725281,"y":0.6459460871382301},"points":[],"size":1,"colorHex":"FFFFFF","hasBlockEnd":false,"label":"","rotation":0,"isDoubleH\
eaded":false,"zoneShape":"rectangle","opacity":0.3,"isCurved":false,"kind":"ball","arrowStyle":"pass"},{"id":"599C284E-D81C-416C-9779-A7EB0409507F","p\
osition":{"x":0.4184132622853759,"y":0.37877442273534634},"points":[],"size":1,"colorHex":"FFFFFF","hasBlockEnd":false,"label":"","rotation":0,"isDoub\
leHeaded":false,"zoneShape":"rectangle","opacity":0.3,"isCurved":false,"kind":"ball","arrowStyle":"pass"}],"keyframes":[{"id":"80CF0E11-B5CF-4A55-BFE0\
-9CA20D62D2DA","poses":["0503FF77-32C0-4E5D-9840-94C3349D322A",{"points":[{"x":0.014481941977501356,"y":0.5004753944206457},{"x":0.054505624629958505,\
"y":0.07642357120468074},{"x":0.2553711775952282,"y":0.19256667564019292}],"position":{"x":0.23952134209474812,"y":0.5278718158421573}},"5D3CBE6A-868F\
-40FD-BF6F-1816E912AAB0",{"points":[],"position":{"y":0.32114942528735635,"x":0.8010311986863712}},"775F5B64-2EFE-46DA-AF96-DD8FA11D6923",{"points":[]\
,"position":{"x":0.45424482109227854,"y":0.5384673565510366}},"C7DDDDB9-D933-4DE8-9B6F-9A585B812600",{"points":[],"position":{"y":0.7800073137603177,"\
x":0.7847838957963291}},"335B189E-C0FC-47FD-91DA-82C1F782D005",{"points":[],"position":{"y":0.18101034374673497,"x":0.3820840734162225}},"8D91F949-20A\
1-413D-97D0-1D9DD31C4F81",{"points":[],"position":{"x":0.8867848932676519,"y":0.7496551724137931}},"F9939479-81CC-422D-B2BE-EBDF3E49C316",{"points":[{\
"x":0.6051078270388615,"y":0.7524137931034482}],"position":{"x":0.8882297217288336,"y":0.536605370389719}},"909E106D-0D0E-4B3A-A024-B7D6A2DD08AC",{"po\
ints":[],"position":{"y":0.8572413793103448,"x":0.9469315818281335}},"DE428FEC-5E7A-4AE4-966E-B309AD350FAA",{"points":[],"position":{"y":0.85987357642\
87954,"x":0.677027827116637}},"B9291756-3122-4A41-B72B-6C5B14AAE585",{"points":[],"position":{"y":0.7838104691254834,"x":0.5520307874481941}},"B60D33D\
0-674A-44D7-8F7A-4EA9D83022F3",{"points":[{"y":0.732183908045977,"x":0.3579704433497537}],"position":{"y":0.9482758620689655,"x":0.08522605363984664}}\
,"AE527FBA-EBCE-4564-8A1C-BC9CC5DF1A2F",{"points":[],"position":{"x":0.4264179988158673,"y":0.7657454811409466}},"0DD54E6E-D64D-461F-A917-5952DE9A2366\
",{"points":[],"position":{"y":0.555621147215547,"x":0.5902072232089994}},"736073C2-05D2-45FD-9153-CA0134BC4303",{"position":{"y":0.5675862068965517,"\
x":0.6610859332238642},"points":[]},"ACAB6570-ECCC-4332-BEB5-545CF3B2C1E4",{"position":{"x":0.6646590038314175,"y":0.21816091954022998},"points":[{"x"\
:0.5,"y":0.49262836490528417}]},"68978292-AED6-4863-9665-3805EED99CDD",{"position":{"x":0.936807881773399,"y":0.5022988505747127},"points":[]},"F1144F\
B2-0924-443D-A411-E166CE009863",{"position":{"x":0.7664915161466885,"y":0.733103448275862},"points":[{"x":0.5473431855500821,"y":0.23195402298850581}]\
},"B5B7EA36-7211-4D9C-BCE2-81E2A752D061",{"position":{"y":0.6022098004388257,"x":0.33590290112492593},"points":[]},"DCA66269-1B9D-45B3-8DC6-6655481FA4\
01",{"position":{"y":0.058160919540230005,"x":0.9320437876299945},"points":[{"y":0.07287356321839084,"x":0.2632840722495895}]},"599C284E-D81C-416C-977\
9-A7EB0409507F",{"position":{"y":0.37877442273534634,"x":0.4184132622853759},"points":[]},"4E6DE079-8DCC-44E9-A9E3-EF9233EA96F4",{"position":{"y":0.18\
78775168746633,"x":0.703625300344178},"points":[]},"62A0354C-C752-4E7F-B4E3-8D940F5819D8",{"points":[],"position":{"x":0.8501116720672056,"y":0.219687\
51388593655}},"D85FA263-3756-43C5-B333-779643E9251D",{"points":[{"x":0.7490704558910597,"y":0.11255354717375404},{"x":0.9799763173475429,"y":0.0697680\
4931564101}],"position":{"x":0.9016726874657908,"y":0.39471264367816095}},"204AC15B-131D-44A7-8475-418DD9F67174",{"points":[],"position":{"x":0.328790\
36672140116,"y":0.2641379310344828}},"EE2E5E3E-C2F2-4897-8827-241C6490872E",{"points":[],"position":{"x":0.5175488454706927,"y":0.18101034374673497}},\
"A186E899-CE9B-40D7-8A6C-898D79FE0776",{"points":[],"position":{"x":0.6351568975725281,"y":0.6459460871382301}},"CC6D53B5-6707-48AA-8EA9-6FFDDE1DA8A4"\
,{"points":[],"position":{"x":0.7599408866995074,"y":0.4250574712643678}}],"duration":1},{"poses":["B60D33D0-674A-44D7-8F7A-4EA9D83022F3",{"position":\
{"y":0.9482758620689655,"x":0.08522605363984664},"points":[{"y":0.732183908045977,"x":0.3579704433497537}]},"736073C2-05D2-45FD-9153-CA0134BC4303",{"p\
osition":{"x":0.6610859332238642,"y":0.5675862068965517},"points":[]},"AE527FBA-EBCE-4564-8A1C-BC9CC5DF1A2F",{"position":{"y":0.7657454811409466,"x":0\
.4264179988158673},"points":[]},"ACAB6570-ECCC-4332-BEB5-545CF3B2C1E4",{"position":{"y":0.32364780658025927,"x":0.7585310734463276},"points":[{"y":0.4\
710344827586207,"x":0.4764772851669403}]},"4E6DE079-8DCC-44E9-A9E3-EF9233EA96F4",{"position":{"x":0.7991055263328787,"y":0.3069577760969963},"points":\
[]},"8D91F949-20A1-413D-97D0-1D9DD31C4F81",{"position":{"x":0.8867848932676519,"y":0.7496551724137931},"points":[]},"DE428FEC-5E7A-4AE4-966E-B309AD350\
FAA",{"position":{"y":0.8598735764287954,"x":0.677027827116637},"points":[]},"204AC15B-131D-44A7-8475-418DD9F67174",{"position":{"y":0.264137931034482\
8,"x":0.32879036672140116},"points":[]},"0DD54E6E-D64D-461F-A917-5952DE9A2366",{"position":{"x":0.5902072232089994,"y":0.555621147215547},"points":[]}\
,"335B189E-C0FC-47FD-91DA-82C1F782D005",{"position":{"x":0.3820840734162225,"y":0.18101034374673497},"points":[]},"775F5B64-2EFE-46DA-AF96-DD8FA11D692\
3",{"position":{"x":0.4395555555555555,"y":0.49310344827586206},"points":[]},"B9291756-3122-4A41-B72B-6C5B14AAE585",{"position":{"x":0.584347171628985\
1,"y":0.9130976077097306},"points":[]},"D85FA263-3756-43C5-B333-779643E9251D",{"position":{"y":0.39471264367816095,"x":0.9016726874657908},"points":[{\
"y":0.11255354717375404,"x":0.7490704558910597},{"y":0.06976804931564101,"x":0.9799763173475429}]},"B5B7EA36-7211-4D9C-BCE2-81E2A752D061",{"points":[]\
,"position":{"x":0.33590290112492593,"y":0.6022098004388257}},"0503FF77-32C0-4E5D-9840-94C3349D322A",{"points":[{"x":0.014481941977501356,"y":0.500475\
3944206457},{"x":0.054505624629958505,"y":0.07642357120468074},{"x":0.2553711775952282,"y":0.19256667564019292}],"position":{"x":0.23952134209474812,"\
y":0.5278718158421573}},"EE2E5E3E-C2F2-4897-8827-241C6490872E",{"points":[],"position":{"x":0.5535375460356645,"y":0.11976906757524947}},"C7DDDDB9-D93\
3-4DE8-9B6F-9A585B812600",{"points":[],"position":{"y":0.7800073137603177,"x":0.7847838957963291}},"62A0354C-C752-4E7F-B4E3-8D940F5819D8",{"points":[]\
,"position":{"x":0.8501116720672056,"y":0.21968751388593655}},"F9939479-81CC-422D-B2BE-EBDF3E49C316",{"points":[{"y":0.8691488035892323,"x":0.61531073\
44632768}],"position":{"y":0.536605370389719,"x":0.8882297217288336}},"68978292-AED6-4863-9665-3805EED99CDD",{"points":[],"position":{"y":0.5022988505\
747127,"x":0.936807881773399}},"F1144FB2-0924-443D-A411-E166CE009863",{"points":[{"y":0.18528788634097704,"x":0.5638983050847458}],"position":{"y":0.7\
33103448275862,"x":0.7664915161466885}},"CC6D53B5-6707-48AA-8EA9-6FFDDE1DA8A4",{"points":[],"position":{"x":0.7599408866995074,"y":0.4250574712643678}\
}],"id":"1411EC9D-C75B-4CC6-8A07-330913AFD38D","duration":3}],"awayColorHex":"EB5757","homeColorHex":"2F80ED","version":1,"fieldType":"footballFull"}
"""

    // MARK: Aerial lines and focus

    /// A lofted shot: a curved line 9 m high, with the ball following it.
    private func aerialDocument() -> (document: BoardDocument, line: UUID, ball: UUID, striker: UUID, keeper: UUID) {
        var document = BoardDocument()
        document.fieldType = .footballFull
        document.viewAngle = .broadcast
        var shot = BoardElement(kind: .arrow, position: BoardPoint(0.55, 0.62), points: [BoardPoint(0.97, 0.5)], colorHex: BoardPalette.white)
        shot.arcHeightMeters = 9
        var striker = BoardElement(kind: .player, position: BoardPoint(0.54, 0.63), colorHex: BoardPalette.home, number: 10)
        striker.rotation = 0
        var keeper = BoardElement(kind: .goalkeeper, position: BoardPoint(0.95, 0.5), colorHex: BoardPalette.keeper, number: 1)
        keeper.rotation = 180
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.55, 0.62))
        document.elements = [shot, striker, keeper, ball]
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        document.keyframes[0].duration = 1.6
        document.keyframes[0].paths = [ball.id: BoardFollowPath(pathID: shot.id)]
        document.keyframes[1].poses[ball.id]?.position = BoardPoint(0.97, 0.5)
        return (document, shot.id, ball.id, striker.id, keeper.id)
    }

    func testAerialLineArcsAboveTheGroundAndCastsAShadow() throws {
        let (document, lineID, _, _, _) = aerialDocument()
        let scene = TacticalBoard3DScene()
        scene.update(document: document, time: nil, selectedID: nil)
        let node = try XCTUnwrap(scene.node(for: lineID))
        let arc = try XCTUnwrap(node.childNodes.first)
        XCTAssertEqual(Double(arc.boundingBox.max.y), 9, accuracy: 0.6, "The ribbon peaks at the arc height")
        XCTAssertLessThan(Double(arc.boundingBox.min.y), 0.2, "and starts and ends near the ground")
        XCTAssertEqual(node.childNodes.count, 2, "Arc plus its ground shadow")
        let shadow = node.childNodes[1]
        XCTAssertLessThan(Double(shadow.boundingBox.max.y), 0.1, "The shadow lies on the grass")
        // A flat line has no shadow child.
        var flat = document
        flat.elements[0].arcHeightMeters = nil
        scene.update(document: flat, time: nil, selectedID: nil)
        XCTAssertEqual(scene.node(for: lineID)?.childNodes.count, 1)
    }

    func testFollowingAnAerialLineLiftsTheElement() throws {
        let (document, _, ballID, _, _) = aerialDocument()
        let scene = TacticalBoard3DScene()
        var heights: [Double] = []
        for time in stride(from: 0.0, through: 1.6, by: 0.2) {
            scene.update(document: document, time: time, selectedID: nil)
            let node = try XCTUnwrap(scene.node(for: ballID))
            heights.append(Double(node.simdPosition.y))
            let resolved = try XCTUnwrap(document.elements(at: time).first { $0.id == ballID })
            XCTAssertEqual(Double(node.simdPosition.y), resolved.heightMeters ?? 0, accuracy: 1e-3)
        }
        XCTAssertLessThan(heights.first ?? 1, 0.5, "Starts on the ground")
        XCTAssertLessThan(heights.last ?? 1, 0.5, "and lands again")
        XCTAssertGreaterThan(heights.max() ?? 0, 6, "with a real lob in between")
    }

    func testPointOfViewFocusTracksAMovingElementAndFallsBack() throws {
        var (document, _, ballID, strikerID, keeperID) = aerialDocument()
        let viewport = CGSize(width: 844, height: 390)
        let camera = document.cameraOrDefault.pointOfView(subject: keeperID, lookAt: .element(ballID))
        var yaws: [Double] = []
        for time in stride(from: 0.0, through: 1.6, by: 0.4) {
            let pose = BoardCameraResolver.pose(camera, in: document, time: time, viewport: viewport)
            let ball = try XCTUnwrap(document.elements(at: time).first { $0.id == ballID })
            let target = BoardOrbit.world(ball.position, field: document.fieldType, y: ball.heightMeters ?? 0)
            let toTarget = simd_normalize(SIMD2((target - pose.eye).x, (target - pose.eye).z))
            XCTAssertGreaterThan(simd_dot(toTarget, simd_normalize(SIMD2(pose.forward.x, pose.forward.z))), 0.99, "Keeper keeps facing the ball at \(time) s")
            yaws.append(BoardViewPose.angles(of: pose.forward).yaw)
        }
        XCTAssertGreaterThan((yaws.max() ?? 0) - (yaws.min() ?? 0), 1, "The look direction really tracks")
        // Focus on the striker, then delete him: the camera falls back to the keeper's facing.
        var focusStriker = camera
        focusStriker.lookAt = .element(strikerID)
        document.removeElement(strikerID)
        let fallback = BoardCameraResolver.pose(focusStriker, in: document, time: nil, viewport: viewport)
        let keeper = try XCTUnwrap(document.elements.first { $0.id == keeperID })
        XCTAssertEqual(BoardViewPose.angles(of: fallback.forward).yaw, keeper.rotation, accuracy: 0.5, "Falls back to facing")
    }

    // MARK: Performance

    /// A heavy board: two full line-ups with keepers, equipment, lines and zones.
    func heavyDocument() -> BoardDocument {
        var document = BoardDocument()
        document.fieldType = .footballFull
        document.viewAngle = .tilted
        var elements: [BoardElement] = []
        for team in 0..<2 {
            let home = team == 0
            for index in 0..<11 {
                let row = index == 0 ? 0.0 : Double((index - 1) / 4 + 1)
                let column = index == 0 ? 2.0 : Double((index - 1) % 4)
                let x = home ? 0.05 + row * 0.13 : 0.95 - row * 0.13
                var player = BoardElement(kind: index == 0 ? .goalkeeper : .player,
                                          position: BoardPoint(x, 0.16 + column * 0.22),
                                          colorHex: index == 0 ? BoardPalette.keeper : (home ? BoardPalette.home : BoardPalette.away),
                                          number: index + 1)
                player.label = index % 3 == 0 ? "Player \(index + 1)" : ""
                player.rotation = home ? 0 : 180
                elements.append(player)
            }
        }
        elements.append(BoardElement(kind: .ball, position: BoardPoint(0.5, 0.5)))
        for index in 0..<8 {
            elements.append(BoardElement(kind: .cone, position: BoardPoint(0.44 + Double(index) * 0.02, 0.92), colorHex: BoardPalette.orange))
        }
        elements.append(BoardElement(kind: .wall, position: BoardPoint(0.75, 0.5), colorHex: BoardPalette.away))
        elements.append(BoardElement(kind: .goal, position: BoardPoint(0.02, 0.5), colorHex: BoardPalette.white))
        elements.append(BoardElement(kind: .ladder, position: BoardPoint(0.3, 0.95), colorHex: BoardPalette.lime))
        for index in 0..<6 {
            var line = BoardElement(kind: .arrow, position: BoardPoint(0.3 + Double(index) * 0.06, 0.3),
                                    points: [BoardPoint(0.45 + Double(index) * 0.06, 0.62)], colorHex: BoardPalette.white)
            line.arrowStyle = index % 3 == 0 ? .run : (index % 3 == 1 ? .dribble : .pass)
            elements.append(line)
        }
        for index in 0..<3 {
            var zone = BoardElement(kind: .zone, position: BoardPoint(0.1 + Double(index) * 0.3, 0.1), points: [BoardPoint(0.3 + Double(index) * 0.3, 0.4)], colorHex: BoardPalette.keeper)
            zone.opacity = 0.18
            elements.append(zone)
        }
        var text = BoardElement(kind: .text, position: BoardPoint(0.5, 0.05), colorHex: BoardPalette.white)
        text.label = "High press"
        elements.append(text)
        document.elements = elements
        return document
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
    }

    /// Orbits the camera for `frames` frames and reports CPU and GPU milliseconds per frame.
    @discardableResult
    private func measureOrbit(_ document: BoardDocument, name: String, size: CGSize = CGSize(width: 1179, height: 2556), samples: Int? = nil,
                              quality: Board3DQuality = .current, frames: Int = 60) throws -> (cpu: [Double], gpu: [Double], wall: [Double]) {
        let previous = Board3DQuality.current
        Board3DQuality.current = quality
        defer { Board3DQuality.current = previous }
        let samples = samples ?? (quality.antialiasing == .multisampling4X ? 4 : quality.antialiasing == .multisampling2X ? 2 : 1)
        let bench = try XCTUnwrap(Board3DFrameBench(size: size, samples: samples))
        var camera = document.cameraOrDefault
        // The fit is solved once, as the live view does during a gesture.
        let framing = BoardOrbit.framing(field: document.fieldType, camera: camera, viewport: size)
        var cpu: [Double] = [], gpu: [Double] = [], wall: [Double] = []
        for frame in 0..<frames {
            camera.azimuthDegrees += 1.5
            camera.elevationDegrees = 34 + 8 * sin(Double(frame) / 12)
            let result = bench.frame(document: document, time: nil, camera: camera, framing: framing, at: TimeInterval(frame) / 60)
            if frame >= 10 { cpu.append(result.cpu); gpu.append(result.gpu); wall.append(result.wall) } // Skip warm-up.
        }
        let counts = Board3DFrameBench.drawCalls(bench.builder.scene.rootNode)
        let pixels = bench.readback()
        let drawn = stride(from: 0, to: pixels.count, by: 4 * 997).filter { pixels[$0] > 2 || pixels[$0 + 1] > 2 }.count
        print(String(format: "board3d-bench %@ %.0fx%.0f msaa%d: cpu med %.2f p95 %.2f | gpu med %.2f p95 %.2f | wall med %.2f p95 %.2f | nodes %d elements %d casters %d | lit samples %d",
                     name, size.width, size.height, samples, percentile(cpu, 0.5), percentile(cpu, 0.95), percentile(gpu, 0.5), percentile(gpu, 0.95),
                     percentile(wall, 0.5), percentile(wall, 0.95), counts.nodes, counts.elements, counts.casters, drawn))
        XCTAssertGreaterThan(drawn, 20, "\(name): the benchmark really rendered the board")
        return (cpu, gpu, wall)
    }

    /// A heavy animated board: stages, follow paths (one aerial), connected lines and camera keys.
    func animatedHeavyDocument() -> BoardDocument {
        var document = heavyDocument()
        let players = document.elements.filter { $0.kind.isPerson }
        var lob = BoardElement(kind: .arrow, position: BoardPoint(0.3, 0.4), points: [BoardPoint(0.92, 0.5)], colorHex: BoardPalette.white)
        lob.arcHeightMeters = 8
        document.elements.append(lob)
        var connected = BoardElement(kind: .line, position: players[0].position, points: [players[5].position], colorHex: BoardPalette.lime)
        connected.startAttachment = players[0].id
        connected.endAttachment = players[5].id
        document.elements.append(connected)
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        document.insertKeyframe(after: 1)
        for index in document.keyframes.indices { document.keyframes[index].duration = 1.5 }
        // Everyone shifts between stages; the ball flies along the lob.
        for element in document.elements where element.kind.isPerson {
            document.keyframes[1].poses[element.id]?.position = element.position.offset(dx: 0.05, dy: -0.03).clamped()
            document.keyframes[2].poses[element.id]?.position = element.position.offset(dx: -0.04, dy: 0.05).clamped()
        }
        if let ball = document.elements.first(where: { $0.kind == .ball }) {
            document.keyframes[0].paths = [ball.id: BoardFollowPath(pathID: lob.id)]
            document.keyframes[1].poses[ball.id]?.position = BoardPoint(0.92, 0.5)
        }
        document.keyframes[0].camera = BoardViewAngle.broadcast.defaultCamera
        document.keyframes[2].camera = BoardCamera(azimuthDegrees: 70, elevationDegrees: 28, distanceScale: 0.7, target: BoardPoint(0.7, 0.5))
        return document
    }

    /// Plays the board back frame by frame and reports the cost of a playback frame.
    @discardableResult
    private func measurePlayback(_ document: BoardDocument, name: String, onionFrame: Int? = nil, quality: Board3DQuality = .current,
                                 size: CGSize = CGSize(width: 1179, height: 2556), fps: Double = 60) throws -> (cpu: [Double], wall: [Double]) {
        let previous = Board3DQuality.current
        Board3DQuality.current = quality
        defer { Board3DQuality.current = previous }
        let bench = try XCTUnwrap(Board3DFrameBench(size: size, samples: quality.antialiasing == .multisampling4X ? 4 : 2))
        var cpu: [Double] = [], wall: [Double] = []
        let frames = Int(document.duration * fps)
        for frame in 0..<frames {
            let time = Double(frame) / fps
            let start = CACurrentMediaTime()
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            bench.builder.update(document: document, time: time, selectedID: nil)
            if let onionFrame {
                let skin = document.onionSkin(aroundFrame: onionFrame)
                bench.builder.updateGhosts(previous: skin.previous, next: skin.next, live: document.elements(at: time))
            }
            bench.builder.applyPose(BoardCameraResolver.pose(for: document, time: time, viewport: size), viewport: size)
            SCNTransaction.commit()
            let prepared = (CACurrentMediaTime() - start) * 1000
            let rendered = bench.render(at: TimeInterval(frame) / 60)
            if frame > 5 { cpu.append(prepared); wall.append(rendered) }
        }
        print(String(format: "board3d-bench %@ playback: cpu med %.2f p95 %.2f | wall med %.2f p95 %.2f | frames %d mesh rebuilds %d",
                     name, percentile(cpu, 0.5), percentile(cpu, 0.95), percentile(wall, 0.5), percentile(wall, 0.95), frames, bench.builder.pathRebuilds))
        return (cpu, wall)
    }

    func testPlaybackFrameBudget() throws {
        let document = animatedHeavyDocument()
        let plain = try measurePlayback(document, name: "heavy")
        _ = try measurePlayback(document, name: "heavy-onion", onionFrame: 1)
        if ProcessInfo.processInfo.environment["BOARD3D_BENCH_VARIANTS"] != nil {
            // "Before": the settings this work started from (high quality, a mesh rebuild whenever
            // any resolved vertex moves at all).
            var before = Board3DQuality.high
            before.lineRebuildTolerance = 0
            _ = try measurePlayback(document, name: "heavy-before", quality: before)
            _ = try measurePlayback(document, name: "heavy-after", quality: .automatic)
            var noEpsilon = Board3DQuality.automatic
            noEpsilon.lineRebuildTolerance = 0
            _ = try measurePlayback(document, name: "heavy-no-mesh-epsilon", quality: noEpsilon)
        }
        let cpuMedian = percentile(plain.cpu, 0.5), cpuP95 = percentile(plain.cpu, 0.95)
        if cpuMedian > 4 { print("board3d-bench WARNING: playback CPU median \(cpuMedian) ms is above the 4 ms budget") }
        // The measurements are always printed; the assertions are a generous smoke ceiling because
        // this machine is shared with other builds. BOARD3D_STRICT_PERF=1 asks for the real budget.
        XCTAssertLessThan(cpuMedian, Self.strictPerformance ? 10 : 60, "Playback frame preparation must fit in a 60 fps budget")
        XCTAssertLessThan(cpuP95, Self.strictPerformance ? 16 : 90, "Playback frame preparation must not spike")
    }

    // MARK: Review fixes

    /// Finding 1: the mannequin body geometry is shared, so its material must be copied before it
    /// is coloured or every mannequin ends up in whichever colour was applied last.
    @MainActor
    func testMannequinsAndWallsKeepTheirOwnColour() throws {
        var document = BoardDocument()
        document.fieldType = .footballFull
        document.viewAngle = .tilted
        let lime = BoardElement(kind: .mannequin, position: BoardPoint(0.3, 0.4), colorHex: BoardPalette.lime)
        let orange = BoardElement(kind: .mannequin, position: BoardPoint(0.5, 0.4), colorHex: BoardPalette.orange)
        let wall = BoardElement(kind: .wall, position: BoardPoint(0.7, 0.4), colorHex: BoardPalette.pink)
        document.elements = [lime, orange, wall]
        let builder = TacticalBoard3DScene()
        builder.update(document: document, time: nil, selectedID: nil)

        func bodyColour(_ id: UUID) throws -> UIColor {
            let node = try XCTUnwrap(builder.node(for: id))
            // The tallest capsule under the element node is the mannequin body.
            var found: UIColor?
            node.enumerateHierarchy { child, _ in
                guard found == nil, child.geometry is SCNCapsule, let colour = child.geometry?.firstMaterial?.diffuse.contents as? UIColor else { return }
                found = colour
            }
            return try XCTUnwrap(found)
        }
        XCTAssertEqual(try bodyColour(lime.id), BoardPalette.uiColor(BoardPalette.lime))
        XCTAssertEqual(try bodyColour(orange.id), BoardPalette.uiColor(BoardPalette.orange))
        XCTAssertEqual(try bodyColour(wall.id), BoardPalette.uiColor(BoardPalette.pink))
    }

    /// Finding 2: switching the field type while orbiting must re-fit the camera at once.
    @MainActor
    func testChangingTheFieldReframesTheOrbitCamera() throws {
        var document = BoardDocument()
        document.fieldType = .footballFull
        document.viewAngle = .tilted
        document.elements = [BoardElement(kind: .ball, position: BoardPoint(0.5, 0.5))]
        let coordinator = Board3DCoordinator()
        let view = Board3DSCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        coordinator.attach(view)
        func representable(_ document: BoardDocument) -> Board3DSceneView {
            Board3DSceneView(document: document, time: nil, selectedID: nil, camera: .constant(document.cameraOrDefault),
                             onSelect: { _ in }, onMove: { _, _, _ in }, onionFrame: nil)
        }
        coordinator.update(from: representable(document))
        let full = try XCTUnwrap(coordinator.currentPose).eye

        document.fieldType = .futsal
        coordinator.update(from: representable(document))
        let futsal = try XCTUnwrap(coordinator.currentPose).eye
        let expected = BoardOrbit(field: .futsal, camera: document.cameraOrDefault, viewport: view.bounds.size).eye
        XCTAssertGreaterThan(simd_distance(full, futsal), 1, "The camera moves when the pitch changes")
        XCTAssertLessThan(simd_distance(futsal, expected), 0.05, "And it is framed for the new pitch")
    }

    /// Finding 3: deleting the point-of-view subject must take the camera (and its chrome) out of
    /// point of view, not leave a dangling subject id behind.
    @MainActor
    func testDeletingThePointOfViewSubjectLeavesPointOfView() throws {
        var (document, keeperID, _, _) = attackDocument()
        document.camera = document.cameraOrDefault.pointOfView(subject: keeperID, lookAt: .ball)
        let coordinator = Board3DCoordinator()
        let view = Board3DSCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        coordinator.attach(view)
        func representable(_ document: BoardDocument) -> Board3DSceneView {
            Board3DSceneView(document: document, time: nil, selectedID: nil, camera: .constant(document.cameraOrDefault),
                             onSelect: { _ in }, onMove: { _, _, _ in }, onionFrame: nil)
        }
        coordinator.update(from: representable(document))
        XCTAssertEqual(coordinator.appliedCamera.resolvedMode, .pointOfView)
        XCTAssertEqual(coordinator.appliedCamera.subjectID, keeperID)

        document.removeElement(keeperID)
        coordinator.update(from: representable(document))
        XCTAssertNotEqual(coordinator.appliedCamera.resolvedMode, .pointOfView, "The chrome follows the mode the scene really shows")
        XCTAssertNil(coordinator.appliedCamera.subjectID)
        XCTAssertNil(coordinator.appliedCamera.lookAt)
        XCTAssertTrue(try XCTUnwrap(coordinator.currentPose).hiddenSubjects.isEmpty)
    }

    /// Finding 10: blending between two point-of-view keys must not drop the figure the camera is
    /// flying out of straight in front of the lens halfway through.
    func testBlendKeepsBothPointOfViewSubjectsHidden() {
        let a = UUID(), b = UUID()
        var from = BoardViewPose(eye: SIMD3(0, 2, 0), forward: SIMD3(1, 0, 0), fieldOfViewDegrees: 65, focusDistance: 10)
        from.hiddenSubjects = [a]
        var to = from
        to.eye = SIMD3(20, 2, 0)
        to.hiddenSubjects = [b]
        XCTAssertEqual(BoardViewPose.blend(from, to, 0).hiddenSubjects, [a])
        XCTAssertEqual(BoardViewPose.blend(from, to, 1).hiddenSubjects, [b])
        for t in [0.2, 0.49, 0.5, 0.51, 0.9] {
            XCTAssertEqual(BoardViewPose.blend(from, to, t).hiddenSubjects, [a, b], "t = \(t)")
        }
    }

    /// Finding 10: dragging an element must not rebuild the selection outline every frame.
    @MainActor
    func testSelectionOutlineIsReusedWhileDragging() throws {
        var document = BoardDocument()
        document.fieldType = .footballFull
        document.viewAngle = .tilted
        var player = BoardElement(kind: .player, position: BoardPoint(0.3, 0.4), colorHex: BoardPalette.home, number: 7)
        player.rotation = 0
        document.elements = [player]
        let builder = TacticalBoard3DScene()
        builder.update(document: document, time: nil, selectedID: player.id)
        let ring = try XCTUnwrap(builder.scene.rootNode.childNode(withName: "selection", recursively: false)?.childNodes.first)
        let geometry = try XCTUnwrap(ring.geometry)

        for step in 1...20 {
            document.elements[0].position = BoardPoint(0.3 + Double(step) * 0.01, 0.4)
            builder.update(document: document, time: nil, selectedID: player.id)
        }
        let selection = try XCTUnwrap(builder.scene.rootNode.childNode(withName: "selection", recursively: false))
        XCTAssertTrue(selection.childNodes.first === ring, "The outline node survives the drag")
        XCTAssertTrue(ring.geometry === geometry, "And its mesh is never rebuilt")
        XCTAssertGreaterThan(Double(selection.simdPosition.x * selection.simdPosition.x + selection.simdPosition.z * selection.simdPosition.z), 1,
                             "It followed the element instead")

        // A real change (a different size) still rebuilds it.
        document.elements[0].size = 2.5
        builder.update(document: document, time: nil, selectedID: player.id)
        XCTAssertFalse(try XCTUnwrap(builder.scene.rootNode.childNode(withName: "selection", recursively: false)?.childNodes.first) === ring)
    }

    /// Finding 6: generated textures must give their memory back under pressure.
    func testTextureCacheIsDroppedOnAMemoryWarning() throws {
        let first = try XCTUnwrap(Board3DTextures.shared.selectionRing())
        XCTAssertTrue(try XCTUnwrap(Board3DTextures.shared.selectionRing()) === first, "Cached between calls")
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertFalse(try XCTUnwrap(Board3DTextures.shared.selectionRing()) === first, "Dropped on a memory warning")
    }

    // MARK: Export file lifecycle (finding 4)

    private func exportsDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "board-exports-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testExportsWithTheSameNameDoNotOverwriteEachOther() async throws {
        let directory = exportsDirectory()
        var document = BoardDocument()
        document.fieldType = .futsal
        document.elements = [BoardElement(kind: .ball, position: BoardPoint(0.4, 0.5))]
        var other = document
        other.elements = [BoardElement(kind: .cone, position: BoardPoint(0.6, 0.5), colorHex: BoardPalette.orange)]

        let first = try await TacticalBoardExporter.export(BoardExportRequest(document: document, name: "Board 1", format: .png), to: directory)
        let second = try await TacticalBoardExporter.export(BoardExportRequest(document: other, name: "Board 1", format: .png), to: directory)
        XCTAssertNotEqual(first, second, "Two boards with the same name get their own file")
        XCTAssertEqual(first.lastPathComponent, second.lastPathComponent, "Both still share the name in the share sheet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path(percentEncoded: false)), "The first export is still there for a live ShareLink")
        XCTAssertNotEqual(try Data(contentsOf: first), try Data(contentsOf: second))

        // MP4 and HEVC both use the "mp4" extension.
        let mp4 = try await TacticalBoardExporter.export(BoardExportRequest(document: document, name: "Board 1", format: .mp4, framing: .square), to: directory)
        let hevc = try await TacticalBoardExporter.export(BoardExportRequest(document: document, name: "Board 1", format: .hevc, framing: .square), to: directory)
        XCTAssertNotEqual(mp4, hevc)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path(percentEncoded: false)))
    }

    func testOldExportsArePrunedButTheNewestAreKept() async throws {
        let directory = exportsDirectory()
        var document = BoardDocument()
        document.fieldType = .futsal
        var urls: [URL] = []
        for index in 0...(TacticalBoardExporter.keptExports + 2) {
            urls.append(try await TacticalBoardExporter.export(BoardExportRequest(document: document, name: "Board \(index)", format: .png), to: directory))
        }
        let folders = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        XCTAssertLessThanOrEqual(folders.count, TacticalBoardExporter.keptExports + 1, "tmp/BoardExports does not grow for ever")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(urls.last).path(percentEncoded: false)), "The newest export survives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path(percentEncoded: false)), "The oldest one is gone")
    }

    func testCancelledGIFExportLeavesNoTruncatedFile() async throws {
        let directory = exportsDirectory()
        var document = BoardDocument()
        document.fieldType = .footballFull
        document.elements = (0..<12).map { BoardElement(kind: .player, position: BoardPoint(0.1 + Double($0) * 0.07, 0.5), colorHex: BoardPalette.home, number: $0 + 1) }
        document.insertKeyframe(after: nil)
        document.keyframes[0].duration = 4

        let task = Task.detached {
            try await TacticalBoardExporter.export(BoardExportRequest(document: document, name: "Cancelled", format: .gif), to: directory)
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value
            // A very fast machine may finish before the cancel lands; then there is simply a file.
        } catch {
            let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            XCTAssertTrue(left.isEmpty, "A cancelled export leaves nothing behind, not a truncated GIF: \(left)")
        }
    }

    @MainActor
    func testExportProgressNeverGoesBackwards() {
        let model = BoardExportModel()
        model.isRunning = true
        for value in [0.1, 0.4, 0.3, 0.35, 0.9, 0.5, 1.0] { model.report(value) }
        XCTAssertEqual(model.progress, 1, accuracy: 0.0001, "Out-of-order hops never move the bar back")
    }

    func testOrbitFrameBudget() throws {
        let light = sampleDocument(field: .futsal, style: .court)
        let heavy = heavyDocument()
        let lightResult = try measureOrbit(light, name: "light")
        let heavyResult = try measureOrbit(heavy, name: "heavy")
        print("board3d-bench quality: \(Board3DQuality.current)")
        if ProcessInfo.processInfo.environment["BOARD3D_BENCH_VARIANTS"] != nil {
            // A/B of the quality profiles and of the pieces that cost most.
            _ = try measureOrbit(heavy, name: "heavy-high-quality", quality: .high)
            _ = try measureOrbit(heavy, name: "heavy-phone-quality", quality: .phone)
            var noShadows = Board3DQuality.phone
            noShadows.shadowSampleCount = 1
            noShadows.shadowRadius = 0
            _ = try measureOrbit(heavy, name: "heavy-phone-1tap-shadows", quality: noShadows)
            var noAA = Board3DQuality.phone
            noAA.antialiasing = .none
            _ = try measureOrbit(heavy, name: "heavy-phone-no-aa", quality: noAA)
            var bigShadow = Board3DQuality.phone
            bigShadow.shadowMapSize = CGSize(width: 2048, height: 2048)
            bigShadow.shadowSampleCount = 8
            _ = try measureOrbit(heavy, name: "heavy-2048-8tap-shadows", quality: bigShadow)
            _ = try measureOrbit(light, name: "light-high-quality", quality: .high)
            _ = try measureOrbit(light, name: "light-phone-quality", quality: .phone)
        }
        // Soft warning and hard ceiling; the simulator renders on the Mac GPU, so these are
        // generous. Phone numbers are in the report.
        for (name, result) in [("light", lightResult), ("heavy", heavyResult)] as [(String, (cpu: [Double], gpu: [Double], wall: [Double]))] {
            let cpuMedian = percentile(result.cpu, 0.5), gpuP95 = percentile(result.wall, 0.95)
            if cpuMedian > 2 { print("board3d-bench WARNING: \(name) CPU median \(cpuMedian) ms is above the 2 ms budget") }
            if gpuP95 > 8 { print("board3d-bench WARNING: \(name) GPU p95 \(gpuP95) ms is above the 8 ms budget") }
            XCTAssertLessThan(cpuMedian, Self.strictPerformance ? 6 : 40, "\(name): CPU work per frame must leave room for the GPU")
            XCTAssertLessThan(gpuP95, Self.strictPerformance ? 16.6 : 90, "\(name): frames must fit in a 60 fps budget")
        }
    }
}

// MARK: - Frame benchmark

/// Renders frames through Metal with a render pass we control, so we can read GPU time per frame
/// (`commandBuffer.gpuEndTime - gpuStartTime`) as well as the CPU time spent preparing the frame.
final class Board3DFrameBench {
    let builder = TacticalBoard3DScene()
    private let renderer: SCNRenderer
    private let queue: MTLCommandQueue
    private let color: MTLTexture
    private let multisample: MTLTexture?
    private let depth: MTLTexture
    let size: CGSize

    init?(size: CGSize, samples: Int = 4) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        self.size = size
        // Not every GPU supports every sample count (the simulator has no 2x), and an unsupported
        // texture descriptor aborts the process.
        var samples = samples
        while samples > 1 && !device.supportsTextureSampleCount(samples) { samples -= 1 }
        let width = Int(size.width), height = Int(size.height)
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        guard let color = device.makeTexture(descriptor: colorDescriptor) else { return nil }
        self.color = color
        if samples > 1 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = samples
            descriptor.usage = .renderTarget
            descriptor.storageMode = .private
            multisample = device.makeTexture(descriptor: descriptor)
        } else {
            multisample = nil
        }
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
        depthDescriptor.sampleCount = samples > 1 ? samples : 1
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let depth = device.makeTexture(descriptor: depthDescriptor) else { return nil }
        self.depth = depth
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = builder.scene
        renderer.pointOfView = builder.cameraNode
        renderer.autoenablesDefaultLighting = false
    }

    /// Prepares and renders one frame; returns milliseconds spent on the CPU and on the GPU.
    @discardableResult
    func frame(document: BoardDocument, time: Double?, camera: BoardCamera, framing: BoardFraming?, at frameTime: TimeInterval) -> (cpu: Double, gpu: Double, wall: Double) {
        let start = CACurrentMediaTime()
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        builder.update(document: document, time: time, selectedID: nil)
        builder.applyPose(BoardCameraResolver.pose(camera, in: document, time: time, viewport: size, framing: framing), viewport: size)
        SCNTransaction.commit()
        let cpu = (CACurrentMediaTime() - start) * 1000
        guard let buffer = queue.makeCommandBuffer() else { return (cpu, 0, 0) }
        let pass = MTLRenderPassDescriptor()
        if let multisample {
            pass.colorAttachments[0].texture = multisample
            pass.colorAttachments[0].resolveTexture = color
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        let submitted = CACurrentMediaTime()
        renderer.render(atTime: frameTime, viewport: CGRect(origin: .zero, size: size), commandBuffer: buffer, passDescriptor: pass)
        buffer.commit()
        buffer.waitUntilCompleted()
        let wall = (CACurrentMediaTime() - submitted) * 1000
        return (cpu, (buffer.gpuEndTime - buffer.gpuStartTime) * 1000, wall)
    }

    /// Renders the current scene state and returns the wall-clock milliseconds it took.
    func render(at frameTime: TimeInterval) -> Double {
        guard let buffer = queue.makeCommandBuffer() else { return 0 }
        let pass = MTLRenderPassDescriptor()
        if let multisample {
            pass.colorAttachments[0].texture = multisample
            pass.colorAttachments[0].resolveTexture = color
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        let start = CACurrentMediaTime()
        renderer.render(atTime: frameTime, viewport: CGRect(origin: .zero, size: size), commandBuffer: buffer, passDescriptor: pass)
        buffer.commit()
        buffer.waitUntilCompleted()
        return (CACurrentMediaTime() - start) * 1000
    }

    /// Reads the rendered texture back, to prove the pass really drew the scene.
    func readback() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 4 * Int(size.width) * Int(size.height))
        color.getBytes(&pixels, bytesPerRow: 4 * Int(size.width), from: MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)), mipmapLevel: 0)
        return pixels
    }

    /// Geometry elements below `node`: a good proxy for draw calls (SceneKit issues one per element,
    /// and again per shadow-casting light).
    static func drawCalls(_ node: SCNNode) -> (nodes: Int, elements: Int, casters: Int) {
        var nodes = 0, elements = 0, casters = 0
        node.enumerateHierarchy { child, _ in
            nodes += 1
            guard let geometry = child.geometry, !child.isHidden else { return }
            elements += geometry.elements.count
            if child.castsShadow { casters += geometry.elements.count }
        }
        return (nodes, elements, casters)
    }
}
