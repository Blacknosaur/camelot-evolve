import AVFoundation
import SwiftData
import UIKit
import XCTest
@testable import Camelot

final class TacticalBoardTests: XCTestCase {
    private func sampleDocument() -> BoardDocument {
        var document = BoardDocument()
        document.fieldType = .footballHalf
        var player = BoardElement(kind: .player, position: BoardPoint(0.3, 0.6), colorHex: BoardPalette.home, number: 7, label: "Sam")
        player.size = 1.25
        var arrow = BoardElement(kind: .arrow, position: BoardPoint(0.3, 0.6), points: [BoardPoint(0.7, 0.2), BoardPoint(0.5, 0.3)], colorHex: BoardPalette.white)
        arrow.isCurved = true; arrow.arrowStyle = .dribble; arrow.hasBlockEnd = true
        var zone = BoardElement(kind: .zone, position: BoardPoint(0.1, 0.1), points: [BoardPoint(0.4, 0.3)], colorHex: BoardPalette.keeper)
        zone.zoneShape = .ellipse; zone.opacity = 0.5
        var text = BoardElement(kind: .text, position: BoardPoint(0.5, 0.9))
        text.label = "Press high"
        document.elements = [zone, arrow, player, text, BoardElement(kind: .ball, position: BoardPoint(0.32, 0.58))]
        return document
    }

    private func assertClose(_ actual: [BoardPoint], _ expected: [BoardPoint], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-9, file: file, line: line)
        }
    }

    private func assertClose(_ actual: BoardPoint?, _ expected: BoardPoint, file: StaticString = #filePath, line: UInt = #line) {
        assertClose(actual.map { [$0] } ?? [], [expected], file: file, line: line)
    }

    private func decodeFixture() throws -> BoardDocument {
        try JSONDecoder().decode(BoardDocument.self, from: Data(Self.phoneBoardJSON.utf8))
    }

    // MARK: Document

    func testPhoneBoardFixtureDecodesWithEveryElementAndKeyframe() throws {
        let document = try decodeFixture()
        XCTAssertEqual(document.fieldType, .footballFull)
        XCTAssertEqual(document.viewAngle, .broadcast)
        XCTAssertEqual(document.elements.count, 27)
        XCTAssertEqual(document.keyframes.count, 2)
        XCTAssertNil(document.style, "Saved before styles existed")
        XCTAssertEqual(document.fieldStyle, .grass)
        XCTAssertTrue(document.elements.allSatisfy { $0.lineStyle == nil && $0.startAttachment == nil })
        XCTAssertEqual(document.elements.filter { $0.kind == .arrow }.count, 5)
        // Old keyframe poses have no rotation or size; applying them keeps the element's values.
        var shown = document
        shown.showFrame(1)
        XCTAssertEqual(shown.elements.count, 27)
        XCTAssertEqual(document.elements(at: 0.5).count, 27, "Every element is resolved mid-transition too")
        // It still round-trips and renders.
        let reencoded = try JSONDecoder().decode(BoardDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(reencoded, document)
        var top = document
        top.viewAngle = .top
        XCTAssertNotNil(TacticalBoardExporter.imageData(document: top, size: CGSize(width: 320, height: 200), scale: 1, jpeg: false))
        // And in its saved 3D broadcast angle, through SceneKit.
        let broadcast = try XCTUnwrap(TacticalBoardExporter.imageData(document: document, size: CGSize(width: 320, height: 200), scale: 2, jpeg: false))
        XCTAssertEqual(UIImage(data: broadcast)?.cgImage?.width, 640)
    }

    func testRemovingAKeyframeKeepsElementsRecordedOnlyThere() {
        var document = BoardDocument()
        let early = BoardElement(kind: .player, position: BoardPoint(0.2, 0.2))
        document.elements = [early]
        document.insertKeyframe(after: nil)
        let late = BoardElement(kind: .cone, position: BoardPoint(0.8, 0.8))
        document.elements.append(late)
        let second = document.insertKeyframe(after: 0)
        document.insertKeyframe(after: second)
        document.keyframes[2].poses[late.id] = nil

        document.removeKeyframe(at: 1)
        XCTAssertEqual(document.keyframes.count, 2)
        XCTAssertEqual(document.pose(of: late.id, atFrame: 1)?.position, BoardPoint(0.8, 0.8), "The pose moves to the next frame")

        document.removeKeyframe(at: 1)
        XCTAssertEqual(document.pose(of: late.id, atFrame: 0)?.position, BoardPoint(0.8, 0.8), "Deleting the last frame moves it back")
        XCTAssertEqual(document.pose(of: early.id, atFrame: 0)?.position, BoardPoint(0.2, 0.2), "Existing poses are not overwritten")
    }

    func testDocumentRoundTripsThroughJSON() throws {
        var document = sampleDocument()
        document.style = .chalk
        document.camera = BoardCamera(azimuthDegrees: 30, elevationDegrees: 40, distanceScale: 1.2)
        document.elements[1].lineStyle = BoardLineStyle(pattern: .dotted, shape: .zigzag, startCap: .dot, endCap: .bar, width: 1.5, opacity: 0.5)
        document.elements[1].endAttachment = document.elements[2].id
        document.elements[0].borderPattern = .dashed
        document.elements[0].showsBorder = false
        document.insertKeyframe(after: nil)
        document.keyframes[0].duration = 1.5
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(BoardDocument.self, from: data)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.elements.count, 5)
        XCTAssertEqual(decoded.keyframes[0].poses.count, 5)
    }

    func testModelStoresAndDecodesDocument() {
        let sample = sampleDocument()
        let board = TacticalBoard(name: "Corner routine", document: sample)
        XCTAssertEqual(board.fieldType, BoardFieldType.footballHalf.rawValue)
        XCTAssertEqual(board.field, .footballHalf)
        XCTAssertEqual(board.loadedDocument, sample)
        var updated = sample
        updated.viewAngle = .broadcast
        board.store(updated)
        XCTAssertEqual(board.viewAngle, "broadcast")
        XCTAssertEqual(board.loadedDocument?.viewAngle, .broadcast)
        XCTAssertTrue(board.thumbnailURL.lastPathComponent.hasSuffix("-v2.png"))
        XCTAssertEqual(board.allThumbnailURLs.count, 2)
    }

    func testPlayerNumbersIncrementPerTeam() {
        var document = BoardDocument()
        document.elements = [
            BoardElement(kind: .player, position: .center, colorHex: document.homeColorHex, number: 4),
            BoardElement(kind: .player, position: .center, colorHex: document.awayColorHex, number: 9),
        ]
        XCTAssertEqual(document.nextNumber(for: .player, colorHex: document.homeColorHex), 5)
        XCTAssertEqual(document.nextNumber(for: .player, colorHex: document.awayColorHex), 10)
        XCTAssertEqual(document.nextNumber(for: .goalkeeper, colorHex: BoardPalette.keeper), 1)
    }

    // MARK: Unreadable boards

    /// An in-memory store; boards live in one so deletion and duplication can be exercised for real.
    @MainActor private func boardContext() throws -> ModelContext {
        let container = try ModelContainer(for: Project.self, MatchEvent.self, Recording.self, VideoComposition.self, TacticalBoard.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testGarbageBoardDataIsRefusedRatherThanReadAsAnEmptyBoard() throws {
        let board = TacticalBoard(name: "Broken", document: sampleDocument())
        board.document = Data("this is not a board".utf8)
        XCTAssertThrowsError(try board.load()) { XCTAssertEqual($0 as? BoardLoadError, .unreadable) }
        XCTAssertNil(board.loadedDocument)
        XCTAssertFalse(board.isReadable)
        // Truncated JSON, the other way a real file goes wrong.
        let whole = try JSONEncoder().encode(sampleDocument())
        board.document = whole.prefix(whole.count / 2)
        XCTAssertThrowsError(try board.load())
    }

    func testAnUnknownElementKindMakesTheBoardUnreadable() throws {
        var raw = try XCTUnwrap(String(data: try JSONEncoder().encode(sampleDocument()), encoding: .utf8))
        raw = raw.replacingOccurrences(of: "\"kind\":\"player\"", with: "\"kind\":\"jetpack\"")
        XCTAssertTrue(raw.contains("jetpack"), "The fixture has a player to rename")
        let board = TacticalBoard(name: "From the future", document: BoardDocument())
        board.document = Data(raw.utf8)
        XCTAssertThrowsError(try board.load()) { XCTAssertEqual($0 as? BoardLoadError, .unreadable) }
    }

    func testADocumentFromANewerVersionIsRefusedInsteadOfPartlyRead() throws {
        var document = sampleDocument()
        document.version = BoardDocument.currentVersion + 1
        let board = TacticalBoard(name: "Newer", document: document)
        XCTAssertThrowsError(try board.load()) {
            XCTAssertEqual($0 as? BoardLoadError, .newerVersion(BoardDocument.currentVersion + 1))
        }
        XCTAssertFalse(board.isReadable)
    }

    /// The data-loss case: the editor falls back to an empty document, the user edits it, and the
    /// autosave must not write that over the real board.
    func testEditingAfterAFailedLoadNeverOverwritesTheStoredBytes() throws {
        let board = TacticalBoard(name: "Broken", document: sampleDocument())
        let real = Data("{\"elements\": <corrupt but precious>}".utf8)
        board.document = real
        let stamp = board.updatedAt

        var fallback = BoardDocument()
        fallback.elements = [BoardElement(kind: .cone, position: .center)]
        XCTAssertFalse(board.store(fallback), "Storing over an unreadable board is refused")
        XCTAssertEqual(board.document, real, "The stored bytes are untouched")
        XCTAssertEqual(board.updatedAt, stamp, "And the board is not marked as edited")
        XCTAssertFalse(board.store(BoardDocument()), "Including an empty document")
        XCTAssertEqual(board.document, real)

        // A readable board still saves normally.
        let healthy = TacticalBoard(name: "Fine", document: sampleDocument())
        XCTAssertTrue(healthy.store(fallback))
        XCTAssertEqual(healthy.loadedDocument, fallback)
    }

    @MainActor
    func testDuplicatingABoardCopiesItsDocumentAndThumbnailAndRefusesAnUnreadableOne() throws {
        let context = try boardContext()
        let document = sampleDocument()
        let board = TacticalBoard(name: "Corner", document: document)
        context.insert(board)
        try FileManager.default.createDirectory(at: TacticalBoard.folder, withIntermediateDirectories: true)
        try TacticalBoardExporter.writeThumbnail(document: document, to: board.thumbnailURL)
        addTeardownBlock { for url in board.allThumbnailURLs { try? FileManager.default.removeItem(at: url) } }

        let copy = try board.duplicate(into: context)
        addTeardownBlock { for url in copy.allThumbnailURLs { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(copy.name, "Corner copy")
        XCTAssertNotEqual(copy.id, board.id)
        XCTAssertEqual(copy.loadedDocument, document)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.thumbnailURL.path(percentEncoded: false)), "The copy shows a preview straight away")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TacticalBoard>()), 2)

        board.document = Data("broken".utf8)
        XCTAssertThrowsError(try board.duplicate(into: context)) { XCTAssertEqual($0 as? BoardLoadError, .unreadable) }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TacticalBoard>()), 2, "No empty copy is inserted")
    }

    @MainActor
    func testDeletingABoardRemovesItAndEveryThumbnailItEverWrote() throws {
        let context = try boardContext()
        let board = TacticalBoard(name: "Drill", document: sampleDocument())
        context.insert(board)
        try FileManager.default.createDirectory(at: TacticalBoard.folder, withIntermediateDirectories: true)
        for url in board.allThumbnailURLs { try Data("png".utf8).write(to: url) }
        XCTAssertEqual(board.allThumbnailURLs.count, 2, "The current thumbnail and the older renderer's")
        let other = TacticalBoard(name: "Kept", document: sampleDocument())
        context.insert(other)
        try Data("png".utf8).write(to: other.thumbnailURL)
        addTeardownBlock { for url in other.allThumbnailURLs { try? FileManager.default.removeItem(at: url) } }

        board.delete(from: context)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<TacticalBoard>()).map(\.name), ["Kept"])
        for url in board.allThumbnailURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "\(url.lastPathComponent) is cleaned up")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.thumbnailURL.path(percentEncoded: false)), "Other boards keep theirs")
    }

    // MARK: Migration

    func testLegacyStoreWithProjectIDMigrates() throws {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "legacy.store")
        let document = try decodeFixture()
        let id = UUID()
        do {
            let legacy = try ModelContainer(for: Schema([LegacyBoardSchema.TacticalBoard.self]), configurations: ModelConfiguration(url: url))
            let context = ModelContext(legacy)
            context.insert(LegacyBoardSchema.TacticalBoard(id: id, projectID: UUID(), name: "Phone board", document: try JSONEncoder().encode(document)))
            try context.save()
        }
        let current = try ModelContainer(for: Project.self, MatchEvent.self, Recording.self, VideoComposition.self, TacticalBoard.self, configurations: ModelConfiguration(url: url))
        let boards = try ModelContext(current).fetch(FetchDescriptor<TacticalBoard>())
        XCTAssertEqual(boards.count, 1)
        XCTAssertEqual(boards.first?.id, id)
        XCTAssertEqual(boards.first?.name, "Phone board")
        XCTAssertEqual(boards.first?.loadedDocument, document)
    }

    /// Opens a copy of a real SwiftData store from a phone. Run with
    /// `TEST_RUNNER_CAMELOT_BOARD_STORE_SNAPSHOT=<folder with default.store> xcodebuild test …`.
    func testPhoneStoreSnapshotMigrates() throws {
        guard let path = ProcessInfo.processInfo.environment["CAMELOT_BOARD_STORE_SNAPSHOT"] else {
            throw XCTSkip("Set TEST_RUNNER_CAMELOT_BOARD_STORE_SNAPSHOT to a folder containing default.store")
        }
        let source = URL(filePath: path, directoryHint: .isDirectory)
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-shm", "-wal"] {
            let file = source.appending(path: "default.store\(suffix)")
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                try FileManager.default.copyItem(at: file, to: folder.appending(path: "default.store\(suffix)"))
            }
        }
        let container = try ModelContainer(for: Project.self, MatchEvent.self, Recording.self, VideoComposition.self, TacticalBoard.self,
                                           configurations: ModelConfiguration(url: folder.appending(path: "default.store")))
        let context = ModelContext(container)
        let boards = try context.fetch(FetchDescriptor<TacticalBoard>())
        XCTAssertEqual(boards.count, 1)
        let document = try XCTUnwrap(boards.first).load()
        XCTAssertEqual(document.elements.count, 27)
        XCTAssertEqual(document.keyframes.count, 2)
        XCTAssertEqual(document, try decodeFixture())
        XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<Project>()), 0, "Other data is untouched")
    }

    // MARK: Keyframes and poses

    func testKeyframeInterpolationEasesBetweenFrames() {
        var document = BoardDocument()
        let id = UUID()
        document.elements = [BoardElement(id: id, kind: .player, position: BoardPoint(0.2, 0.2))]
        document.insertKeyframe(after: nil)
        document.elements[0].position = BoardPoint(0.8, 0.2)
        document.insertKeyframe(after: 0)
        document.keyframes[0].duration = 2
        XCTAssertEqual(document.duration, 3, accuracy: 0.0001)

        XCTAssertEqual(document.elements(at: 0)[0].position.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(document.elements(at: 1)[0].position.x, 0.5, accuracy: 0.0001, "Halfway through an ease-in-out is the midpoint")
        let quarter = document.elements(at: 0.5)[0].position.x
        XCTAssertLessThan(quarter, 0.35, "Ease-in starts slowly")
        XCTAssertGreaterThan(quarter, 0.2)
        XCTAssertEqual(document.elements(at: 2)[0].position.x, 0.8, accuracy: 0.0001)
        XCTAssertEqual(document.elements(at: 2.9)[0].position.x, 0.8, accuracy: 0.0001, "The last frame holds")
        XCTAssertEqual(document.elements(at: 99)[0].position.x, 0.8, accuracy: 0.0001)
    }

    func testPoseInterpolatesRotationAlongShortestArcAndSize() {
        var from = BoardPose(position: BoardPoint(0, 0))
        from.rotation = 350; from.size = 1
        var to = BoardPose(position: BoardPoint(1, 1))
        to.rotation = 10; to.size = 2
        let half = from.lerp(to: to, 0.5)
        XCTAssertEqual(half.rotation ?? -1, 360, accuracy: 0.0001, "350° → 10° turns 20° through 0°")
        XCTAssertEqual(half.size ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(from.lerp(to: to, 1).rotation.map { $0.truncatingRemainder(dividingBy: 360) } ?? -1, 10, accuracy: 0.0001)

        var back = BoardPose(position: .center); back.rotation = -170
        var forward = BoardPose(position: .center); forward.rotation = 170
        XCTAssertEqual(back.lerp(to: forward, 0.5).rotation ?? 0, -180, accuracy: 0.0001, "−170° → 170° turns 20° backwards")

        // Nil (old keyframes) falls back to whichever side has a value, and applying nil keeps the element's value.
        let legacy = BoardPose(position: .center)
        XCTAssertEqual(legacy.lerp(to: to, 0.3).rotation, 10)
        XCTAssertEqual(from.lerp(to: legacy, 0.3).rotation, 350)
        XCTAssertNil(legacy.lerp(to: legacy, 0.5).size)
        var element = BoardElement(kind: .player, position: .center)
        element.rotation = 45; element.size = 2
        element.pose = legacy
        XCTAssertEqual(element.rotation, 45)
        XCTAssertEqual(element.size, 2)
    }

    func testRotationAndSizeAnimateThroughKeyframes() {
        var document = BoardDocument()
        document.elements = [BoardElement(kind: .player, position: .center)]
        document.insertKeyframe(after: nil)
        document.elements[0].rotation = 90
        document.elements[0].size = 3
        document.insertKeyframe(after: 0)
        let mid = document.elements(at: 0.5)[0]
        XCTAssertEqual(mid.rotation, 45, accuracy: 0.0001)
        XCTAssertEqual(mid.size, 2, accuracy: 0.0001)
    }

    func testElementsAddedLaterExistFromTheirFirstFrame() {
        var document = BoardDocument()
        document.elements = [BoardElement(kind: .player, position: BoardPoint(0.2, 0.2))]
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        let cone = BoardElement(kind: .cone, position: BoardPoint(0.6, 0.6))
        document.elements.append(cone)
        document.recordPoses(in: 1, only: cone.id)
        XCTAssertEqual(document.elements(at: 0).count, 1)
        XCTAssertEqual(document.elements(at: 0.999).count, 1)
        XCTAssertEqual(document.elements(at: 1.0).count, 2)
        document.showFrame(1)
        document.keyframes.append(BoardKeyframe())
        XCTAssertEqual(document.elements(at: 2.5).count, 2)
        XCTAssertEqual(document.elements(at: 2.5).last?.position, cone.position)
        document.removeElement(cone.id)
        XCTAssertTrue(document.keyframes.allSatisfy { $0.poses[cone.id] == nil })
    }

    func testShowFrameLoadsPosesIntoElements() {
        var document = BoardDocument()
        document.elements = [BoardElement(kind: .ball, position: BoardPoint(0.1, 0.1))]
        document.insertKeyframe(after: nil)
        document.elements[0].position = BoardPoint(0.9, 0.9)
        document.insertKeyframe(after: 0)
        document.showFrame(0)
        XCTAssertEqual(document.elements[0].position, BoardPoint(0.1, 0.1))
        document.showFrame(1)
        XCTAssertEqual(document.elements[0].position, BoardPoint(0.9, 0.9))
        XCTAssertEqual(document.frameProgress(at: 1.5).index, 1)
        XCTAssertEqual(document.frameStart(1), 1, accuracy: 0.0001)
    }

    /// The editor reloads the current stage's poses whenever playback stops or a stage is re-selected.
    /// That reload has to be a no-op when nothing moved, or merely pausing would mark the board edited.
    func testShowingTheFrameAlreadyOnScreenChangesNothing() {
        var document = BoardDocument()
        let player = BoardElement(kind: .player, position: BoardPoint(0.2, 0.2))
        let line = BoardElement(kind: .line, position: BoardPoint(0.1, 0.1), points: [BoardPoint(0.9, 0.9)])
        document.elements = [player, line]
        document.insertKeyframe(after: nil)
        document.update(player.id) { $0.position = BoardPoint(0.7, 0.4) }
        document.insertKeyframe(after: 0)
        document.recordPoses(in: 1)
        document.attachToPath(player.id, pathID: line.id, fromFrame: 0)

        for frame in document.keyframes.indices {
            document.showFrame(frame)
            let settled = document
            document.showFrame(frame)
            XCTAssertEqual(document, settled, "Re-showing stage \(frame + 1) is a no-op")
        }
    }

    // MARK: Rotate and resize

    private func meters(_ p: BoardPoint, _ field: BoardFieldType) -> CGPoint {
        CGPoint(x: p.x * field.meters.width, y: p.y * field.meters.height)
    }

    func testMultiPointShapesRotateAndScaleAroundTheirCentroidInMetres() {
        let field = BoardFieldType.footballFull
        let polygon = BoardElement(kind: .polygon, position: BoardPoint(0.4, 0.4), points: [BoardPoint(0.6, 0.4), BoardPoint(0.6, 0.6), BoardPoint(0.4, 0.6)])
        let turned = polygon.transformed(rotation: 90, scale: 2, field: field)
        XCTAssertEqual(turned.rotation, 90)
        XCTAssertEqual(turned.pivot.x, polygon.pivot.x, accuracy: 1e-9, "The centroid stays put")
        XCTAssertEqual(turned.pivot.y, polygon.pivot.y, accuracy: 1e-9)
        let c = meters(polygon.pivot, field)
        for (before, after) in zip(polygon.allPoints, turned.allPoints) {
            let a = meters(before, field), b = meters(after, field)
            let va = CGVector(dx: a.x - c.x, dy: a.y - c.y), vb = CGVector(dx: b.x - c.x, dy: b.y - c.y)
            XCTAssertEqual(hypot(vb.dx, vb.dy), 2 * hypot(va.dx, va.dy), accuracy: 1e-6, "Distances double in metres")
            // 90° clockwise on the top view: (x, y) → (−y, x).
            XCTAssertEqual(vb.dx, -2 * va.dy, accuracy: 1e-6)
            XCTAssertEqual(vb.dy, 2 * va.dx, accuracy: 1e-6)
        }

        var line = BoardElement(kind: .line, position: BoardPoint(0.2, 0.5), points: [BoardPoint(0.4, 0.5)])
        line.isCurved = true
        line.points.append(BoardPoint(0.3, 0.4))
        let rotatedLine = line.transformed(rotation: 180, scale: 1, field: field)
        XCTAssertEqual(rotatedLine.position.x, 0.4, accuracy: 1e-9, "Ends swap places")
        XCTAssertEqual(rotatedLine.arrowEnd.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rotatedLine.curveControl?.y ?? 0, 0.6, accuracy: 1e-9, "The control point turns too")

        let back = turned.transformed(rotation: 0, scale: 0.5, field: field)
        for (a, b) in zip(back.allPoints, polygon.allPoints) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9); XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        }
    }

    func testPointElementsAndZonesStoreRotationAndClampSize() {
        let player = BoardElement(kind: .player, position: .center)
        let big = player.transformed(rotation: 30, scale: 10, field: .futsal)
        XCTAssertEqual(big.size, 3)
        XCTAssertEqual(big.rotation, 30)
        XCTAssertEqual(big.position, player.position)
        XCTAssertEqual(player.transformed(rotation: 0, scale: 0.01, field: .futsal).size, 0.4)

        let zone = BoardElement(kind: .zone, position: BoardPoint(0.2, 0.2), points: [BoardPoint(0.4, 0.6)])
        let rotatedZone = zone.transformed(rotation: 45, scale: 1, field: .footballFull)
        XCTAssertEqual(rotatedZone.position, zone.position, "Zones keep their corners and draw rotated")
        XCTAssertEqual(rotatedZone.rotation, 45)
        let scaledZone = zone.transformed(rotation: 0, scale: 2, field: .footballFull)
        XCTAssertEqual(scaledZone.position.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(scaledZone.opposite.y, 0.8, accuracy: 1e-9)
    }

    // MARK: Lines and connections

    func testLegacyArrowsResolveToLineStyles() {
        var pass = BoardElement(kind: .arrow, position: .center, points: [BoardPoint(0.8, 0.5)])
        XCTAssertEqual(pass.resolvedLineStyle, BoardLineStyle(pattern: .solid, shape: .straight, startCap: .none, endCap: .arrow, width: 1))
        pass.arrowStyle = .run; pass.isDoubleHeaded = true; pass.size = 1.5
        XCTAssertEqual(pass.resolvedLineStyle, BoardLineStyle(pattern: .dashed, shape: .straight, startCap: .arrow, endCap: .arrow, width: 1.5))
        pass.arrowStyle = .dribble; pass.hasBlockEnd = true; pass.isDoubleHeaded = false
        XCTAssertEqual(pass.resolvedLineStyle, BoardLineStyle(pattern: .solid, shape: .wavy, startCap: .none, endCap: .bar, width: 1.5))
        pass.lineStyle = .run
        XCTAssertEqual(pass.resolvedLineStyle, .run, "A stored style wins")

        var curved = BoardElement(kind: .arrow, position: .center, points: [BoardPoint(0.8, 0.5), BoardPoint(0.6, 0.2)])
        XCTAssertNil(curved.curveControl)
        curved.isCurved = true
        XCTAssertEqual(curved.lineVertices, [.center, BoardPoint(0.8, 0.5)])
        XCTAssertEqual(curved.curveControl, BoardPoint(0.6, 0.2))

        // Legacy freehand lines are polylines through every point.
        let freehand = BoardElement(kind: .line, position: BoardPoint(0.1, 0.1), points: [BoardPoint(0.2, 0.2), BoardPoint(0.3, 0.1), BoardPoint(0.4, 0.2)])
        XCTAssertEqual(freehand.lineVertices.count, 4)
        XCTAssertNil(freehand.curveControl)
        XCTAssertEqual(freehand.resolvedLineStyle.endCap, .none)
        XCTAssertTrue(freehand.isLineLike)
        XCTAssertFalse(BoardElementKind.polyline.isPoint)
    }

    private func connectedDocument() -> (BoardDocument, passer: UUID, receiver: UUID, line: UUID) {
        var document = BoardDocument()
        let passer = BoardElement(kind: .player, position: BoardPoint(0.2, 0.5))
        let receiver = BoardElement(kind: .player, position: BoardPoint(0.6, 0.5))
        var line = BoardElement(kind: .line, position: BoardPoint(0.2, 0.5), points: [BoardPoint(0.6, 0.5)])
        line.startAttachment = passer.id
        line.endAttachment = receiver.id
        document.elements = [passer, receiver, line]
        return (document, passer.id, receiver.id, line.id)
    }

    func testAttachedLineEndsFollowElementsIncludingDuringAnimation() throws {
        var (document, _, receiver, lineID) = connectedDocument()
        document.update(receiver) { $0.position = BoardPoint(0.7, 0.8) }
        XCTAssertEqual(document.elements(at: nil).first { $0.id == lineID }?.arrowEnd, BoardPoint(0.7, 0.8), "The static layout resolves attachments")
        XCTAssertEqual(document.elements.first { $0.id == lineID }?.arrowEnd, BoardPoint(0.6, 0.5), "Stored points are untouched")

        document.insertKeyframe(after: nil)
        document.update(receiver) { $0.position = BoardPoint(0.9, 0.2) }
        document.insertKeyframe(after: 0)
        let mid = document.elements(at: 0.5)
        let receiverMid = try XCTUnwrap(mid.first { $0.id == receiver })
        XCTAssertEqual(try XCTUnwrap(mid.first { $0.id == lineID }).arrowEnd, receiverMid.position, "Mid-animation the end sits on the moving player")
        XCTAssertEqual(document.elements(at: 1).first { $0.id == lineID }?.arrowEnd, BoardPoint(0.9, 0.2))

        document.settleAttachments()
        XCTAssertEqual(document.elements.first { $0.id == lineID }?.arrowEnd, BoardPoint(0.9, 0.2))
        XCTAssertEqual(document.visualRadiusMeters(of: document.elements[0]), 3.1 * 0.68, accuracy: 1e-9)
    }

    func testDeletingAnElementDetachesLinesAtItsLastPosition() throws {
        var (document, passer, receiver, lineID) = connectedDocument()
        document.insertKeyframe(after: nil)
        document.update(receiver) { $0.position = BoardPoint(0.8, 0.3) }
        document.insertKeyframe(after: 0)
        document.removeElement(receiver)
        let line = try XCTUnwrap(document.elements.first { $0.id == lineID })
        XCTAssertNil(line.endAttachment)
        XCTAssertEqual(line.startAttachment, passer, "Other attachments stay")
        XCTAssertEqual(line.arrowEnd, BoardPoint(0.8, 0.3))
        XCTAssertEqual(document.keyframes[0].poses[lineID]?.points.first, BoardPoint(0.6, 0.5), "Each frame keeps the end where the element was then")
        XCTAssertEqual(document.keyframes[1].poses[lineID]?.points.first, BoardPoint(0.8, 0.3))
        XCTAssertEqual(document.elements(at: 0).first { $0.id == lineID }?.arrowEnd, BoardPoint(0.6, 0.5))
    }

    func testAttachmentTargetFindsNearestPointElement() {
        let (document, passer, receiver, lineID) = connectedDocument()
        XCTAssertEqual(document.attachmentTarget(near: BoardPoint(0.21, 0.5), withinMeters: 3), passer)
        XCTAssertEqual(document.attachmentTarget(near: BoardPoint(0.21, 0.5), withinMeters: 3, excluding: passer), nil)
        XCTAssertEqual(document.attachmentTarget(near: BoardPoint(0.58, 0.51), withinMeters: 3), receiver)
        XCTAssertNotEqual(document.attachmentTarget(near: BoardPoint(0.4, 0.5), withinMeters: 1), lineID, "Lines are never targets")
    }

    func testPolylineVerticesInsertAndDeleteInEveryKeyframe() {
        var document = BoardDocument()
        var polyline = BoardElement(kind: .polyline, position: BoardPoint(0.1, 0.1), points: [BoardPoint(0.5, 0.1), BoardPoint(0.5, 0.5)])
        polyline.endAttachment = UUID()
        polyline.startAttachment = UUID()
        document.elements = [polyline]
        document.insertKeyframe(after: nil)
        document.insertVertex(in: polyline.id, after: 0)
        assertClose(document.elements[0].lineVertices, [BoardPoint(0.1, 0.1), BoardPoint(0.3, 0.1), BoardPoint(0.5, 0.1), BoardPoint(0.5, 0.5)])
        XCTAssertEqual(document.keyframes[0].poses[polyline.id]?.points.count, 3, "Keyframes gain the vertex too")

        document.removeVertex(in: polyline.id, at: 2)
        assertClose(document.elements[0].lineVertices, [BoardPoint(0.1, 0.1), BoardPoint(0.3, 0.1), BoardPoint(0.5, 0.5)])
        XCTAssertNotNil(document.elements[0].endAttachment, "Removing a middle vertex keeps attachments")
        document.removeVertex(in: polyline.id, at: 2)
        assertClose(document.elements[0].lineVertices, [BoardPoint(0.1, 0.1), BoardPoint(0.3, 0.1)])
        XCTAssertNil(document.elements[0].endAttachment, "Removing the end vertex drops its attachment")
        document.removeVertex(in: polyline.id, at: 0)
        XCTAssertEqual(document.elements[0].lineVertices.count, 2, "A polyline keeps at least two vertices")
        XCTAssertEqual(document.keyframes[0].poses[polyline.id]?.points.count, 1)
    }

    func testCurveControlAppliesToEveryKeyframe() {
        var document = BoardDocument()
        let line = BoardElement(kind: .line, position: BoardPoint(0.2, 0.2), points: [BoardPoint(0.4, 0.2)])
        document.elements = [line]
        document.insertKeyframe(after: nil)
        document.update(line.id) { $0.pose = $0.pose.translated(dx: 0, dy: 0.5) }
        document.insertKeyframe(after: 0)
        document.showFrame(0)
        document.setCurveControl(of: line.id, to: BoardPoint(0.3, 0.1))
        assertClose(document.elements[0].curveControl, BoardPoint(0.3, 0.1))
        let frameTwo = document.keyframes[1].poses[line.id]
        XCTAssertEqual(frameTwo?.points.count, 2)
        XCTAssertEqual(frameTwo?.points[1].y ?? 0, 0.6, accuracy: 1e-9, "Frame 2 bends by the same offset")
        document.setCurveControl(of: line.id, to: nil)
        XCTAssertNil(document.elements[0].curveControl)
        XCTAssertEqual(document.keyframes[1].poses[line.id]?.points.count, 1)
    }

    // MARK: Projection and hit testing

    func testTopViewIsAnAspectFit() {
        let projection = BoardProjection(field: .footballFull, size: CGSize(width: 800, height: 400))
        let topLeft = projection.point(BoardPoint(0, 0)), bottomRight = projection.point(BoardPoint(1, 1)), center = projection.point(.center)
        XCTAssertEqual(center.x, 400, accuracy: 0.01)
        XCTAssertEqual(center.y, 200, accuracy: 0.01)
        XCTAssertEqual(bottomRight.x - topLeft.x, (bottomRight.y - topLeft.y) * 105 / 68, accuracy: 0.01, "Field keeps its aspect ratio")
        XCTAssertTrue(CGRect(origin: .zero, size: CGSize(width: 800, height: 400)).insetBy(dx: -0.01, dy: -0.01).contains(projection.surfaceFrame), "Field and run-off fit")
        for p in [BoardPoint(0, 0), BoardPoint(1, 1), BoardPoint(0.25, 0.8)] {
            let round = projection.unproject(projection.point(p))
            XCTAssertEqual(round.x, p.x, accuracy: 0.0001); XCTAssertEqual(round.y, p.y, accuracy: 0.0001)
        }
        XCTAssertEqual(projection.unit, 0.68 * projection.pixelsPerMeter, accuracy: 0.0001)
    }

    func testPortraitRotatesTheLengthAxis() {
        let portrait = BoardProjection(field: .footballFull, size: CGSize(width: 400, height: 800))
        XCTAssertTrue(portrait.rotated)
        let start = portrait.point(BoardPoint(0, 0.5)), end = portrait.point(BoardPoint(1, 0.5))
        XCTAssertEqual(start.x, end.x, accuracy: 0.001)
        let width = abs(portrait.point(BoardPoint(0.5, 1)).x - portrait.point(BoardPoint(0.5, 0)).x)
        XCTAssertEqual((end.y - start.y) / width, 105 / 68, accuracy: 0.01, "The length runs down the screen")
        XCTAssertEqual(portrait.screenAngle(0), .pi / 2, accuracy: 0.0001, "Facing +x points down the screen")
        let round = portrait.unproject(portrait.point(BoardPoint(0.3, 0.7)))
        XCTAssertEqual(round.x, 0.3, accuracy: 0.0001); XCTAssertEqual(round.y, 0.7, accuracy: 0.0001)
        XCTAssertFalse(BoardProjection(field: .footballHalf, size: CGSize(width: 400, height: 800)).rotated)
    }

    func testRendererHitTestsElementsAndHandles() {
        var document = sampleDocument()
        document.viewAngle = .top
        let size = CGSize(width: 900, height: 600)
        let renderer = BoardRenderer(document: document, selectedID: document.elements[1].id, showsHandles: true)
        let projection = renderer.projection(size: size)
        let player = document.elements[2]
        XCTAssertEqual(renderer.hitTest(projection.point(player.position), size: size), player.id, "Players win over the line beneath them")
        let arrow = document.elements[1]
        XCTAssertEqual(renderer.handle(at: projection.point(arrow.arrowEnd), of: arrow, size: size), .vertex(1))
        XCTAssertNil(renderer.handle(at: CGPoint(x: 5, y: 5), of: arrow, size: size))
        XCTAssertEqual(renderer.hitTest(projection.point(BoardPoint(0.25, 0.2)), size: size), document.elements[0].id, "Inside the zone")
        XCTAssertNil(renderer.hitTest(projection.point(BoardPoint(0.95, 0.5)), size: size))
    }

    func testHitTestingRespectsRotationAndSize() {
        var document = BoardDocument()
        document.fieldType = .futsal
        var text = BoardElement(kind: .text, position: .center, label: "Press from the front")
        let size = CGSize(width: 1000, height: 500)
        document.elements = [text]
        let projection = BoardProjection(field: .futsal, size: size)
        let center = projection.point(.center)
        let wide = BoardRenderer(document: document).pointRadius(text, projection: projection)
        let alongText = CGPoint(x: center.x + wide * 0.85, y: center.y)
        let belowText = CGPoint(x: center.x, y: center.y + wide * 0.85)
        XCTAssertEqual(BoardRenderer(document: document).hitTest(alongText, size: size), text.id)
        XCTAssertNil(BoardRenderer(document: document).hitTest(belowText, size: size))

        text.rotation = 90
        document.elements = [text]
        XCTAssertNil(BoardRenderer(document: document).hitTest(alongText, size: size), "Turned text no longer covers its old extent")
        XCTAssertEqual(BoardRenderer(document: document).hitTest(belowText, size: size), text.id)

        var player = BoardElement(kind: .player, position: .center)
        document.elements = [player]
        let normal = BoardRenderer(document: document).pointRadius(player, projection: projection)
        let edge = CGPoint(x: center.x + normal * 2.5, y: center.y)
        XCTAssertNil(BoardRenderer(document: document).hitTest(edge, size: size))
        player.size = 3
        document.elements = [player]
        XCTAssertEqual(BoardRenderer(document: document).hitTest(edge, size: size), player.id, "Bigger players are easier to hit")

        var polygon = BoardElement(kind: .polygon, position: BoardPoint(0.1, 0.4), points: [BoardPoint(0.3, 0.4), BoardPoint(0.3, 0.6), BoardPoint(0.1, 0.6)])
        polygon = polygon.transformed(rotation: 0, scale: 2, field: .futsal)
        document.elements = [polygon]
        XCTAssertEqual(BoardRenderer(document: document).hitTest(projection.point(BoardPoint(0.02, 0.32)), size: size), polygon.id, "Scaled polygons hit where they are drawn")
    }

    func testSelectedElementsExposeRotateAndResizeHandles() throws {
        var document = BoardDocument()
        let player = BoardElement(kind: .player, position: .center)
        document.elements = [player]
        let size = CGSize(width: 800, height: 500)
        let renderer = BoardRenderer(document: document, selectedID: player.id, showsHandles: true)
        let handles = renderer.handles(for: player, projection: renderer.projection(size: size))
        let rotate = try XCTUnwrap(handles.first { $0.0 == .rotate }?.1)
        let resize = try XCTUnwrap(handles.first { $0.0 == .resize }?.1)
        XCTAssertEqual(renderer.handle(at: rotate, of: player, size: size), .rotate)
        XCTAssertEqual(renderer.handle(at: CGPoint(x: resize.x + 15, y: resize.y), of: player, size: size), .resize, "44 pt targets")

        let line = BoardElement(kind: .line, position: BoardPoint(0.2, 0.5), points: [BoardPoint(0.8, 0.5)])
        let lineHandles = renderer.handles(for: line, projection: renderer.projection(size: size)).map(\.0)
        XCTAssertEqual(lineHandles, [.bend, .vertex(0), .vertex(1)])
        let polyline = BoardElement(kind: .polyline, position: BoardPoint(0.2, 0.5), points: [BoardPoint(0.5, 0.5), BoardPoint(0.8, 0.2)])
        XCTAssertEqual(renderer.handles(for: polyline, projection: renderer.projection(size: size)).map(\.0), [.insert(0), .insert(1), .vertex(0), .vertex(1), .vertex(2)])
    }

    func testAttachedLinesAreTrimmedToTheElementEdge() {
        let (document, _, receiver, lineID) = connectedDocument()
        let size = CGSize(width: 1000, height: 650)
        let renderer = BoardRenderer(document: document)
        let projection = renderer.projection(size: size)
        let elements = document.elements(at: nil)
        let line = elements.first { $0.id == lineID }!
        let samples = renderer.lineSamples(line, all: elements, projection: projection)
        let receiverCenter = projection.point(document.elements.first { $0.id == receiver }!.position)
        let gap = hypot(samples.last!.x - receiverCenter.x, samples.last!.y - receiverCenter.y)
        XCTAssertGreaterThan(gap, renderer.pointRadius(document.elements[1], projection: projection), "The arrowhead ends outside the player")
    }

    // MARK: Gestures

    func testTouchTrackerSeparatesDragsFromPinches() {
        var tracker = BoardTouchTracker()
        XCTAssertEqual(tracker.update([CGPoint(x: 10, y: 10)]), [.began(CGPoint(x: 10, y: 10))])
        XCTAssertEqual(tracker.update([CGPoint(x: 20, y: 10)]), [.moved(CGPoint(x: 20, y: 10))])
        XCTAssertEqual(tracker.update([CGPoint(x: 20, y: 10), CGPoint(x: 120, y: 10)]), [.pinchBegan(centroid: CGPoint(x: 70, y: 10))])
        let events = tracker.update([CGPoint(x: 70, y: -40), CGPoint(x: 70, y: 160)])
        guard case .pinchChanged(let centroid, let scale, let rotation) = events.first else { return XCTFail("Expected a pinch update") }
        XCTAssertEqual(centroid, CGPoint(x: 70, y: 60))
        XCTAssertEqual(scale, 2, accuracy: 0.0001)
        XCTAssertEqual(rotation, .pi / 2, accuracy: 0.0001, "Clockwise on screen is positive")
        XCTAssertEqual(tracker.update([CGPoint(x: 70, y: -40)]), [.pinchEnded])
        XCTAssertEqual(tracker.update([CGPoint(x: 80, y: -40)]), [], "The remaining finger is ignored")
        XCTAssertEqual(tracker.update([]), [])
        XCTAssertEqual(tracker.update([CGPoint(x: 1, y: 1)]), [.began(CGPoint(x: 1, y: 1))])
        XCTAssertEqual(tracker.update([]), [.ended(CGPoint(x: 1, y: 1))])
    }

    func testFocalZoomKeepsTheBoardPointUnderTheFingers() {
        let size = CGSize(width: 400, height: 600)
        var base = BoardViewport()
        let fingers = CGPoint(x: 300, y: 150)
        let anchor = fingers.applying(base.transform(in: size).inverted())
        let zoomed = BoardViewport.zoomed(from: base, anchor: anchor, to: fingers, magnification: 2, in: size)
        XCTAssertEqual(zoomed.scale, 2)
        let mapped = anchor.applying(zoomed.transform(in: size))
        XCTAssertEqual(mapped.x, fingers.x, accuracy: 0.001)
        XCTAssertEqual(mapped.y, fingers.y, accuracy: 0.001)
        // Moving both fingers pans.
        base = zoomed
        let moved = CGPoint(x: 250, y: 200)
        let panned = BoardViewport.zoomed(from: base, anchor: anchor, to: moved, magnification: 1, in: size)
        XCTAssertEqual(anchor.applying(panned.transform(in: size)).x, moved.x, accuracy: 0.001)
        XCTAssertEqual(BoardViewport.zoomed(from: base, anchor: anchor, to: moved, magnification: 0.2, in: size), BoardViewport(), "Zooming out fully resets")
    }

    // MARK: History

    func testHistoryUndoRedoIsBounded() {
        var history = BoardHistory()
        history.limit = 3
        var document = BoardDocument()
        XCTAssertFalse(history.canUndo)
        for index in 1...5 {
            history.record(document)
            document.elements.append(BoardElement(kind: .cone, position: BoardPoint(Double(index) / 10, 0.5)))
        }
        XCTAssertEqual(history.past.count, 3)
        let undone = history.undo(current: document)
        XCTAssertEqual(undone?.elements.count, 4)
        XCTAssertTrue(history.canRedo)
        let redone = history.redo(current: undone!)
        XCTAssertEqual(redone?.elements.count, 5)
        XCTAssertFalse(history.canRedo)
        _ = history.undo(current: redone!)
        history.record(redone!)
        XCTAssertFalse(history.canRedo, "A new change clears the redo stack")
    }

    /// The editor records the document before each change and restores it wholesale, so undo and redo
    /// have to carry keyframe structure, not just element positions.
    func testUndoAndRedoAcrossKeyframeInsertRemoveAndMove() throws {
        var history = BoardHistory()
        var document = BoardDocument()
        let player = BoardElement(kind: .player, position: BoardPoint(0.2, 0.2))
        document.elements = [player]
        document.insertKeyframe(after: nil)

        func change(_ edit: (inout BoardDocument) -> Void) {
            var next = document
            edit(&next)
            history.record(document)
            document = next
        }
        func undo() throws { document = try XCTUnwrap(history.undo(current: document)) }
        func redo() throws { document = try XCTUnwrap(history.redo(current: document)) }

        // Insert two more stages, moving the player in each so they are distinguishable.
        change { $0.insertKeyframe(after: 0) }
        change { $0.update(player.id) { $0.position = BoardPoint(0.5, 0.5) }; $0.recordPoses(in: 1, only: player.id) }
        change { $0.insertKeyframe(after: 1) }
        change { $0.update(player.id) { $0.position = BoardPoint(0.9, 0.9) }; $0.recordPoses(in: 2, only: player.id) }
        XCTAssertEqual(document.keyframes.count, 3)
        let threeStages = document

        change { $0.moveKeyframe(from: 2, to: 0) }
        XCTAssertEqual(document.pose(of: player.id, atFrame: 0)?.position, BoardPoint(0.9, 0.9), "The moved stage leads")
        try undo()
        XCTAssertEqual(document, threeStages, "Undo restores the stage order and every pose")
        try redo()
        XCTAssertEqual(document.pose(of: player.id, atFrame: 0)?.position, BoardPoint(0.9, 0.9))
        try undo()

        change { $0.removeKeyframe(at: 1) }
        XCTAssertEqual(document.keyframes.count, 2)
        try undo()
        XCTAssertEqual(document.keyframes.count, 3)
        XCTAssertEqual(document, threeStages, "Undoing a stage deletion brings back its poses")
        XCTAssertEqual(document.pose(of: player.id, atFrame: 1)?.position, BoardPoint(0.5, 0.5))
        try redo()
        XCTAssertEqual(document.keyframes.count, 2)

        // Back to the start: undoing every step returns the one-stage board.
        while history.canUndo { try undo() }
        XCTAssertEqual(document.keyframes.count, 1)
        XCTAssertEqual(document.elements.first?.position, BoardPoint(0.2, 0.2))
        XCTAssertFalse(history.canUndo)
    }

    func testPosesAndHeadingsSurviveDegenerateGeometry() throws {
        var document = BoardDocument()
        let player = BoardElement(kind: .player, position: .center)
        document.elements = [player]
        document.insertKeyframe(after: nil)
        XCTAssertNil(document.pose(of: player.id, atFrame: -1), "A frame before the first has no pose")
        XCTAssertNil(document.pose(of: player.id, atFrame: -4), "And neither does an out-of-range one")

        // A polyline whose last segment is zero length: the end still faces the way it was travelling.
        let line = BoardElement(kind: .polyline, position: BoardPoint(0.2, 0.5), points: [BoardPoint(0.8, 0.5), BoardPoint(0.8, 0.5)])
        let geometry = try XCTUnwrap(BoardDocument.pathGeometry(of: line, field: .footballFull))
        let end = try XCTUnwrap(BoardDocument.geometryPoint(geometry.points, closed: false, at: 1, field: .footballFull))
        XCTAssertEqual(end.point.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(end.tangentDegrees, 0, accuracy: 1e-9, "Along +x, the direction of the last real segment")

        let upwards = BoardElement(kind: .polyline, position: BoardPoint(0.5, 0.9), points: [BoardPoint(0.5, 0.2), BoardPoint(0.5, 0.2)])
        let upGeometry = try XCTUnwrap(BoardDocument.pathGeometry(of: upwards, field: .footballFull))
        let upEnd = try XCTUnwrap(BoardDocument.geometryPoint(upGeometry.points, closed: false, at: 1, field: .footballFull))
        XCTAssertEqual(upEnd.tangentDegrees, -90, accuracy: 1e-9, "Not 0°, which would point across the travel")
    }

    /// The drawn stroke, the length pill and follow-path geometry all measure the same curve.
    func testCurvedLineLengthMatchesTheDrawnStrokeAndItsFollowPath() throws {
        var line = BoardElement(kind: .line, position: BoardPoint(0.2, 0.5), points: [BoardPoint(0.8, 0.5), BoardPoint(0.5, 0.1)])
        line.isCurved = true
        line.showsLength = true
        var document = BoardDocument()
        document.fieldType = .footballFull
        document.elements = [line]
        let field = document.fieldType
        let w = Double(field.meters.width), h = Double(field.meters.height)

        let labelled = BoardRenderer(document: document).lengthMeters(of: line)
        let geometry = try XCTUnwrap(BoardDocument.pathGeometry(of: line, field: field))
        let travelled = zip(geometry.points, geometry.points.dropFirst()).reduce(0.0) { $0 + hypot(($1.1.x - $1.0.x) * w, ($1.1.y - $1.0.y) * h) }
        XCTAssertEqual(labelled, travelled, accuracy: 1e-9, "The pill measures the path a follower travels")

        // And the drawn polyline passes through those same points.
        let size = CGSize(width: 900, height: 600)
        let renderer = BoardRenderer(document: document)
        let projection = renderer.projection(size: size)
        let drawn = renderer.lineSamples(line, all: document.elements, projection: projection)
        XCTAssertEqual((drawn.count - 1) % BoardElement.curveSampleCount, 0, "A whole number of canonical steps")
        let stride = (drawn.count - 1) / BoardElement.curveSampleCount
        for (index, point) in geometry.points.enumerated() {
            let expected = projection.point(point), actual = drawn[index * stride]
            XCTAssertEqual(hypot(expected.x - actual.x, expected.y - actual.y), 0, accuracy: 1e-6)
        }
    }

    // MARK: Surface

    func testSurfaceImageCoversFieldPlusApron() throws {
        for field in BoardFieldType.allCases {
            let image = try XCTUnwrap(BoardRenderer.surfaceImage(field: field, style: .grass, pixelsPerMeter: 10, apronMeters: 3))
            XCTAssertEqual(image.width, Int(((field.meters.width + 6) * 10).rounded()))
            XCTAssertEqual(image.height, Int(((field.meters.height + 6) * 10).rounded()))
        }
        let noApron = try XCTUnwrap(BoardRenderer.surfaceImage(field: .futsal, style: .court, pixelsPerMeter: 4))
        XCTAssertEqual(noApron.width, 160)
        XCTAssertEqual(noApron.height, 80)
    }

    /// The laid-out canvas is blitted 1:1 over the view, so a cache key that rounded the canvas size to
    /// whole points would hand a 392.66 pt canvas the bitmap baked for 392 pt and shift every marking.
    func testCanvasCacheDoesNotServeAFractionallyDifferentCanvas() throws {
        let cache = BoardSurfaceCache.shared
        let reserved = CGSize(width: 0, height: 52)
        let small = try XCTUnwrap(cache.canvas(field: .footballFull, style: .grass, size: CGSize(width: 392, height: 620), inset: 10, reserved: reserved, scale: 2))
        let large = try XCTUnwrap(cache.canvas(field: .footballFull, style: .grass, size: CGSize(width: 392.66, height: 620), inset: 10, reserved: reserved, scale: 2))
        XCTAssertNotEqual(small.width, large.width, "Each canvas size gets its own bitmap")
        XCTAssertEqual(large.width, Int((392.66 * 2).rounded()))
        let again = try XCTUnwrap(cache.canvas(field: .footballFull, style: .grass, size: CGSize(width: 392.66, height: 620), inset: 10, reserved: reserved, scale: 2))
        XCTAssertTrue(again === large, "The same canvas is still served from the cache")
    }

    // MARK: Export

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "board-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testExportsReadablePNGAndJPEG() async throws {
        let directory = temporaryDirectory()
        var request = BoardExportRequest(document: sampleDocument(), name: "Corner / routine", format: .png, framing: .square, imageScale: 2)
        let png = try await TacticalBoardExporter.export(request, to: directory)
        XCTAssertEqual(png.pathExtension, "png")
        XCTAssertEqual(png.deletingPathExtension().lastPathComponent, "Corner  routine")
        let image = try XCTUnwrap(UIImage(contentsOfFile: png.path(percentEncoded: false)))
        XCTAssertEqual(image.size.width * image.scale, 1080, accuracy: 1)
        XCTAssertEqual(image.size.height * image.scale, 1080, accuracy: 1)
        request.format = .jpeg; request.framing = .vertical; request.imageScale = 3
        let jpeg = try await TacticalBoardExporter.export(request, to: directory)
        let vertical = try XCTUnwrap(UIImage(contentsOfFile: jpeg.path(percentEncoded: false)))
        XCTAssertEqual(vertical.size.width * vertical.scale, 1620, accuracy: 1)
        XCTAssertEqual(vertical.size.height * vertical.scale, 2880, accuracy: 1)

        // The same exports of a 3D board.
        request.document.viewAngle = .tilted
        for (format, framing, scale, width) in [(BoardExportFormat.png, BoardExportFraming.square, CGFloat(2), 1080.0), (.jpeg, .vertical, 3, 1620)] {
            request.format = format; request.framing = framing; request.imageScale = scale
            let url = try await TacticalBoardExporter.export(request, to: directory)
            let image = try XCTUnwrap(UIImage(contentsOfFile: url.path(percentEncoded: false)), "3D \(format)")
            XCTAssertEqual(image.size.width * image.scale, width, accuracy: 1, "3D \(format)")
        }
    }

    func testThumbnailIsWritten() throws {
        let url = temporaryDirectory().appending(path: "thumb.png")
        try TacticalBoardExporter.writeThumbnail(document: sampleDocument(), to: url)
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path(percentEncoded: false)))
        XCTAssertEqual(image.size.width * image.scale, 960, accuracy: 1)
        var threeD = sampleDocument()
        threeD.viewAngle = .broadcast
        try TacticalBoardExporter.writeThumbnail(document: threeD, to: url)
        let thumbnail = try XCTUnwrap(UIImage(contentsOfFile: url.path(percentEncoded: false)))
        XCTAssertEqual(thumbnail.size.width * thumbnail.scale, 960, accuracy: 1, "3D thumbnail")
    }

    func testExportsAnimatedMP4WithExpectedDurationAndSize() async throws {
        var document = sampleDocument()
        document.viewAngle = .top
        document.insertKeyframe(after: nil)
        document.elements[2].position = BoardPoint(0.7, 0.7)
        document.insertKeyframe(after: 0)
        document.keyframes[0].duration = 0.5
        document.keyframes[1].duration = 0.5
        let box = ProgressBox()
        let request = BoardExportRequest(document: document, name: "Animated", format: .mp4, framing: .landscape)
        let url = try await TacticalBoardExporter.export(request, to: temporaryDirectory()) { value in box.append(value) }
        let progress = box.values
        XCTAssertEqual(progress.last ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(progress.count, 30)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size.width, 1920); XCTAssertEqual(size.height, 1080)
    }

    func testStaticBoardExportsAsShortSquareClip() async throws {
        for angle in [BoardViewAngle.top, .tilted] {
            var document = sampleDocument()
            document.viewAngle = angle
            let request = BoardExportRequest(document: document, name: "Still", format: angle == .top ? .mp4 : .hevc, framing: .square)
            let url = try await TacticalBoardExporter.export(request, to: temporaryDirectory())
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, TacticalBoardExporter.stillClipDuration, accuracy: 0.05, "\(angle)")
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 1080, height: 1080), "\(angle)")
        }
    }

    func testExportsGIF() async throws {
        for angle in [BoardViewAngle.top, .broadcast] {
            var document = sampleDocument()
            document.viewAngle = angle
            document.insertKeyframe(after: nil)
            document.keyframes[0].duration = 0.5
            let url = try await TacticalBoardExporter.export(BoardExportRequest(document: document, name: "Loop", format: .gif, framing: .landscape), to: temporaryDirectory())
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 6, "\(angle)")
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
        }
    }

    // MARK: Follow paths

    private func metres(_ a: BoardPoint, _ b: BoardPoint, _ field: BoardFieldType = .footballFull) -> Double {
        hypot((a.x - b.x) * field.meters.width, (a.y - b.y) * field.meters.height)
    }

    func testPathLocationSamplesByArcLengthOnOpenAndClosedPaths() throws {
        var document = BoardDocument()
        document.fieldType = .futsal // 40 × 20 m
        let straight = BoardElement(kind: .line, position: BoardPoint(0.1, 0.5), points: [BoardPoint(0.5, 0.5)])
        let polyline = BoardElement(kind: .polyline, position: BoardPoint(0.1, 0.1), points: [BoardPoint(0.3, 0.1), BoardPoint(0.3, 0.9)])
        var curve = BoardElement(kind: .line, position: BoardPoint(0.1, 0.5), points: [BoardPoint(0.5, 0.5), BoardPoint(0.3, 0.1)])
        curve.isCurved = true
        let rect = BoardElement(kind: .zone, position: BoardPoint(0.25, 0.25), points: [BoardPoint(0.75, 0.75)]) // 20 × 10 m, 60 m round
        var ellipse = BoardElement(kind: .zone, position: BoardPoint(0.25, 0.25), points: [BoardPoint(0.75, 0.75)])
        ellipse.zoneShape = .ellipse
        let polygon = BoardElement(kind: .polygon, position: BoardPoint(0.1, 0.1), points: [BoardPoint(0.6, 0.1), BoardPoint(0.1, 0.6)])
        document.elements = [straight, polyline, curve, rect, ellipse, polygon]
        let layout = document.elements, field = document.fieldType

        let mid = try XCTUnwrap(BoardDocument.pathLocation(pathID: straight.id, progress: 0.5, in: layout, field: field))
        XCTAssertEqual(mid.point.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(mid.tangentDegrees, 0, accuracy: 1e-9)
        XCTAssertEqual(BoardDocument.pathLocation(pathID: straight.id, progress: 1.4, in: layout, field: field)?.point.x ?? 0, 0.5, accuracy: 1e-9, "Open paths clamp")

        let total = 0.2 * 40 + 0.8 * 20
        let corner = try XCTUnwrap(BoardDocument.pathLocation(pathID: polyline.id, progress: (0.2 * 40) / total, in: layout, field: field))
        assertClose(corner.point, BoardPoint(0.3, 0.1))
        XCTAssertEqual(BoardDocument.pathLocation(pathID: polyline.id, progress: 0.9, in: layout, field: field)?.tangentDegrees ?? 0, 90, accuracy: 1e-9)

        let samples = (0...10).compactMap { BoardDocument.pathLocation(pathID: curve.id, progress: Double($0) / 10, in: layout, field: field)?.point }
        let steps = zip(samples, samples.dropFirst()).map { metres($0.0, $0.1, field) }
        XCTAssertLessThan((steps.max() ?? 0) - (steps.min() ?? 0), 0.05 * (steps.max() ?? 1), "Uniform speed along a curve")

        let quarter = try XCTUnwrap(BoardDocument.pathLocation(pathID: rect.id, progress: 20.0 / 60, in: layout, field: field))
        assertClose(quarter.point, BoardPoint(0.75, 0.25))
        let lap = try XCTUnwrap(BoardDocument.pathLocation(pathID: rect.id, progress: 1 + 20.0 / 60, in: layout, field: field))
        assertClose(lap.point, quarter.point)
        let backwards = try XCTUnwrap(BoardDocument.pathLocation(pathID: rect.id, progress: -5.0 / 60, in: layout, field: field))
        assertClose(backwards.point, BoardPoint(0.25, 0.5))
        XCTAssertEqual(BoardDocument.pathLocation(pathID: ellipse.id, progress: 0, in: layout, field: field)?.point.x ?? 0, 0.75, accuracy: 1e-9)
        assertClose(BoardDocument.pathLocation(pathID: polygon.id, progress: 1, in: layout, field: field)?.point, polygon.position)
    }

    func testDraggingProjectsOntoThePath() throws {
        var document = BoardDocument()
        let polyline = BoardElement(kind: .polyline, position: BoardPoint(0.1, 0.5), points: [BoardPoint(0.5, 0.5), BoardPoint(0.5, 0.9)])
        document.elements = [polyline]
        let field = document.fieldType
        let total = 0.4 * 105 + 0.4 * 68
        let onFirst = try XCTUnwrap(BoardDocument.projectOntoPath(pathID: polyline.id, point: BoardPoint(0.3, 0.52), in: document.elements, field: field))
        XCTAssertEqual(onFirst.progress, (0.2 * 105) / total, accuracy: 1e-9)
        XCTAssertEqual(onFirst.distanceMeters, 0.02 * 68, accuracy: 1e-9)
        let onSecond = try XCTUnwrap(BoardDocument.projectOntoPath(pathID: polyline.id, point: BoardPoint(0.6, 0.7), in: document.elements, field: field))
        XCTAssertEqual(onSecond.progress, (0.4 * 105 + 0.2 * 68) / total, accuracy: 1e-9)
        XCTAssertEqual(onSecond.distanceMeters, 0.1 * 105, accuracy: 1e-9)
        XCTAssertEqual(BoardDocument.projectOntoPath(pathID: polyline.id, point: BoardPoint(0, 0.5), in: document.elements, field: field)?.progress, 0, "Beyond the start clamps to it")
        XCTAssertNil(BoardDocument.projectOntoPath(pathID: UUID(), point: .center, in: document.elements, field: field))
    }

    /// A ball, a straight line along x and `count` stages.
    private func pathDocument(stages count: Int) -> (BoardDocument, ball: UUID, line: UUID) {
        var document = BoardDocument()
        let line = BoardElement(kind: .line, position: BoardPoint(0.1, 0.5), points: [BoardPoint(0.9, 0.5)])
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.1, 0.52))
        document.elements = [line, ball]
        for _ in 0..<count { document.insertKeyframe(after: nil) }
        return (document, ball.id, line.id)
    }

    func testFollowingAPathAcrossFourStagesWithCustomProgress() throws {
        var (document, ball, line) = pathDocument(stages: 4)
        XCTAssertEqual(document.attachToPath(ball, pathID: line, fromFrame: 0), 4)
        XCTAssertEqual((0..<4).map { document.pathPose(of: ball, atFrame: $0)?.pathProgress ?? -1 }, [0, 1.0 / 3, 2.0 / 3, 1], "Spread evenly by default")
        for (frame, progress) in [0.0, 0.3, 0.6, 1].enumerated() { document.setPathProgress(progress, for: ball, inFrame: frame) }
        let x: (Double) -> Double = { 0.1 + 0.8 * $0 }
        // Stage k at time k (1 s transitions). Halfway through each transition the ease is 0.5.
        for (k, (from, to)) in [(0.0, 0.3), (0.3, 0.6), (0.6, 1.0)].enumerated() {
            let element = try XCTUnwrap(document.elements(at: Double(k) + 0.5).first { $0.id == ball })
            XCTAssertEqual(element.position.x, x((from + to) / 2), accuracy: 1e-9, "Mid-transition \(k + 1) is on the path")
            XCTAssertEqual(element.position.y, 0.5, accuracy: 1e-9)
        }
        XCTAssertEqual(document.keyframes[2].poses[ball]?.position.x ?? 0, x(0.6), accuracy: 1e-9, "Poses are snapped for editors reading them")
        var shown = document
        shown.showFrame(1)
        XCTAssertEqual(shown.elements.first { $0.id == ball }?.position.x ?? 0, x(0.3), accuracy: 1e-9)

        // Spread evenly keeps the ends.
        document.setPathProgress(0.9, for: ball, inFrame: 1)
        document.spreadPathEvenly(ball, pathID: line)
        XCTAssertEqual((0..<4).map { document.pathPose(of: ball, atFrame: $0)?.pathProgress ?? -1 }, [0, 1.0 / 3, 2.0 / 3, 1])
        let decoded = try JSONDecoder().decode(BoardDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
    }

    func testLapsAndBackwardsProgressAndFacing() throws {
        var document = BoardDocument()
        document.fieldType = .futsal
        let rect = BoardElement(kind: .zone, position: BoardPoint(0.25, 0.25), points: [BoardPoint(0.75, 0.75)])
        let player = BoardElement(kind: .player, position: BoardPoint(0.25, 0.25))
        document.elements = [rect, player]
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: nil)
        XCTAssertEqual(document.attachToPath(player.id, pathID: rect.id, fromFrame: 0), 2)
        XCTAssertEqual(document.pathPose(of: player.id, atFrame: 1)?.pathProgress ?? 0, 1, accuracy: 1e-9, "Closed shapes default to one lap")
        document.setPathProgress(2.5, for: player.id, inFrame: 1)
        document.setFacesPath(true, for: player.id, pathID: rect.id)
        // Halfway through 0 → 2.5 laps is 1.25 laps: 15 m along = the top-right corner... 75 m round → 15 m past a lap start.
        let mid = try XCTUnwrap(document.elements(at: 0.5).first { $0.id == player.id })
        let expected = try XCTUnwrap(BoardDocument.pathLocation(pathID: rect.id, progress: 1.25, in: document.elements, field: .futsal))
        assertClose(mid.position, expected.point)
        XCTAssertEqual(mid.rotation, expected.tangentDegrees, accuracy: 1e-9, "Faces the direction of travel")

        document.setPathProgress(-0.25, for: player.id, inFrame: 1)
        let back = try XCTUnwrap(document.elements(at: 0.5).first { $0.id == player.id })
        let backExpected = try XCTUnwrap(BoardDocument.pathLocation(pathID: rect.id, progress: -0.125, in: document.elements, field: .futsal))
        assertClose(back.position, backExpected.point)
        XCTAssertEqual(back.rotation, normalizedDegrees(backExpected.tangentDegrees + 180), accuracy: 1e-9, "Decreasing progress travels (and faces) backwards")
    }

    func testDetachingInOneStageFallsBackToAStraightMove() throws {
        var (document, ball, line) = pathDocument(stages: 3)
        document.attachToPath(ball, pathID: line, fromFrame: 0)
        document.detachFromPath(ball, inFrame: 2)
        XCTAssertNil(document.pathPose(of: ball, atFrame: 2))
        let end = try XCTUnwrap(document.keyframes[2].poses[ball]?.position)
        XCTAssertEqual(end.x, 0.9, accuracy: 1e-9, "Detaching keeps it where it was on the path")
        document.update(ball) { _ in }
        document.keyframes[2].poses[ball]?.position = BoardPoint(0.5, 0.8)
        let mid = try XCTUnwrap(document.elements(at: 1.5).first { $0.id == ball })
        XCTAssertEqual(mid.position.x, (0.5 + 0.5) / 2, accuracy: 1e-9, "Straight from the path point (0.5, 0.5) to the free point")
        XCTAssertEqual(mid.position.y, (0.5 + 0.8) / 2, accuracy: 1e-9)

        // A deleted path element: no crash, straight lerp of the snapped poses.
        document.removeElement(line)
        XCTAssertNotNil(document.elements(at: 0.5).first { $0.id == ball })
        // Attaching stops at a stage already on another path.
        var (other, ball2, line2) = pathDocument(stages: 3)
        let second = BoardElement(kind: .line, position: BoardPoint(0.1, 0.2), points: [BoardPoint(0.9, 0.2)])
        other.elements.append(second)
        for frame in 0..<3 { other.recordPoses(in: frame, only: second.id) }
        other.attachToPath(ball2, pathID: second.id, fromFrame: 2)
        XCTAssertEqual(other.attachToPath(ball2, pathID: line2, fromFrame: 0), 2, "Stops before a stage on another path")
    }

    func testPathFollowsAnAttachedMovingPlayer() throws {
        var (document, ball, line) = pathDocument(stages: 2)
        let receiver = BoardElement(kind: .player, position: BoardPoint(0.9, 0.5))
        document.elements.append(receiver)
        document.update(line) { $0.endAttachment = receiver.id }
        document.recordPoses(in: 0); document.recordPoses(in: 1)
        document.showFrame(1)
        document.update(receiver.id) { $0.position = BoardPoint(0.9, 0.9) }
        document.recordPoses(in: 1, only: receiver.id)
        document.showFrame(0)
        document.attachToPath(ball, pathID: line, fromFrame: 0)
        let atEnd = try XCTUnwrap(document.elements(at: 0.999).first { $0.id == ball })
        let receiverNow = try XCTUnwrap(document.elements(at: 0.999).first { $0.id == receiver.id })
        XCTAssertLessThan(metres(atEnd.position, receiverNow.position), 1, "The path end follows the moving receiver")
    }

    func testLegacyTransitionPathsMigrateToPoseProgress() throws {
        var legacy = BoardDocument()
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.2, 0.8))
        var line = BoardElement(kind: .line, position: BoardPoint(0.2, 0.8), points: [BoardPoint(0.8, 0.2), BoardPoint(0.2, 0.2)])
        line.isCurved = true
        legacy.elements = [line, ball]
        legacy.insertKeyframe(after: nil)
        legacy.insertKeyframe(after: 0)
        legacy.keyframes[0].paths = [ball.id: BoardFollowPath(pathID: line.id, reversed: true, startFraction: 0.1, endFraction: 0.9, facesDirection: true)]
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(BoardDocument.self, from: data)
        XCTAssertNotNil(decoded.keyframes[0].paths, "Old documents still decode their paths")
        for t in [0.0, 0.25, 0.5, 0.75, 0.999] {
            let eased = decoded.frameProgress(at: t).fraction
            let old = try XCTUnwrap(BoardDocument.legacyPathPoint(decoded.keyframes[0].paths![ball.id]!, at: eased, in: decoded.elements, field: decoded.fieldType))
            let now = try XCTUnwrap(decoded.elements(at: t).first { $0.id == ball.id })
            assertClose(now.position, old.point)
            XCTAssertEqual(now.rotation, old.tangentDegrees + 180 > 180 ? old.tangentDegrees - 180 : old.tangentDegrees + 180, accuracy: 1e-6, "Reversed travel faces backwards along the line")
        }
        let migrated = decoded.migratingLegacyPaths()
        XCTAssertNil(migrated.keyframes[0].paths)
        XCTAssertEqual(migrated.keyframes[0].poses[ball.id]?.pathProgress ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(migrated.keyframes[1].poses[ball.id]?.pathProgress ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(try TacticalBoard(name: "Old", document: decoded).load().keyframes[0].paths, nil, "Boards migrate when opened")
    }

    func testMovingAStageKeepsEveryStageLayout() {
        var (document, ball, _) = pathDocument(stages: 3)
        document.showFrame(1)
        document.update(ball) { $0.position = BoardPoint(0.5, 0.5) }
        document.recordPoses(in: 1, only: ball)
        document.keyframes[2].poses[ball] = nil // inherits stage 2
        let before = (0..<3).map { document.pose(of: ball, atFrame: $0)?.position }
        document.moveKeyframe(from: 2, to: 0)
        XCTAssertEqual(document.pose(of: ball, atFrame: 0)?.position, before[2])
        XCTAssertEqual(document.pose(of: ball, atFrame: 1)?.position, before[0])
        XCTAssertEqual(document.pose(of: ball, atFrame: 2)?.position, before[1])
    }

    func testOnionSkinResolvesNeighbouringKeyframes() {
        var (document, ball, line) = pathDocument(stages: 3)
        document.showFrame(2)
        document.update(ball) { $0.position = BoardPoint(0.6, 0.6) }
        document.recordPoses(in: 2, only: ball)
        document.showFrame(1)
        let skin = document.onionSkin(aroundFrame: 1)
        XCTAssertEqual(skin.previous.first { $0.id == ball }?.position, BoardPoint(0.1, 0.52))
        XCTAssertEqual(skin.next.first { $0.id == ball }?.position, BoardPoint(0.6, 0.6))
        XCTAssertTrue(document.onionSkin(aroundFrame: 0).previous.isEmpty)
        XCTAssertTrue(document.onionSkin(aroundFrame: 2).next.isEmpty)
        XCTAssertFalse(BoardRenderer.poseDiffers(skin.next.first { $0.id == line }!, document.elements.first { $0.id == line }!), "Unmoved elements get no ghost")
    }

    /// Follow-path preview and onion skin for design review. Run with `TEST_RUNNER_CAMELOT_BOARD_GALLERY=<folder>`.
    func testRenderAnimationGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["CAMELOT_BOARD_GALLERY"] else { throw XCTSkip("Set TEST_RUNNER_CAMELOT_BOARD_GALLERY to write the gallery") }
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = BoardDocument()
        let runner = BoardElement(kind: .player, position: BoardPoint(0.55, 0.15), colorHex: document.homeColorHex, number: 11)
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.2, 0.75))
        var pass = BoardElement(kind: .line, position: BoardPoint(0.2, 0.75), points: [BoardPoint(0.8, 0.5), BoardPoint(0.45, 0.95)])
        pass.isCurved = true; pass.lineStyle = .pass
        var zone = BoardElement(kind: .zone, position: BoardPoint(0.55, 0.15), points: [BoardPoint(0.85, 0.45)], colorHex: BoardPalette.keeper)
        zone.zoneShape = .ellipse; zone.opacity = 0.15
        document.elements = [zone, pass, runner, ball]
        for _ in 0..<4 { document.insertKeyframe(after: nil) }
        document.attachToPath(ball.id, pathID: pass.id, fromFrame: 0)
        document.attachToPath(runner.id, pathID: zone.id, fromFrame: 1)
        document.showFrame(2)
        document.showsOnionSkin = true
        for style in [BoardFieldStyle.grass, .chalk] {
            document.style = style
            for (name, size) in [("portrait", CGSize(width: 402, height: 560)), ("landscape", CGSize(width: 780, height: 330))] {
                for (mode, selected) in [("onion", nil as UUID?), ("follow", ball.id)] {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 3
                    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                        UIColor(red: 0.045, green: 0.047, blue: 0.055, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
                        BoardRenderer(document: document, selectedID: selected, showsHandles: selected != nil, inset: 10,
                                      animationFrame: 2, onionFrame: mode == "onion" ? 2 : nil).draw(in: context.cgContext, size: size)
                    }
                    try image.pngData()?.write(to: folder.appending(path: "stages-\(mode)-\(style.rawValue)-\(name).png"))
                }
            }
        }
    }

    // MARK: Camera keys

    private func cameraDocument(stages: Int) -> BoardDocument {
        var document = BoardDocument()
        document.viewAngle = .tilted
        document.elements = [BoardElement(kind: .ball, position: .center)]
        for _ in 0..<stages { document.insertKeyframe(after: nil) }
        return document
    }

    func testCameraInterpolatesBetweenKeyedStagesAndHoldsOutside() throws {
        var document = cameraDocument(stages: 4) // stages start at 0, 1, 2, 3 s
        XCTAssertFalse(document.animatesCamera)
        XCTAssertEqual(document.camera(at: 1.5), document.cameraOrDefault, "No keys: the board's camera")
        XCTAssertEqual(document.camera(atStage: 2), document.cameraOrDefault)

        let first = BoardCamera(azimuthDegrees: 350, elevationDegrees: 30, distanceScale: 1, target: BoardPoint(0.2, 0.5))
        let third = BoardCamera(azimuthDegrees: 10, elevationDegrees: 60, distanceScale: 2, target: BoardPoint(0.6, 0.5))
        document.keyframes[1].camera = first // stage 2 at 1 s
        document.keyframes[3].camera = third // stage 4 at 3 s
        XCTAssertTrue(document.animatesCamera)
        XCTAssertEqual(document.camera(at: 0), first, "Holds the first key before it")
        XCTAssertEqual(document.camera(at: 3.7), third, "Holds the last key after it")
        let mid = document.camera(at: 2) // halfway between 1 s and 3 s, smoothstep 0.5
        XCTAssertEqual(mid.azimuthDegrees, 0, accuracy: 1e-9, "350° → 10° goes through 0°, not 180°")
        XCTAssertEqual(mid.elevationDegrees, 45, accuracy: 1e-9)
        XCTAssertEqual(mid.distanceScale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(mid.target.x, 0.4, accuracy: 1e-9)
        let quarter = document.camera(at: 1.5)
        XCTAssertLessThan(quarter.elevationDegrees, 30 + 30 * 0.25 + 1e-9, "Eased: slow at the start")
        XCTAssertEqual(document.camera(atStage: 1), first, "A stage's own key")
        XCTAssertEqual(document.camera(atStage: 2), mid, "Between keys: the interpolated camera at its start")
    }

    func testCameraKeysSurviveStageEditsAndLegacyDecode() throws {
        var document = cameraDocument(stages: 3)
        let key = BoardCamera(azimuthDegrees: 90, elevationDegrees: 40, distanceScale: 1.2)
        document.keyframes[0].camera = key
        document.showFrame(0)
        let duplicate = document.insertKeyframe(after: 0)
        XCTAssertEqual(document.keyframes[duplicate].camera, key, "Duplicating a stage copies its camera key")
        document.keyframes[duplicate].camera = nil
        document.moveKeyframe(from: 0, to: 2)
        XCTAssertEqual(document.keyframes[2].camera, key, "Moving a stage carries its key")
        document.removeKeyframe(at: 0)
        XCTAssertEqual(document.keyframes[1].camera, key, "Deleting another stage keeps the key")
        let decoded = try JSONDecoder().decode(BoardDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertTrue(try decodeFixture().keyframes.allSatisfy { $0.camera == nil }, "Old boards have no camera keys")
    }

    func testPointOfViewCameraKeysDuplicateAndLegacyBoardsDecode() throws {
        var document = cameraDocument(stages: 2)
        let referee = BoardElement(kind: .referee, position: BoardPoint(0.4, 0.4))
        document.elements.append(referee)
        document.recordPoses(in: 0); document.recordPoses(in: 1)
        let pov = document.cameraOrDefault.pointOfView(subject: referee.id, lookAt: .ball)
        document.keyframes[0].camera = pov
        document.showFrame(0)
        let copy = document.insertKeyframe(after: 0)
        XCTAssertEqual(document.keyframes[copy].camera, pov, "Duplicating a stage copies its point-of-view key")
        XCTAssertEqual(document.keyframes[copy].camera?.resolvedMode, .pointOfView)
        XCTAssertEqual(document.keyframes[copy].camera?.subjectID, referee.id)
        let decoded = try JSONDecoder().decode(BoardDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
        // Deleting the subject clears the key's reference to it (see
        // `testDeletingAnElementClearsCamerasThatPointedAtIt`) and still resolves without crashing.
        document.removeElement(referee.id)
        XCTAssertNil(document.camera(atStage: copy).subjectID)
        XCTAssertEqual(document.camera(atStage: copy).resolvedMode, .orbit)
        _ = document.camera(at: 0.5)
        let legacy = try decodeFixture()
        XCTAssertNil(legacy.camera?.mode)
        XCTAssertTrue(legacy.keyframes.allSatisfy { $0.camera == nil })
        XCTAssertEqual(TacticalBoardView.cameraKeySymbol(pov), "eye.fill")
        XCTAssertEqual(TacticalBoardView.cameraKeySymbol(nil), "video.fill")
    }

    /// Every goal type used to hand-roll its own net spacing, so nets did not match across the board.
    /// One rule now drives them all: `BoardNet.cells` squares across the box's longer side, never
    /// finer than the caller's floor.
    func testGoalNetsShareOneMesh() {
        // Mini goal and full goal in screen points, and the baked surface goal in metres.
        let mini = CGRect(x: -30, y: -12, width: 60, height: 24)
        let full = CGRect(x: -80, y: -14, width: 160, height: 28)
        let surface = CGRect(x: 0, y: 0, width: 7.32, height: 2)
        for box in [mini, full, surface] {
            let spacing = BoardNet.spacing(in: box, minimum: 0)
            XCTAssertEqual(box.width / spacing, BoardNet.cells, accuracy: 0.001, "\(box) keeps the shared mesh count")
        }
        // The floor wins on a preview-sized goal, so the net never turns into a solid smudge.
        XCTAssertEqual(BoardNet.spacing(in: CGRect(x: 0, y: 0, width: 9, height: 4), minimum: 2), 2, accuracy: 0.001)
        // And it strokes something: a clipped mesh over a small box leaves marks in the bitmap.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20))
        let image = renderer.image { context in
            BoardNet.mesh(in: CGRect(x: 0, y: 0, width: 40, height: 20), minimum: 1, color: .white, lineWidth: 1, in: context.cgContext)
        }
        XCTAssertEqual(image.size, CGSize(width: 40, height: 20))
    }

    /// VoiceOver cannot drag on the direct-interaction board, so "Next/Previous element" walks
    /// document order and wraps at both ends.
    func testBoardVoiceOverSelectionWalksElementsAndWraps() {
        let elements = [BoardElement(kind: .player, position: BoardPoint(0.2, 0.2)),
                        BoardElement(kind: .ball, position: BoardPoint(0.5, 0.5)),
                        BoardElement(kind: .cone, position: BoardPoint(0.8, 0.8))]
        XCTAssertEqual(TacticalBoardView.neighbourID(after: nil, in: elements, step: 1), elements[0].id)
        XCTAssertEqual(TacticalBoardView.neighbourID(after: nil, in: elements, step: -1), elements[2].id)
        XCTAssertEqual(TacticalBoardView.neighbourID(after: elements[0].id, in: elements, step: 1), elements[1].id)
        XCTAssertEqual(TacticalBoardView.neighbourID(after: elements[2].id, in: elements, step: 1), elements[0].id)
        XCTAssertEqual(TacticalBoardView.neighbourID(after: elements[0].id, in: elements, step: -1), elements[2].id)
        // A stale selection (deleted element) falls back to the first one rather than going nowhere.
        XCTAssertEqual(TacticalBoardView.neighbourID(after: UUID(), in: elements, step: 1), elements[0].id)
        XCTAssertNil(TacticalBoardView.neighbourID(after: nil, in: [], step: 1))
    }

    /// A "Move selected" action nudges by a fixed, small step and stays on the field.
    func testBoardVoiceOverNudgeStaysOnTheField() {
        var document = BoardDocument()
        let player = BoardElement(kind: .player, position: BoardPoint(0.5, 0.01))
        document.elements = [player]
        document.update(player.id) { element in
            element.pose = element.pose.translated(dx: 0, dy: -TacticalBoardView.nudgeStep)
            if element.kind.isPoint { element.position = element.position.clamped() }
        }
        XCTAssertEqual(document.elements[0].position.y, 0, accuracy: 0.0001, "The nudge clamps at the goal line")
        document.update(player.id) { $0.pose = $0.pose.translated(dx: TacticalBoardView.nudgeStep, dy: 0) }
        XCTAssertEqual(document.elements[0].position.x, 0.52, accuracy: 0.0001)
    }

    /// A deleted element must not stay referenced by a point-of-view camera: the reference would be
    /// written into the saved JSON and outlive the element.
    func testDeletingAnElementClearsCamerasThatPointedAtIt() throws {
        var document = BoardDocument()
        let subject = BoardElement(kind: .player, position: BoardPoint(0.3, 0.3))
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.6, 0.6))
        let keeper = BoardElement(kind: .goalkeeper, position: BoardPoint(0.1, 0.5))
        document.elements = [subject, ball, keeper]
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        document.camera = document.cameraOrDefault.pointOfView(subject: subject.id, lookAt: .ball)
        document.keyframes[0].camera = document.cameraOrDefault.pointOfView(subject: subject.id, lookAt: .element(ball.id))
        document.keyframes[1].camera = document.cameraOrDefault.pointOfView(subject: keeper.id, lookAt: .element(subject.id))

        document.removeElement(subject.id)

        let base = try XCTUnwrap(document.camera)
        XCTAssertNil(base.subjectID, "The base camera lets go of the deleted subject")
        XCTAssertNil(base.lookAt)
        XCTAssertEqual(base.resolvedMode, .orbit, "With no subject it falls back to orbit")
        let first = try XCTUnwrap(document.keyframes[0].camera)
        XCTAssertNil(first.subjectID)
        XCTAssertEqual(first.resolvedMode, .orbit)
        let second = try XCTUnwrap(document.keyframes[1].camera)
        XCTAssertEqual(second.subjectID, keeper.id, "A camera on another player keeps its subject")
        XCTAssertEqual(second.resolvedMode, .pointOfView)
        XCTAssertNil(second.lookAt, "But stops looking at the deleted element")

        // And none of it survives a save.
        let reloaded = try JSONDecoder().decode(BoardDocument.self, from: try JSONEncoder().encode(document))
        XCTAssertFalse(reloaded.keyframes.contains { $0.camera?.subjectID == subject.id || $0.camera?.lookAt == .element(subject.id) })
        XCTAssertNotEqual(reloaded.camera?.subjectID, subject.id)
    }

    // MARK: Aerial lines

    func testLineHeightsFormAQuadraticThroughStartPeakAndEnd() throws {
        var line = BoardElement(kind: .line, position: BoardPoint(0.1, 0.5), points: [BoardPoint(0.9, 0.5)])
        XCTAssertFalse(line.isAerial)
        XCTAssertEqual(line.lineHeightMeters(at: 0.5), 0, "A flat line stays on the ground")

        line.arcHeightMeters = 8
        XCTAssertTrue(line.isAerial)
        XCTAssertEqual(line.lineHeightMeters(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(line.lineHeightMeters(at: 0.5), 8, accuracy: 1e-9, "The peak is the arc height")
        XCTAssertEqual(line.lineHeightMeters(at: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(line.lineHeightMeters(at: 0.25), 6, accuracy: 1e-9)
        XCTAssertEqual(line.lineHeightMeters(at: 0.25), line.lineHeightMeters(at: 0.75), accuracy: 1e-9, "Symmetric")
        XCTAssertEqual(line.lineHeightMeters(at: -1), 0, accuracy: 1e-9, "Clamped outside 0…1")

        // A shot from the ground into the top corner: ends at 2.44 m, still peaking at 8 m.
        line.endHeightMeters = 2.44
        XCTAssertEqual(line.lineHeightMeters(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(line.lineHeightMeters(at: 1), 2.44, accuracy: 1e-9)
        XCTAssertEqual(line.lineHeightMeters(at: 0.5), 8, accuracy: 1e-9, "The peak still matches the arc height")
        line.startHeightMeters = 1
        XCTAssertEqual(line.lineHeightMeters(at: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(line.lineHeightMeters(at: 0.5), 8, accuracy: 1e-9)
        // A low arc between raised ends never dips below the straight line between them.
        var flatish = BoardElement(kind: .line, position: BoardPoint(0.1, 0.5), points: [BoardPoint(0.9, 0.5)])
        flatish.startHeightMeters = 4; flatish.endHeightMeters = 4; flatish.arcHeightMeters = 1
        XCTAssertEqual(flatish.lineHeightMeters(at: 0.5), 4, accuracy: 1e-9)

        let decoded = try JSONDecoder().decode(BoardElement.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(decoded, line)
        XCTAssertTrue(try decodeFixture().elements.allSatisfy { !$0.isAerial }, "Old boards have no aerial lines")
        XCTAssertNil(try decodeFixture().elements.first?.heightMeters)
    }

    func testFollowingAnAerialLineLiftsTheElementMidTransition() throws {
        var (document, ball, line) = pathDocument(stages: 2)
        document.update(line) { $0.arcHeightMeters = 10 }
        document.attachToPath(ball, pathID: line, fromFrame: 0)
        let start = try XCTUnwrap(document.elements(at: 0).first { $0.id == ball })
        XCTAssertNil(start.heightMeters, "On the ground at the start")
        let mid = try XCTUnwrap(document.elements(at: 0.5).first { $0.id == ball })
        XCTAssertEqual(mid.heightMeters ?? 0, 10, accuracy: 1e-9, "At the peak halfway through")
        let quarter = try XCTUnwrap(document.elements(at: 0.25).first { $0.id == ball })
        XCTAssertGreaterThan(quarter.heightMeters ?? 0, 0)
        XCTAssertLessThan(quarter.heightMeters ?? 0, 10)
        let sample = try XCTUnwrap(BoardDocument.pathSample(pathID: line, progress: 0.5, in: document.elements, field: document.fieldType))
        XCTAssertEqual(sample.heightMeters, 10, accuracy: 1e-9, "The resolver exposes the height for both renderers")
        XCTAssertEqual(BoardDocument.pathLocation(pathID: line, progress: 0.5, in: document.elements, field: document.fieldType)?.point, sample.point)
        // Thumbnails, onion skin and exports draw aerial lines without trouble.
        XCTAssertNotNil(TacticalBoardExporter.imageData(document: document, time: 0.5, size: CGSize(width: 240, height: 160), scale: 1, jpeg: false))
        XCTAssertFalse(document.onionSkin(aroundFrame: 0).next.isEmpty)
    }

    /// Aerial lines for design review. Run with `TEST_RUNNER_CAMELOT_BOARD_GALLERY=<folder>`.
    func testRenderAerialGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["CAMELOT_BOARD_GALLERY"] else { throw XCTSkip("Set TEST_RUNNER_CAMELOT_BOARD_GALLERY to write the gallery") }
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = BoardDocument()
        let striker = BoardElement(kind: .player, position: BoardPoint(0.25, 0.7), colorHex: document.homeColorHex, number: 9)
        var shot = BoardElement(kind: .line, position: BoardPoint(0.25, 0.7), points: [BoardPoint(0.97, 0.45)])
        shot.lineStyle = BoardLineStyle(width: 1.2)
        shot.startAttachment = striker.id
        shot.arcHeightMeters = 8
        shot.endHeightMeters = 2.44
        shot.showsLength = true
        var lofted = BoardElement(kind: .polyline, position: BoardPoint(0.2, 0.2), points: [BoardPoint(0.5, 0.1), BoardPoint(0.8, 0.25)], colorHex: BoardPalette.lime)
        lofted.lineStyle = BoardLineStyle(pattern: .dashed, width: 1)
        lofted.arcHeightMeters = 4
        let flat = BoardElement(kind: .line, position: BoardPoint(0.2, 0.9), points: [BoardPoint(0.8, 0.9)])
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.28, 0.68))
        document.elements = [shot, lofted, flat, striker, ball]
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        document.attachToPath(ball.id, pathID: shot.id, fromFrame: 0)
        for style in [BoardFieldStyle.grass, .chalk] {
            document.style = style
            for (name, size) in [("portrait", CGSize(width: 402, height: 560)), ("landscape", CGSize(width: 780, height: 330))] {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    UIColor(red: 0.045, green: 0.047, blue: 0.055, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
                    BoardRenderer(document: document, time: 0.5, inset: 10).draw(in: context.cgContext, size: size)
                }
                try image.pngData()?.write(to: folder.appending(path: "aerial-\(style.rawValue)-\(name).png"))
            }
        }
    }

    // MARK: Performance

    /// A realistic heavy board: 22 players, equipment, lines (aerial, connected, curved), zones and 6 stages
    /// with follow paths.
    static func heavyDocument() -> BoardDocument {
        var document = BoardDocument()
        document.fieldType = .footballFull
        var elements: [BoardElement] = []
        for index in 0..<22 {
            let home = index < 11
            let row = Double(index % 11)
            var player = BoardElement(kind: index % 11 == 0 ? .goalkeeper : .player,
                                      position: BoardPoint(home ? 0.1 + row * 0.035 : 0.9 - row * 0.035, 0.1 + row * 0.07),
                                      colorHex: home ? document.homeColorHex : document.awayColorHex, number: index % 11 + 1)
            player.label = home ? "Home \(index + 1)" : ""
            elements.append(player)
        }
        for index in 0..<8 {
            elements.append(BoardElement(kind: .cone, position: BoardPoint(0.2 + Double(index) * 0.07, 0.85), colorHex: BoardPalette.orange))
        }
        elements.append(BoardElement(kind: .ballCart, position: BoardPoint(0.05, 0.95), colorHex: "1E2A3A"))
        var wall = BoardElement(kind: .wall, position: BoardPoint(0.7, 0.2), colorHex: "3A3F4B")
        wall.count = 5
        elements.append(wall)
        elements.append(BoardElement(kind: .goal, position: BoardPoint(0.98, 0.5), colorHex: BoardPalette.white))
        var zone = BoardElement(kind: .zone, position: BoardPoint(0.55, 0.1), points: [BoardPoint(0.9, 0.45)], colorHex: BoardPalette.keeper)
        zone.zoneShape = .ellipse
        elements.append(zone)
        elements.append(BoardElement(kind: .polygon, position: BoardPoint(0.1, 0.55), points: [BoardPoint(0.35, 0.5), BoardPoint(0.3, 0.75)], colorHex: BoardPalette.purple))
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.2, 0.3))
        elements.append(ball)
        // Lines: a connected pass, a curved run, a wavy dribble, an aerial shot and a polyline.
        var pass = BoardElement(kind: .line, position: elements[0].position, points: [elements[13].position])
        pass.lineStyle = .pass; pass.startAttachment = elements[0].id; pass.endAttachment = elements[13].id
        var run = BoardElement(kind: .line, position: BoardPoint(0.3, 0.6), points: [BoardPoint(0.7, 0.35), BoardPoint(0.5, 0.75)])
        run.isCurved = true; run.lineStyle = .run
        var dribble = BoardElement(kind: .polyline, position: BoardPoint(0.2, 0.9), points: [BoardPoint(0.45, 0.8), BoardPoint(0.7, 0.9)])
        dribble.lineStyle = .dribble
        var shot = BoardElement(kind: .line, position: BoardPoint(0.35, 0.4), points: [BoardPoint(0.95, 0.5)])
        shot.arcHeightMeters = 9; shot.endHeightMeters = 2.44; shot.showsLength = true
        var lane = BoardElement(kind: .polyline, position: BoardPoint(0.15, 0.15), points: [BoardPoint(0.5, 0.25), BoardPoint(0.85, 0.15)])
        lane.lineStyle = BoardLineStyle(pattern: .dotted, shape: .zigzag)
        elements.append(contentsOf: [pass, run, dribble, shot, lane])
        document.elements = elements
        for _ in 0..<6 { document.insertKeyframe(after: nil) }
        // Follow paths: the ball on the shot, two players on the run and the zone.
        document.attachToPath(ball.id, pathID: shot.id, fromFrame: 0)
        document.attachToPath(elements[1].id, pathID: run.id, fromFrame: 0)
        document.attachToPath(elements[12].id, pathID: zone.id, fromFrame: 1)
        // Every stage moves the outfield players a little.
        for stage in 0..<6 {
            document.showFrame(stage)
            for index in 2..<22 where index != 12 {
                document.update(document.elements[index].id) { $0.position = $0.position.offset(dx: 0.01 * Double(stage % 3) - 0.01, dy: 0.008 * Double(stage % 2)).clamped() }
            }
            document.recordPoses(in: stage)
        }
        document.showFrame(0)
        return document
    }

    private func measureFrames(_ label: String, count: Int = 60, _ body: (Int) -> Void) -> (median: Double, p95: Double) {
        var times: [Double] = []
        for frame in 0..<count {
            let start = CFAbsoluteTimeGetCurrent()
            body(frame)
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2], p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print(String(format: "PERF %@: median %.2f ms, p95 %.2f ms", label, median, p95))
        return (median, p95)
    }

    /// Frame budget for a heavy animated board. Generous next to 16.7 ms so a shared simulator cannot
    /// make it flaky, but tight enough to catch a real regression.
    /// The editor puts the field behind the canvas as `BoardSurfaceCache.canvas`. That has to land the
    /// field exactly where the renderer would draw it itself, or elements would sit off the pitch.
    func testFieldBehindCanvasMatchesTheRendererDrawingIt() throws {
        let document = Self.heavyDocument()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        for size in [CGSize(width: 402, height: 620), CGSize(width: 780, height: 380)] {
            let reserved = CGSize(width: 0, height: 52)
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let together = renderer.image { context in
                BoardRenderer(document: document, time: 0.4, inset: 10, reserved: reserved).draw(in: context.cgContext, size: size)
            }
            let layered = renderer.image { context in
                let cg = context.cgContext
                let surface = BoardSurfaceCache.shared.canvas(field: document.fieldType, style: document.fieldStyle, size: size,
                                                              inset: 10, reserved: reserved, scale: 2)
                XCTAssertNotNil(surface, "The editor's field image is available at \(size)")
                if let surface {
                    cg.saveGState()
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    cg.draw(surface, in: CGRect(origin: .zero, size: size))
                    cg.restoreGState()
                }
                BoardRenderer(document: document, time: 0.4, inset: 10, reserved: reserved, drawsSurface: false).draw(in: cg, size: size)
            }
            XCTAssertLessThan(try Self.meanDifference(together, layered), 3,
                              "The field behind the canvas lands where the renderer would draw it (\(size))")
        }
    }

    /// Mean absolute difference per colour channel, 0…255.
    private static func meanDifference(_ a: UIImage, _ b: UIImage) throws -> Double {
        let first = try XCTUnwrap(a.cgImage), second = try XCTUnwrap(b.cgImage)
        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let left = try pixels(first), right = try pixels(second)
        let total = zip(left, right).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(left.count)
    }

    func testHeavyBoardRendersWithinFrameBudget() throws {
        let document = Self.heavyDocument()
        let size = CGSize(width: 402, height: 620)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let duration = document.duration
        // Warm the surface cache the way the editor does before playback starts.
        _ = renderer.image { context in BoardRenderer(document: document, time: 0, inset: 10).draw(in: context.cgContext, size: size) }

        // The editor shows the field as an image behind the canvas, so a playback frame redraws only
        // elements. `drawsSurface: true` is the export and thumbnail path, measured separately.
        let play = measureFrames("playback frame") { frame in
            let time = duration * Double(frame) / 60
            _ = renderer.image { context in
                BoardRenderer(document: document, time: time, inset: 10, drawsSurface: false).draw(in: context.cgContext, size: size)
            }
        }
        let export = measureFrames("playback frame, field included") { frame in
            let time = duration * Double(frame) / 60
            _ = renderer.image { context in
                BoardRenderer(document: document, time: time, inset: 10).draw(in: context.cgContext, size: size)
            }
        }
        let onion = measureFrames("editing frame with onion skin") { frame in
            var editing = document
            editing.showsOnionSkin = true
            _ = renderer.image { context in
                BoardRenderer(document: editing, selectedID: editing.elements.last?.id, showsHandles: true, inset: 10, drawsSurface: false,
                              animationFrame: 2, onionFrame: 2).draw(in: context.cgContext, size: size)
            }
        }
        let state = measureFrames("layout resolve") { frame in
            _ = document.elements(at: duration * Double(frame) / 60)
        }
        // Two tiers, because these numbers move by 50% between runs on the same hardware: a phone that
        // has just run the rest of the suite throttles, and a shared simulator competes with whatever
        // else is on the Mac. The default ceilings only catch a gross regression and never flake; the
        // real budget is opt-in and meant for an idle device:
        //     TEST_RUNNER_BOARD2D_STRICT_PERF=1 xcodebuild test -destination 'platform=iOS,id=…'
        // Measured on an idle iPhone 16: playback 10.1 ms, with the field 11.6 ms, onion skin 19.3 ms.
        // Measured on the iPhone 16 simulator: 13.5 / 16.5 / 35 ms (onion is dearer there than on device).
        let strict = ProcessInfo.processInfo.environment["BOARD2D_STRICT_PERF"] != nil
        XCTAssertLessThan(play.median, strict ? 16 : 30, "A heavy board plays within a frame")
        XCTAssertLessThan(play.p95, strict ? 26 : 60, "No slow frames while playing")
        XCTAssertLessThan(export.median, strict ? 22 : 40, "Exports and thumbnails draw the field too")
        // An onion-skin frame draws the live board plus a trail per moved element and the cached ghost
        // layer. It is an editing aid, off by default and never shown while playing, so it is held to a
        // looser ceiling than the frame budget.
        XCTAssertLessThan(onion.median, strict ? 30 : 60, "Editing with onion skin stays usable")
        XCTAssertLessThan(state.median, strict ? 1 : 5, "Resolving the layout is cheap")
    }

    // MARK: Training library

    static let trainingKinds: [BoardElementKind] = [.tallCone, .domeCone, .pole, .hurdle, .ladder, .ring, .wall, .goal, .popUpGoal, .rebounder, .flag, .ballCart, .coach, .referee, .stepMarker]

    func testTrainingElementsRoundTripAndOldDocumentsStillDecode() throws {
        // An old element without any of the newer keys.
        let legacy = #"{"version":1,"fieldType":"futsal","viewAngle":"top","homeColorHex":"2F80ED","awayColorHex":"EB5757","keyframes":[],"elements":[{"id":"4E6DE079-8DCC-44E9-A9E3-EF9233EA96F4","kind":"cone","position":{"x":0.5,"y":0.5},"points":[],"colorHex":"FF8A3D","label":"","size":1,"opacity":0.3,"rotation":0,"arrowStyle":"pass","isCurved":false,"isDoubleHeaded":false,"hasBlockEnd":false,"zoneShape":"rectangle"}]}"#
        let old = try JSONDecoder().decode(BoardDocument.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.elements.first?.kind, .cone)
        XCTAssertNil(old.elements.first?.count)
        XCTAssertNil(old.elements.first?.showsLength)
        XCTAssertEqual(try decodeFixture().elements.count, 27)

        var document = BoardDocument()
        for (index, kind) in Self.trainingKinds.enumerated() {
            var element = BoardElement(kind: kind, position: BoardPoint(0.1 + Double(index) * 0.05, 0.5), colorHex: BoardRenderer.defaultColor(for: kind, document: document))
            element.rotation = 30; element.size = 1.4
            if kind == .wall { element.count = 5 }
            if kind == .stepMarker { element.number = 3 }
            XCTAssertTrue(kind.isPoint, "\(kind) is a point element")
            XCTAssertGreaterThan(element.visualRadiusMeters(field: .footballFull), 0, "\(kind) has a size")
            document.elements.append(element)
        }
        var line = BoardElement(kind: .line, position: BoardPoint(0, 0.5), points: [BoardPoint(1, 0.5)])
        line.showsLength = true
        document.elements.append(line)
        let decoded = try JSONDecoder().decode(BoardDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.elements.first { $0.kind == .wall }?.wallCount, 5)
        XCTAssertEqual(BoardElement(kind: .wall, position: .center).wallCount, 4)
        XCTAssertEqual(BoardRenderer(document: document).lengthMeters(of: line), 105, accuracy: 1e-9)
    }

    func testTrainingElementsHitTestRespectingRotation() {
        var document = BoardDocument()
        var ladder = BoardElement(kind: .ladder, position: .center)
        document.elements = [ladder]
        let size = CGSize(width: 1000, height: 650)
        let projection = BoardProjection(field: .footballFull, size: size)
        let center = projection.point(.center)
        let half = BoardRenderer(document: document).pointRadius(ladder, projection: projection)
        let along = CGPoint(x: center.x + half * 0.9, y: center.y)
        let across = CGPoint(x: center.x, y: center.y + half * 0.9)
        XCTAssertEqual(BoardRenderer(document: document).hitTest(along, size: size), ladder.id)
        XCTAssertNil(BoardRenderer(document: document).hitTest(across, size: size))
        ladder.rotation = 90
        document.elements = [ladder]
        XCTAssertEqual(BoardRenderer(document: document).hitTest(across, size: size), ladder.id, "A turned ladder is hit along its new length")
        XCTAssertNil(BoardRenderer(document: document).hitTest(along, size: size))
    }

    /// Renders every training element on each style. Run with `TEST_RUNNER_CAMELOT_BOARD_GALLERY=<folder>`.
    func testRenderTrainingGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["CAMELOT_BOARD_GALLERY"] else { throw XCTSkip("Set TEST_RUNNER_CAMELOT_BOARD_GALLERY to write the gallery") }
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var sheet: [UIImage] = []
        for style in BoardFieldStyle.allCases {
            var document = BoardDocument()
            document.fieldType = .footballHalf
            document.style = style
            let columns = 5
            for (index, kind) in Self.trainingKinds.enumerated() {
                let column = index % columns, row = index / columns
                var element = BoardElement(kind: kind, position: BoardPoint(0.12 + Double(column) * 0.19, 0.2 + Double(row) * 0.27), colorHex: BoardRenderer.defaultColor(for: kind, document: document))
                if kind == .wall { element.count = 4 }
                if kind == .stepMarker { element.number = index }
                if [.hurdle, .flag, .coach].contains(kind) { element.rotation = 25 }
                if kind == .ladder { element.size = 0.6; element.rotation = -20 }
                document.elements.append(element)
            }
            var run = BoardElement(kind: .line, position: BoardPoint(0.1, 0.93), points: [BoardPoint(0.6, 0.93)])
            run.lineStyle = .run; run.showsLength = true
            document.elements.append(run)
            let size = CGSize(width: 780, height: 620)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(red: 0.045, green: 0.047, blue: 0.055, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
                BoardRenderer(document: document, inset: 10).draw(in: context.cgContext, size: size)
            }
            try image.pngData()?.write(to: folder.appending(path: "training-\(style.rawValue).png"))
            sheet.append(image)
        }
        let contact = UIGraphicsImageRenderer(size: CGSize(width: 780 * 2, height: 620 * 3), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { _ in
            for (index, image) in sheet.enumerated() { image.draw(in: CGRect(x: CGFloat(index % 2) * 780, y: CGFloat(index / 2) * 620, width: 780, height: 620)) }
        }
        try contact.pngData()?.write(to: folder.appending(path: "sheet-training.png"))
    }

    // MARK: Design gallery

    /// Renders every field × style in phone portrait and landscape sizes for design review.
    /// Run with `TEST_RUNNER_CAMELOT_BOARD_GALLERY=<folder>`.
    func testRenderDesignGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["CAMELOT_BOARD_GALLERY"] else { throw XCTSkip("Set TEST_RUNNER_CAMELOT_BOARD_GALLERY to write the gallery") }
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ink = UIColor(red: 0.045, green: 0.047, blue: 0.055, alpha: 1)
        func render(_ document: BoardDocument, size: CGSize, selected: UUID? = nil, scale: CGFloat = 3) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                ink.setFill(); context.fill(CGRect(origin: .zero, size: size))
                BoardRenderer(document: document, selectedID: selected, showsHandles: selected != nil, inset: 10).draw(in: context.cgContext, size: size)
            }
        }
        for field in [BoardFieldType.footballFull, .footballHalf, .futsal, .basketball, .blank] {
            var sheet: [UIImage] = []
            for style in BoardFieldStyle.allCases {
                var document = Self.galleryDocument(field: field)
                document.style = style
                let portrait = render(document, size: CGSize(width: 402, height: 560), selected: style == .grass ? document.elements.first(where: { $0.kind == .player && $0.rotation != 0 })?.id : nil)
                try portrait.pngData()?.write(to: folder.appending(path: "\(field.rawValue)-\(style.rawValue)-portrait.png"))
                let landscape = render(document, size: CGSize(width: 780, height: 330))
                try landscape.pngData()?.write(to: folder.appending(path: "\(field.rawValue)-\(style.rawValue)-landscape.png"))
                sheet.append(portrait)
            }
            let cell = CGSize(width: 402, height: 560)
            let contact = UIGraphicsImageRenderer(size: CGSize(width: cell.width * 5, height: cell.height), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { _ in
                for (index, image) in sheet.enumerated() { image.draw(in: CGRect(x: CGFloat(index) * cell.width, y: 0, width: cell.width, height: cell.height)) }
            }
            try contact.pngData()?.write(to: folder.appending(path: "sheet-\(field.rawValue).png"))
        }
        try render(try decodeFixture(), size: CGSize(width: 402, height: 560)).pngData()?.write(to: folder.appending(path: "phone-board-portrait.png"))
        var fixture = try decodeFixture()
        fixture.viewAngle = .top
        try render(fixture, size: CGSize(width: 780, height: 330)).pngData()?.write(to: folder.appending(path: "phone-board-landscape.png"))
    }

    static func galleryDocument(field: BoardFieldType) -> BoardDocument {
        var document = BoardDocument()
        document.fieldType = field
        let home = document.homeColorHex, away = document.awayColorHex
        var p1 = BoardElement(kind: .player, position: BoardPoint(0.3, 0.3), colorHex: home, number: 4)
        p1.rotation = 35
        var p2 = BoardElement(kind: .player, position: BoardPoint(0.55, 0.62), colorHex: home, number: 10, label: "Ana")
        p2.size = 1.3
        let p3 = BoardElement(kind: .player, position: BoardPoint(0.72, 0.28), colorHex: home, number: 9)
        let keeper = BoardElement(kind: .goalkeeper, position: BoardPoint(0.06, 0.5), colorHex: BoardPalette.keeper, number: 1)
        var opp = BoardElement(kind: .opponent, position: BoardPoint(0.62, 0.42), colorHex: away)
        opp.rotation = 200
        let opp2 = BoardElement(kind: .player, position: BoardPoint(0.82, 0.55), colorHex: away, number: 5)
        let ball = BoardElement(kind: .ball, position: BoardPoint(0.34, 0.34))
        let cones = [BoardPoint(0.2, 0.75), BoardPoint(0.26, 0.8), BoardPoint(0.32, 0.75)].map { BoardElement(kind: .cone, position: $0, colorHex: BoardPalette.orange) }
        let marker = BoardElement(kind: .marker, position: BoardPoint(0.4, 0.8), colorHex: BoardPalette.keeper)
        var goal = BoardElement(kind: .miniGoal, position: BoardPoint(0.88, 0.85), colorHex: BoardPalette.white)
        goal.rotation = -30
        var dummy = BoardElement(kind: .mannequin, position: BoardPoint(0.45, 0.2), colorHex: "9A9AA0")
        dummy.rotation = 90
        var pass = BoardElement(kind: .line, position: p1.position, points: [p2.position])
        pass.lineStyle = .pass; pass.startAttachment = p1.id; pass.endAttachment = p2.id
        var run = BoardElement(kind: .line, position: p2.position, points: [BoardPoint(0.8, 0.8), BoardPoint(0.75, 0.6)])
        run.isCurved = true; run.lineStyle = .run; run.startAttachment = p2.id; run.colorHex = BoardPalette.lime
        var dribble = BoardElement(kind: .polyline, position: p3.position, points: [BoardPoint(0.8, 0.15), BoardPoint(0.93, 0.3)])
        dribble.lineStyle = BoardLineStyle(shape: .wavy, width: 1); dribble.startAttachment = p3.id
        var zig = BoardElement(kind: .line, position: BoardPoint(0.1, 0.9), points: [BoardPoint(0.3, 0.93)])
        zig.lineStyle = BoardLineStyle(pattern: .dotted, shape: .zigzag, startCap: .dot, endCap: .bar)
        zig.colorHex = BoardPalette.pink
        var zone = BoardElement(kind: .zone, position: BoardPoint(0.58, 0.12), points: [BoardPoint(0.78, 0.4)], colorHex: BoardPalette.keeper)
        zone.rotation = 12; zone.borderPattern = .dashed; zone.opacity = 0.18
        var text = BoardElement(kind: .text, position: BoardPoint(0.5, 0.94), label: "Press the pivot")
        text.rotation = -8
        document.elements = [zone, pass, run, dribble, zig, p1, p2, p3, keeper, opp, opp2, ball, marker, goal, dummy, text] + cones
        return document
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    var values: [Double] { lock.withLock { storage } }
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
}

/// The board model before boards moved to their own tab, for migration tests.
enum LegacyBoardSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [TacticalBoard.self] }

    @Model
    final class TacticalBoard {
        @Attribute(.unique) var id: UUID
        var projectID: UUID
        var name: String
        var fieldType: String
        var viewAngle: String
        var createdAt: Date
        var updatedAt: Date
        var document: Data

        init(id: UUID, projectID: UUID, name: String, document: Data) {
            self.id = id
            self.projectID = projectID
            self.name = name
            fieldType = "footballFull"
            viewAngle = "broadcast"
            createdAt = .now
            updatedAt = .now
            self.document = document
        }
    }
}

extension TacticalBoardTests {
    /// A board saved on Miguel's phone before styles, rotation animation, line styles and attachments existed.
    static let phoneBoardJSON = #"""
{"viewAngle":"broadcast","elements":[{"label":"","isCurved":false,"rotation":0,"points":[],"position":{"y":0.1878775168746633,"x":0.703625300344178},"arrowStyle":"pass","opacity":0.3,"zoneShape":"rectangle","size":1,"isDoubleHeaded":false,"number":1,"colorHex":"2F80ED","hasBlockEnd":false,"kind":"player","id":"4E6DE079-8DCC-44E9-A9E3-EF9233EA96F4"},{"label":"","isCurved":false,"rotation":0,"points":[],"position":{"y":0.7800073137603177,"x":0.7847838957963291},"arrowStyle":"pass","opacity":0.3,"zoneShape":"rectangle","size":1,"isDoubleHeaded":false,"number":2,"colorHex":"2F80ED","hasBlockEnd":false,"kind":"player","id":"C7DDDDB9-D933-4DE8-9B6F-9A585B812600"},{"label":"","isCurved":false,"rotation":0,"points":[],"position":{"y":0.18101034374673497,"x":0.5175488454706927},"arrowStyle":"pass","opacity":0.3,"zoneShape":"rectangle","size":1,"isDoubleHeaded":false,"number":3,"colorHex":"2F80ED","hasBlockEnd":false,"kind":"player","id":"EE2E5E3E-C2F2-4897-8827-241C6490872E"},{"label":"","isCurved":false,"rotation":0,"points":[],"position":{"y":0.7838104691254834,"x":0.5520307874481941},"arrowStyle":"pass","opacity":0.3,"zoneShape":"rectangle","size":1,"isDoubleHeaded":false,"number":4,"colorHex":"2F80ED","hasBlockEnd":false,"kind":"player","id":"B9291756-3122-4A41-B72B-6C5B14AAE585"},{"points":[],"hasBlockEnd":false,"arrowStyle":"pass","kind":"goalkeeper","isDoubleHeaded":false,"label":"","colorHex":"F2C94C","number":1,"id":"68978292-AED6-4863-9665-3805EED99CDD","zoneShape":"rectangle","size":1,"isCurved":false,"rotation":0,"position":{"y":0.5022988505747127,"x":0.936807881773399},"opacity":0.3},{"points":[],"hasBlockEnd":false,"arrowStyle":"pass","kind":"opponent","isDoubleHeaded":false,"label":"","colorHex":"EB5757","id":"204AC15B-131D-44A7-8475-418DD9F67174","zoneShape":"rectangle","size":1,"isCurved":false,"rotation":0,"position":{"y":0.2641379310344828,"x":0.32879036672140116},"opacity":0.3},{"points":[],"hasBlockEnd":false,"arrowStyle":"pass","kind":"opponent","isDoubleHeaded":false,"label":"","colorHex":"EB5757","id":"B5B7EA36-7211-4D9C-BCE2-81E2A752D061","zoneShape":"rectangle","size":1,"isCurved":false,"rotation":0,"position":{"y":0.6022098004388257,"x":0.33590290112492593},"opacity":0.3},{"points":[],"hasBlockEnd":false,"arrowStyle":"pass","kind":"player","isDoubleHeaded":false,"label":"","colorHex":"EB5757","number":1,"id":"775F5B64-2EFE-46DA-AF96-DD8FA11D6923","zoneShape":"rectangle","size":1,"isCurved":false,"rotation":0,"position":{"y":0.5384673565510366,"x":0.45424482109227854},"opacity":0.3},{"position":{"y":0.7657454811409466,"x":0.4264179988158673},"zoneShape":"rectangle","opacity":0.3,"hasBlockEnd":false,"rotation":0,"id":"AE527FBA-EBCE-4564-8A1C-BC9CC5DF1A2F","isDoubleHeaded":false,"label":"","number":2,"kind":"player","colorHex":"EB5757","points":[],"arrowStyle":"pass","isCurved":false,"size":1},{"position":{"y":0.18101034374673497,"x":0.3820840734162225},"zoneShape":"rectangle","opacity":0.3,"hasBlockEnd":false,"rotation":0,"id":"335B189E-C0FC-47FD-91DA-82C1F782D005","isDoubleHeaded":false,"label":"","number":3,"kind":"player","colorHex":"EB5757","points":[],"arrowStyle":"pass","isCurved":false,"size":1},{"position":{"y":0.5675862068965517,"x":0.6610859332238642},"zoneShape":"rectangle","opacity":0.3,"hasBlockEnd":false,"rotation":0,"id":"736073C2-05D2-45FD-9153-CA0134BC4303","isDoubleHeaded":false,"label":"","kind":"marker","colorHex":"F2C94C","points":[],"arrowStyle":"pass","isCurved":false,"size":1},{"position":{"y":0.21968751388593655,"x":0.8501116720672056},"zoneShape":"rectangle","opacity":0.3,"hasBlockEnd":false,"rotation":0,"id":"62A0354C-C752-4E7F-B4E3-8D940F5819D8","isDoubleHeaded":false,"label":"","kind":"miniGoal","colorHex":"FFFFFF","points":[],"arrowStyle":"pass","isCurved":false,"size":1},{"rotation":0,"zoneShape":"rectangle","colorHex":"9A9AA0","hasBlockEnd":false,"label":"","kind":"mannequin","id":"8D91F949-20A1-413D-97D0-1D9DD31C4F81","isDoubleHeaded":false,"points":[],"isCurved":false,"position":{"y":0.7496551724137931,"x":0.8867848932676519},"size":1,"arrowStyle":"pass","opacity":0.3},{"rotation":0,"zoneShape":"rectangle","colorHex":"FFFFFF","hasBlockEnd":false,"label":"","kind":"arrow","id":"F1144FB2-0924-443D-A411-E166CE009863","isDoubleHeaded":false,"points":[{"y":0.23195402298850581,"x":0.5473431855500821}],"isCurved":false,"position":{"y":0.733103448275862,"x":0.7664915161466885},"size":1,"arrowStyle":"pass","opacity":0.3},{"rotation":0,"zoneShape":"rectangle","colorHex":"FFFFFF","hasBlockEnd":false,"label":"","kind":"arrow","id":"ACAB6570-ECCC-4332-BEB5-545CF3B2C1E4","isDoubleHeaded":false,"points":[{"y":0.49262836490528417,"x":0.5}],"isCurved":false,"position":{"y":0.21816091954022998,"x":0.6646590038314175},"size":1,"arrowStyle":"dribble","opacity":0.3},{"rotation":0,"zoneShape":"rectangle","colorHex":"F2C94C","hasBlockEnd":false,"label":"","kind":"zone","id":"B60D33D0-674A-44D7-8F7A-4EA9D83022F3","isDoubleHeaded":false,"points":[{"y":0.732183908045977,"x":0.3579704433497537}],"isCurved":false,"position":{"y":0.9482758620689655,"x":0.08522605363984664},"size":1,"arrowStyle":"pass","opacity":0.3},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[{"x":0.014481941977501356,"y":0.5004753944206457},{"x":0.054505624629958505,"y":0.07642357120468074},{"x":0.2553711775952282,"y":0.19256667564019292}],"zoneShape":"rectangle","arrowStyle":"pass","label":"","kind":"polygon","id":"0503FF77-32C0-4E5D-9840-94C3349D322A","colorHex":"F2C94C","opacity":0.3,"position":{"x":0.23952134209474812,"y":0.5278718158421573}},{"isDoubleHeaded":true,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[{"x":0.6051078270388615,"y":0.7524137931034482}],"zoneShape":"rectangle","arrowStyle":"pass","label":"","kind":"arrow","id":"F9939479-81CC-422D-B2BE-EBDF3E49C316","colorHex":"FFFFFF","opacity":0.3,"position":{"x":0.8882297217288336,"y":0.536605370389719}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":true,"size":1,"points":[{"x":0.7490704558910597,"y":0.11255354717375404},{"x":0.9799763173475429,"y":0.06976804931564101}],"zoneShape":"rectangle","arrowStyle":"pass","label":"","kind":"arrow","id":"D85FA263-3756-43C5-B333-779643E9251D","colorHex":"FFFFFF","opacity":0.3,"position":{"x":0.9016726874657908,"y":0.39471264367816095}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[],"zoneShape":"rectangle","arrowStyle":"pass","label":"","kind":"cone","id":"CC6D53B5-6707-48AA-8EA9-6FFDDE1DA8A4","colorHex":"FF8A3D","opacity":0.3,"position":{"x":0.7599408866995074,"y":0.4250574712643678}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[],"zoneShape":"rectangle","arrowStyle":"pass","label":"","kind":"cone","id":"0DD54E6E-D64D-461F-A917-5952DE9A2366","colorHex":"FF8A3D","opacity":0.3,"position":{"x":0.5902072232089994,"y":0.555621147215547}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[],"zoneShape":"rectangle","arrowStyle":"pass","label":"","kind":"cone","id":"DE428FEC-5E7A-4AE4-966E-B309AD350FAA","colorHex":"FF8A3D","opacity":0.3,"position":{"x":0.677027827116637,"y":0.8598735764287954}},{"isDoubleHeaded":false,"rotation":0,"hasBlockEnd":false,"isCurved":false,"size":1,"points":[{"y":0.07287356321839084,"x":0.2632840722495895}],"zoneShape":"rectangle","arrowStyle":"run","label":"","kind":"arrow","id":"DCA66269-1B9D-45B3-8DC6-6655481FA401","colorHex":"FFFFFF","opacity":0.3,"position":{"y":0.058160919540230005,"x":0.9320437876299945}},{"id":"909E106D-0D0E-4B3A-A024-B7D6A2DD08AC","position":{"x":0.9469315818281335,"y":0.8572413793103448},"points":[],"size":1,"colorHex":"FFFFFF","hasBlockEnd":false,"label":"","rotation":0,"isDoubleHeaded":false,"zoneShape":"rectangle","opacity":0.3,"isCurved":false,"kind":"miniGoal","arrowStyle":"pass"},{"id":"5D3CBE6A-868F-40FD-BF6F-1816E912AAB0","position":{"x":0.8010311986863712,"y":0.32114942528735635},"points":[],"size":1,"colorHex":"FFFFFF","hasBlockEnd":false,"label":"","rotation":0,"isDoubleHeaded":false,"zoneShape":"rectangle","opacity":0.3,"isCurved":false,"kind":"ball","arrowStyle":"pass"},{"id":"A186E899-CE9B-40D7-8A6C-898D79FE0776","position":{"x":0.6351568975725281,"y":0.6459460871382301},"points":[],"size":1,"colorHex":"FFFFFF","hasBlockEnd":false,"label":"","rotation":0,"isDoubleHeaded":false,"zoneShape":"rectangle","opacity":0.3,"isCurved":false,"kind":"ball","arrowStyle":"pass"},{"id":"599C284E-D81C-416C-9779-A7EB0409507F","position":{"x":0.4184132622853759,"y":0.37877442273534634},"points":[],"size":1,"colorHex":"FFFFFF","hasBlockEnd":false,"label":"","rotation":0,"isDoubleHeaded":false,"zoneShape":"rectangle","opacity":0.3,"isCurved":false,"kind":"ball","arrowStyle":"pass"}],"keyframes":[{"id":"80CF0E11-B5CF-4A55-BFE0-9CA20D62D2DA","poses":["0503FF77-32C0-4E5D-9840-94C3349D322A",{"points":[{"x":0.014481941977501356,"y":0.5004753944206457},{"x":0.054505624629958505,"y":0.07642357120468074},{"x":0.2553711775952282,"y":0.19256667564019292}],"position":{"x":0.23952134209474812,"y":0.5278718158421573}},"5D3CBE6A-868F-40FD-BF6F-1816E912AAB0",{"points":[],"position":{"y":0.32114942528735635,"x":0.8010311986863712}},"775F5B64-2EFE-46DA-AF96-DD8FA11D6923",{"points":[],"position":{"x":0.45424482109227854,"y":0.5384673565510366}},"C7DDDDB9-D933-4DE8-9B6F-9A585B812600",{"points":[],"position":{"y":0.7800073137603177,"x":0.7847838957963291}},"335B189E-C0FC-47FD-91DA-82C1F782D005",{"points":[],"position":{"y":0.18101034374673497,"x":0.3820840734162225}},"8D91F949-20A1-413D-97D0-1D9DD31C4F81",{"points":[],"position":{"x":0.8867848932676519,"y":0.7496551724137931}},"F9939479-81CC-422D-B2BE-EBDF3E49C316",{"points":[{"x":0.6051078270388615,"y":0.7524137931034482}],"position":{"x":0.8882297217288336,"y":0.536605370389719}},"909E106D-0D0E-4B3A-A024-B7D6A2DD08AC",{"points":[],"position":{"y":0.8572413793103448,"x":0.9469315818281335}},"DE428FEC-5E7A-4AE4-966E-B309AD350FAA",{"points":[],"position":{"y":0.8598735764287954,"x":0.677027827116637}},"B9291756-3122-4A41-B72B-6C5B14AAE585",{"points":[],"position":{"y":0.7838104691254834,"x":0.5520307874481941}},"B60D33D0-674A-44D7-8F7A-4EA9D83022F3",{"points":[{"y":0.732183908045977,"x":0.3579704433497537}],"position":{"y":0.9482758620689655,"x":0.08522605363984664}},"AE527FBA-EBCE-4564-8A1C-BC9CC5DF1A2F",{"points":[],"position":{"x":0.4264179988158673,"y":0.7657454811409466}},"0DD54E6E-D64D-461F-A917-5952DE9A2366",{"points":[],"position":{"y":0.555621147215547,"x":0.5902072232089994}},"736073C2-05D2-45FD-9153-CA0134BC4303",{"position":{"y":0.5675862068965517,"x":0.6610859332238642},"points":[]},"ACAB6570-ECCC-4332-BEB5-545CF3B2C1E4",{"position":{"x":0.6646590038314175,"y":0.21816091954022998},"points":[{"x":0.5,"y":0.49262836490528417}]},"68978292-AED6-4863-9665-3805EED99CDD",{"position":{"x":0.936807881773399,"y":0.5022988505747127},"points":[]},"F1144FB2-0924-443D-A411-E166CE009863",{"position":{"x":0.7664915161466885,"y":0.733103448275862},"points":[{"x":0.5473431855500821,"y":0.23195402298850581}]},"B5B7EA36-7211-4D9C-BCE2-81E2A752D061",{"position":{"y":0.6022098004388257,"x":0.33590290112492593},"points":[]},"DCA66269-1B9D-45B3-8DC6-6655481FA401",{"position":{"y":0.058160919540230005,"x":0.9320437876299945},"points":[{"y":0.07287356321839084,"x":0.2632840722495895}]},"599C284E-D81C-416C-9779-A7EB0409507F",{"position":{"y":0.37877442273534634,"x":0.4184132622853759},"points":[]},"4E6DE079-8DCC-44E9-A9E3-EF9233EA96F4",{"position":{"y":0.1878775168746633,"x":0.703625300344178},"points":[]},"62A0354C-C752-4E7F-B4E3-8D940F5819D8",{"points":[],"position":{"x":0.8501116720672056,"y":0.21968751388593655}},"D85FA263-3756-43C5-B333-779643E9251D",{"points":[{"x":0.7490704558910597,"y":0.11255354717375404},{"x":0.9799763173475429,"y":0.06976804931564101}],"position":{"x":0.9016726874657908,"y":0.39471264367816095}},"204AC15B-131D-44A7-8475-418DD9F67174",{"points":[],"position":{"x":0.32879036672140116,"y":0.2641379310344828}},"EE2E5E3E-C2F2-4897-8827-241C6490872E",{"points":[],"position":{"x":0.5175488454706927,"y":0.18101034374673497}},"A186E899-CE9B-40D7-8A6C-898D79FE0776",{"points":[],"position":{"x":0.6351568975725281,"y":0.6459460871382301}},"CC6D53B5-6707-48AA-8EA9-6FFDDE1DA8A4",{"points":[],"position":{"x":0.7599408866995074,"y":0.4250574712643678}}],"duration":1},{"poses":["B60D33D0-674A-44D7-8F7A-4EA9D83022F3",{"position":{"y":0.9482758620689655,"x":0.08522605363984664},"points":[{"y":0.732183908045977,"x":0.3579704433497537}]},"736073C2-05D2-45FD-9153-CA0134BC4303",{"position":{"x":0.6610859332238642,"y":0.5675862068965517},"points":[]},"AE527FBA-EBCE-4564-8A1C-BC9CC5DF1A2F",{"position":{"y":0.7657454811409466,"x":0.4264179988158673},"points":[]},"ACAB6570-ECCC-4332-BEB5-545CF3B2C1E4",{"position":{"y":0.32364780658025927,"x":0.7585310734463276},"points":[{"y":0.4710344827586207,"x":0.4764772851669403}]},"4E6DE079-8DCC-44E9-A9E3-EF9233EA96F4",{"position":{"x":0.7991055263328787,"y":0.3069577760969963},"points":[]},"8D91F949-20A1-413D-97D0-1D9DD31C4F81",{"position":{"x":0.8867848932676519,"y":0.7496551724137931},"points":[]},"DE428FEC-5E7A-4AE4-966E-B309AD350FAA",{"position":{"y":0.8598735764287954,"x":0.677027827116637},"points":[]},"204AC15B-131D-44A7-8475-418DD9F67174",{"position":{"y":0.2641379310344828,"x":0.32879036672140116},"points":[]},"0DD54E6E-D64D-461F-A917-5952DE9A2366",{"position":{"x":0.5902072232089994,"y":0.555621147215547},"points":[]},"335B189E-C0FC-47FD-91DA-82C1F782D005",{"position":{"x":0.3820840734162225,"y":0.18101034374673497},"points":[]},"775F5B64-2EFE-46DA-AF96-DD8FA11D6923",{"position":{"x":0.4395555555555555,"y":0.49310344827586206},"points":[]},"B9291756-3122-4A41-B72B-6C5B14AAE585",{"position":{"x":0.5843471716289851,"y":0.9130976077097306},"points":[]},"D85FA263-3756-43C5-B333-779643E9251D",{"position":{"y":0.39471264367816095,"x":0.9016726874657908},"points":[{"y":0.11255354717375404,"x":0.7490704558910597},{"y":0.06976804931564101,"x":0.9799763173475429}]},"B5B7EA36-7211-4D9C-BCE2-81E2A752D061",{"points":[],"position":{"x":0.33590290112492593,"y":0.6022098004388257}},"0503FF77-32C0-4E5D-9840-94C3349D322A",{"points":[{"x":0.014481941977501356,"y":0.5004753944206457},{"x":0.054505624629958505,"y":0.07642357120468074},{"x":0.2553711775952282,"y":0.19256667564019292}],"position":{"x":0.23952134209474812,"y":0.5278718158421573}},"EE2E5E3E-C2F2-4897-8827-241C6490872E",{"points":[],"position":{"x":0.5535375460356645,"y":0.11976906757524947}},"C7DDDDB9-D933-4DE8-9B6F-9A585B812600",{"points":[],"position":{"y":0.7800073137603177,"x":0.7847838957963291}},"62A0354C-C752-4E7F-B4E3-8D940F5819D8",{"points":[],"position":{"x":0.8501116720672056,"y":0.21968751388593655}},"F9939479-81CC-422D-B2BE-EBDF3E49C316",{"points":[{"y":0.8691488035892323,"x":0.6153107344632768}],"position":{"y":0.536605370389719,"x":0.8882297217288336}},"68978292-AED6-4863-9665-3805EED99CDD",{"points":[],"position":{"y":0.5022988505747127,"x":0.936807881773399}},"F1144FB2-0924-443D-A411-E166CE009863",{"points":[{"y":0.18528788634097704,"x":0.5638983050847458}],"position":{"y":0.733103448275862,"x":0.7664915161466885}},"CC6D53B5-6707-48AA-8EA9-6FFDDE1DA8A4",{"points":[],"position":{"x":0.7599408866995074,"y":0.4250574712643678}}],"id":"1411EC9D-C75B-4CC6-8A07-330913AFD38D","duration":3}],"awayColorHex":"EB5757","homeColorHex":"2F80ED","version":1,"fieldType":"footballFull"}
"""#
}
