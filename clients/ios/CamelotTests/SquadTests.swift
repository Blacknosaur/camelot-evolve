import SwiftData
import UIKit
import XCTest
@testable import Camelot

final class SquadTests: XCTestCase {
    /// Photos go to a temporary folder, never the real Documents of the app hosting these tests.
    private var photoRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        photoRoot = FileManager.default.temporaryDirectory.appending(path: "squad-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        SquadPhotoStore.rootDirectory = photoRoot
    }

    override func tearDownWithError() throws {
        SquadPhotoStore.rootDirectory = URL.documentsDirectory
        if let photoRoot { try? FileManager.default.removeItem(at: photoRoot) }
        try super.tearDownWithError()
    }

    // MARK: Helpers

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: SquadPlayer.self, TacticalBoard.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// JPEG of a solid colour with an optional darker block, `width` × `height` pixels.
    private func photoData(width: Int = 900, height: Int = 1200, color: UIColor = .red) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.jpegData(compressionQuality: 0.9)!
    }

    private func photoID() -> UUID {
        let id = UUID()
        addTeardownBlock { SquadPhotoStore.delete(for: id) }
        return id
    }

    private func snapshot(_ name: String, _ number: Int?, _ position: SquadPosition, id: UUID = UUID()) -> SquadPlayerSnapshot {
        SquadPlayerSnapshot(id: id, name: name, number: number, position: position, colorHex: nil)
    }

    private func eleven() -> [SquadPlayerSnapshot] {
        [snapshot("Keeper", 1, .goalkeeper)]
            + (2...5).map { (n: Int) in snapshot("Def " + String(n), n, .defender) }
            + (6...8).map { (n: Int) in snapshot("Mid " + String(n), n, .midfielder) }
            + (9...11).map { (n: Int) in snapshot("Fwd " + String(n), n, .forward) }
    }

    // MARK: Model

    @MainActor
    func testSquadPlayerCreateUpdateDelete() throws {
        let context = try makeContext()
        let player = SquadPlayer(name: "Sam Kerr", number: 20, position: .forward, role: "ST", team: "First team", preferredFoot: .right, birthYear: 1993, heightCm: 167)
        context.insert(player)
        try context.save()

        var fetched = try XCTUnwrap(context.fetch(FetchDescriptor<SquadPlayer>()).first)
        XCTAssertEqual(fetched.squadPosition, .forward)
        XCTAssertEqual(fetched.foot, .right)
        XCTAssertEqual(fetched.positionLabel, "ST")
        XCTAssertEqual(fetched.snapshot.elementKind, .player)

        fetched.number = 9
        fetched.squadPosition = .goalkeeper
        fetched.colorHex = BoardPalette.lime
        try context.save()
        fetched = try XCTUnwrap(context.fetch(FetchDescriptor<SquadPlayer>()).first)
        XCTAssertEqual(fetched.number, 9)
        XCTAssertEqual(fetched.snapshot.elementKind, .goalkeeper)

        let copy = try fetched.duplicate(in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SquadPlayer>()), 2)
        XCTAssertEqual(copy.team, "First team")
        XCTAssertNil(copy.number, "Duplicates do not copy the shirt number")

        try copy.delete(from: context)
        try fetched.delete(from: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SquadPlayer>()), 0)
    }

    func testBoardLabelShortensLongNames() {
        XCTAssertEqual(snapshot("Sam Kerr", 20, .forward).boardLabel, "Sam Kerr")
        XCTAssertEqual(snapshot("Alexandra Popp-Schmidt", 11, .forward).boardLabel, "Popp-Schmidt")
        XCTAssertEqual(SquadPlayerSnapshot.initials(of: "sam kerr"), "SK")
        XCTAssertEqual(SquadPlayerSnapshot.initials(of: ""), "?")
    }

    // MARK: Photos

    func testPhotoIsStoredAsSquare512JPEGAndCached() throws {
        let id = photoID()
        XCTAssertNil(SquadPhotoStore.image(for: id))
        try SquadPhotoStore.save(photoData(width: 900, height: 1200), for: id)

        let url = SquadPhotoStore.url(for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        XCTAssertEqual(url.pathExtension, "jpg")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "SquadPhotos")
        let folderValues = try SquadPhotoStore.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertNotEqual(folderValues.isExcludedFromBackup, true,
                          "Photos are the coach's own content and cannot be regenerated: they belong in the backup")

        let image = try XCTUnwrap(SquadPhotoStore.image(for: id))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
        XCTAssertTrue(SquadPhotoStore.image(for: id) === image, "Second read comes from the cache")

        // Saving invalidates the cache.
        try SquadPhotoStore.save(photoData(width: 400, height: 300, color: .blue), for: id)
        let replaced = try XCTUnwrap(SquadPhotoStore.image(for: id))
        XCTAssertFalse(replaced === image)
        XCTAssertEqual(replaced.width, 512)

        SquadPhotoStore.delete(for: id)
        XCTAssertNil(SquadPhotoStore.image(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    /// Finding 6: the photo cache is bounded and must give its memory back under pressure.
    func testPhotoCacheIsDroppedOnAMemoryWarning() throws {
        let id = photoID()
        try SquadPhotoStore.save(photoData(width: 400, height: 400), for: id)
        XCTAssertNotNil(SquadPhotoStore.image(for: id))
        XCTAssertNotNil(SquadPhotoStore.cachedImage(for: id), "A decoded photo stays cached")
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(SquadPhotoStore.cachedImage(for: id), "The cache is emptied on a memory warning")
        XCTAssertNotNil(SquadPhotoStore.image(for: id), "And the photo is read again on demand")
    }

    /// Finding 7: a draw path must not block on disk. `cachedImage` misses, warms off-main and says so.
    func testCachedImageMissesThenWarmsInTheBackground() throws {
        let id = photoID()
        try SquadPhotoStore.save(photoData(width: 400, height: 400), for: id)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        let warmed = expectation(forNotification: SquadPhotoStore.didWarmPhoto, object: nil)
        XCTAssertNil(SquadPhotoStore.cachedImage(for: id), "Cold cache: no blocking read")
        wait(for: [warmed], timeout: 5)
        let found = try XCTUnwrap(SquadPhotoStore.cachedImage(for: id))
        XCTAssertEqual(found.image.width, 512)
        XCTAssertFalse(found.version.isEmpty)
    }

    /// Finding 10: a yes/no question must not decode a 512 px JPEG.
    func testHasPhotoAnswersWithoutDecoding() throws {
        let id = photoID()
        XCTAssertFalse(SquadPhotoStore.hasPhoto(for: id))
        try SquadPhotoStore.save(photoData(width: 300, height: 300), for: id)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertTrue(SquadPhotoStore.hasPhoto(for: id))
        XCTAssertNil(SquadPhotoStore.cachedImage(for: id), "hasPhoto did not decode anything into the cache")
    }

    /// Finding 6: the texture key follows the stored file, not the address of a cached CGImage.
    func testPhotoVersionFollowsTheStoredFile() throws {
        let id = photoID()
        try SquadPhotoStore.save(photoData(width: 400, height: 400, color: .red), for: id)
        let first = try XCTUnwrap(SquadPhotoStore.imageWithVersion(for: id)).version
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(try XCTUnwrap(SquadPhotoStore.imageWithVersion(for: id)).version, first,
                       "Re-decoding the same file keeps the key, so the badge texture is not rebuilt")
        try SquadPhotoStore.save(photoData(width: 640, height: 480, color: .blue), for: id)
        XCTAssertNotEqual(try XCTUnwrap(SquadPhotoStore.imageWithVersion(for: id)).version, first, "A new photo is a new key")
    }

    /// Finding 5: the photo is written after the record, so a copy never leaves an orphan file.
    @MainActor
    func testDuplicateSavesThePlayerBeforeCopyingThePhoto() throws {
        let context = try makeContext()
        let player = SquadPlayer(name: "Ada Hegerberg", number: 14, position: .forward)
        context.insert(player)
        try context.save()
        addTeardownBlock { SquadPhotoStore.delete(for: player.id) }
        try SquadPhotoStore.save(photoData(width: 300, height: 300), for: player.id)

        let copy = try player.duplicate(in: context)
        addTeardownBlock { SquadPhotoStore.delete(for: copy.id) }
        XCTAssertFalse(context.hasChanges, "The copy is already stored when duplicate returns")
        XCTAssertTrue(SquadPhotoStore.hasPhoto(for: copy.id), "And its photo followed the save")
        XCTAssertEqual(copy.photoVersion, 1)

        try copy.delete(from: context)
        XCTAssertFalse(SquadPhotoStore.hasPhoto(for: copy.id), "Deleting takes the photo once the deletion is stored")
    }

    /// Finding 9: two teams in the same kit. Colour cannot tell them apart, so the half decides and
    /// "Fill remaining" still works for both sides.
    func testFillRemainingWorksWhenBothKitsShareAColour() {
        var document = BoardDocument()
        document.fieldType = .footballFull
        document.awayColorHex = document.homeColorHex
        document.elements = document.lineupElements(eleven(), formation: .f433, side: .home)
        XCTAssertEqual(document.teamElements(.home).count, 11)
        XCTAssertEqual(document.teamElements(.away).count, 0, "Home players are in home's half, not away's team")

        let filled = document.fillRemainingElements(formation: .f433, side: .away)
        XCTAssertEqual(filled.count, 11, "Away starts empty, so every slot is filled")
        document.elements += filled
        XCTAssertEqual(document.teamElements(.away).count, 11)
        XCTAssertTrue(document.fillRemainingElements(formation: .f433, side: .home).isEmpty, "Home is already complete")
        XCTAssertTrue(document.fillRemainingElements(formation: .f433, side: .away).isEmpty, "And so is away")
    }

    func testCropCentresOnTheFaceOrTheImage() {
        let size = CGSize(width: 1000, height: 2000)
        XCTAssertEqual(SquadPhotoStore.cropRect(imageSize: size, face: nil), CGRect(x: 0, y: 500, width: 1000, height: 1000))
        let face = CGRect(x: 400, y: 300, width: 200, height: 240)
        let crop = SquadPhotoStore.cropRect(imageSize: size, face: face)
        XCTAssertEqual(crop.width, crop.height)
        XCTAssertEqual(crop.width, 576, accuracy: 1, "Room for hair and shoulders around the face")
        XCTAssertTrue(crop.contains(face))
        XCTAssertEqual(crop.midX, face.midX, accuracy: 1)
        // A face near the edge keeps the crop inside the image.
        let edge = SquadPhotoStore.cropRect(imageSize: size, face: CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(edge.minX, 0)
        XCTAssertEqual(edge.minY, 0)
        XCTAssertLessThanOrEqual(edge.maxX, size.width)
    }

    func testConcurrentReadsAndSavesAreSafe() throws {
        let ids = (0..<6).map { _ in photoID() }
        for id in ids { try SquadPhotoStore.save(photoData(width: 300, height: 300), for: id) }
        let blue = photoData(width: 320, height: 240, color: .blue)
        let failures = FailureCounter()
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            let id = ids[index % ids.count]
            if index % 25 == 0 {
                do { try SquadPhotoStore.save(blue, for: id) } catch { failures.increment() }
            } else if let image = SquadPhotoStore.image(for: id) {
                if image.width != 512 || image.height != 512 { failures.increment() }
            } else {
                failures.increment()
            }
        }
        XCTAssertEqual(failures.value, 0)
        // After the dust settles every photo reads as the latest save.
        for (index, id) in ids.enumerated() where (0..<400).contains(where: { $0 % 25 == 0 && $0 % ids.count == index }) {
            let image = try XCTUnwrap(SquadPhotoStore.image(for: id))
            XCTAssertEqual(centerColor(of: image).blue, 1, accuracy: 0.1, "Latest save is visible, not a stale cached read")
        }
    }

    private func centerColor(of image: CGImage) -> (red: Double, green: Double, blue: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    func testRendererDrawsLinkedPlayerPhotoInsideTheDisc() throws {
        let id = photoID()
        try SquadPhotoStore.save(photoData(width: 600, height: 600, color: UIColor(red: 1, green: 0, blue: 0, alpha: 1)), for: id)
        var document = BoardDocument()
        document.fieldStyle = .classic
        var linked = document.element(for: snapshot("Photo", 7, .midfielder, id: id), at: BoardPoint(0.3, 0.5))
        linked.size = 2
        let plain = BoardElement(kind: .player, position: BoardPoint(0.7, 0.5), colorHex: BoardPalette.home, number: 8)
        document.elements = [linked, plain]
        let size = CGSize(width: 600, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            var renderer = BoardRenderer(document: document)
            renderer.loadsPhotosSynchronously = true
            renderer.draw(in: context.cgContext, size: size)
        }
        let cg = try XCTUnwrap(image.cgImage)
        let projection = BoardProjection(field: document.fieldType, size: size)
        func sample(_ element: BoardElement, dy: CGFloat) -> (Double, Double, Double) {
            let p = projection.point(element.position)
            let r = BoardRenderer(document: document).pointRadius(element, projection: projection)
            let cropped = cg.cropping(to: CGRect(x: p.x, y: p.y - r * dy, width: 1, height: 1))!
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
        }
        let photoPixel = sample(linked, dy: 0.4)
        XCTAssertGreaterThan(photoPixel.0, 0.7, "Photo red shows inside the linked disc")
        XCTAssertLessThan(photoPixel.2, 0.4)
        let plainPixel = sample(plain, dy: -0.72)
        XCTAssertGreaterThan(plainPixel.2, plainPixel.0, "An unlinked player keeps its team colour")
    }

    // MARK: Board integration

    func testFormationPlacementStaysInsideTheOwnHalf() {
        for field in [BoardFieldType.footballFull, .footballHalf, .futsal, .blank] {
            var document = BoardDocument()
            document.fieldType = field
            for formation in SquadFormation.allCases {
                XCTAssertEqual(formation.slots.count, 11, formation.title)
                let elements = document.lineupElements(eleven(), formation: formation)
                XCTAssertEqual(elements.count, 11, "\(field) \(formation.title)")
                XCTAssertEqual(Set(elements.map { "\($0.position.x),\($0.position.y)" }).count, 11, "No two players share a spot")
                for element in elements {
                    XCTAssertTrue((0.02...0.98).contains(element.position.x) && (0.02...0.98).contains(element.position.y), "\(field) \(formation.title) \(element.position)")
                    if field != .footballHalf { XCTAssertLessThanOrEqual(element.position.x, 0.5, "Home side stays in its own half") }
                }
                let keeper = elements.first { $0.kind == .goalkeeper }
                XCTAssertEqual(keeper?.number, 1, "The goalkeeper takes the goal")
                if field == .footballHalf {
                    XCTAssertEqual(elements.map(\.position.y).min(), keeper?.position.y, "Keeper is nearest the goal line")
                } else {
                    XCTAssertEqual(elements.map(\.position.x).min(), keeper?.position.x)
                }
            }
        }
    }

    func testLineupPrefersPlayersPositionsAndCopiesData() {
        let document = BoardDocument()
        let players = eleven().reversed().map { $0 }
        let elements = document.lineupElements(players, formation: .f442)
        let forwards = elements.filter { ($0.number ?? 0) >= 9 }
        let maxDefenderX = elements.filter { (2...5).contains($0.number ?? 0) }.map(\.position.x).max() ?? 1
        XCTAssertTrue(forwards.allSatisfy { $0.position.x > maxDefenderX }, "Forwards play ahead of defenders whatever the selection order")
        XCTAssertTrue(elements.allSatisfy { $0.playerID != nil })
        XCTAssertEqual(elements.first { $0.number == 7 }?.label, "Mid 7")
        XCTAssertEqual(elements.first { $0.number == 7 }?.colorHex, document.homeColorHex)
        XCTAssertEqual(elements.first { $0.number == 1 }?.colorHex, BoardPalette.keeper)
        // Fewer than eleven and more than eleven.
        XCTAssertEqual(document.lineupElements(Array(players.prefix(5)), formation: .f433).count, 5)
        XCTAssertEqual(document.lineupElements(players + [snapshot("Extra", 12, .forward)], formation: .f433).count, 11)
        // A kit colour overrides the side colour.
        var kit = snapshot("Kit", 3, .defender)
        kit.colorHex = BoardPalette.lime
        XCTAssertEqual(document.element(for: kit, at: .center).colorHex, BoardPalette.lime)
    }

    func testLineupIsOneUndoStepIncludingAnimatedFrames() {
        var document = BoardDocument()
        document.elements = [BoardElement(kind: .ball, position: .center)]
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        var history = BoardHistory()
        let before = document
        history.record(document)
        document.insertElements(document.lineupElements(eleven(), formation: .f4231), recordingFrame: 1)
        XCTAssertEqual(document.elements.count, 12)
        XCTAssertEqual(document.keyframes[1].poses.count, 12, "Poses are recorded in the current frame")
        XCTAssertEqual(document.elements(at: document.frameStart(1)).count, 12, "Placed players exist from that frame")

        let undone = history.undo(current: document)
        XCTAssertEqual(undone, before, "One undo removes the whole lineup")
        XCTAssertEqual(undone?.elements.count, 1)
    }

    func testSlotAssignmentFollowsPositions() {
        let picked = [snapshot("Fwd", 9, .forward), snapshot("Def", 4, .defender), snapshot("GK", 13, .goalkeeper), snapshot("Mid", 8, .midfielder)]
        let assigned = BoardDocument.assignSlots(picked, formation: .f433)
        let slots = SquadFormation.f433.slots
        XCTAssertEqual(assigned.count, 4)
        for (index, player) in assigned { XCTAssertEqual(slots[index].position, player.position, "\(player.name) sits in a \(player.position) slot") }
        XCTAssertEqual(assigned[0]?.name, "GK", "The keeper takes the keeper slot")
        // Two keepers: the second falls back to the first free slot.
        let keepers = BoardDocument.assignSlots([snapshot("A", 1, .goalkeeper), snapshot("B", 12, .goalkeeper)], formation: .f442)
        XCTAssertEqual(keepers[0]?.name, "A")
        XCTAssertTrue(keepers.contains { $0.key != 0 && $0.value.name == "B" }, "A second keeper still gets a slot")
    }

    func testFillingNumbersGenericPlayersWithoutClashes() {
        var document = BoardDocument()
        // Home already uses 2 and 3 on the board; away's 5 does not matter for home.
        document.elements = [BoardElement(kind: .player, position: BoardPoint(0.9, 0.9), colorHex: document.homeColorHex, number: 2),
                             BoardElement(kind: .player, position: BoardPoint(0.9, 0.1), colorHex: document.homeColorHex, number: 3),
                             BoardElement(kind: .player, position: BoardPoint(0.6, 0.5), colorHex: document.awayColorHex, number: 5)]
        let picked = [snapshot("Striker", 4, .forward), snapshot("Anchor", 6, .midfielder), snapshot("Wall", 5, .defender)]
        let elements = document.lineupElements(picked, formation: .f433, fillsEmptySlots: true)
        XCTAssertEqual(elements.count, 11)
        XCTAssertEqual(elements.filter { $0.playerID != nil }.count, 3)
        let numbers = elements.compactMap(\.number)
        XCTAssertEqual(numbers.count, 11)
        XCTAssertEqual(Set(numbers).count, 11, "No duplicate numbers in the lineup")
        XCTAssertTrue(Set(numbers).isDisjoint(with: [2, 3]), "Numbers already on the board are skipped")
        XCTAssertEqual(elements.first { $0.kind == .goalkeeper }?.number, 1, "The generic keeper wears 1")
        XCTAssertEqual(elements.first { $0.kind == .goalkeeper }?.colorHex, BoardPalette.keeper)
        let generic = elements.filter { $0.playerID == nil && $0.kind == .player }.compactMap(\.number)
        XCTAssertEqual(generic, [7, 8, 9, 10, 11, 12, 13], "Generic outfield players take the lowest free numbers in slot order")

        // A full team with no squad players, and without fill nothing is placed.
        XCTAssertEqual(BoardDocument().lineupElements([], formation: .f442, fillsEmptySlots: true).compactMap(\.number).sorted(), Array(1...11))
        for formation in SquadFormation.allCases { XCTAssertEqual(Set(formation.conventionalNumbers), Set(1...11), formation.title) }
        XCTAssertTrue(document.lineupElements([], formation: .f442).isEmpty)
    }

    private func role(_ name: String, _ number: Int, _ position: SquadPosition, _ role: String) -> SquadPlayerSnapshot {
        var player = snapshot(name, number, position)
        player.role = role
        return player
    }

    /// The team's right in field metres (y grows downwards): facing +x it is +y, facing -x it is -y,
    /// facing +y it is -x, facing -y it is +x. Returns how far `point` lies to the right of the centre.
    private func rightward(_ point: BoardPoint, field: BoardFieldType, side: BoardTeamSide) -> Double {
        let sign: Double = side == .home ? 1 : -1
        return field == .footballHalf ? -sign * (point.x - 0.5) : sign * (point.y - 0.5)
    }

    func testRolesSitOnTheTeamsOwnSidesForHomeAndAway() {
        // Selected in an awkward order: left before right, centre-backs unlabelled.
        let back = [role("Left", 3, .defender, "LB"), role("Centre A", 5, .defender, ""), role("Right", 2, .defender, "RB"), role("Centre B", 4, .defender, "CB")]
        let front = [role("Left wing", 11, .forward, "LW"), role("Right wing", 7, .forward, "RW"), role("Nine", 9, .forward, "ST")]
        for field in [BoardFieldType.footballFull, .footballHalf, .futsal] {
            var document = BoardDocument()
            document.fieldType = field
            for side in BoardTeamSide.allCases {
                let elements = document.lineupElements(back + front, formation: .f433, side: side, fillsEmptySlots: true)
                func spot(_ number: Int) -> BoardPoint { elements.first { $0.number == number }!.position }
                let label = "\(field) \(side)"
                XCTAssertGreaterThan(rightward(spot(2), field: field, side: side), 0.2, "\(label): the RB is on the team's right")
                XCTAssertLessThan(rightward(spot(3), field: field, side: side), -0.2, "\(label): the LB is on the team's left")
                XCTAssertEqual(rightward(spot(3), field: field, side: side), -rightward(spot(2), field: field, side: side), accuracy: 1e-9, "\(label): LB mirrors RB")
                XCTAssertGreaterThan(rightward(spot(7), field: field, side: side), 0.2, "\(label): RW on the right")
                XCTAssertLessThan(rightward(spot(11), field: field, side: side), -0.2, "\(label): LW on the left")
                XCTAssertEqual(rightward(spot(9), field: field, side: side), 0, accuracy: 1e-9, "\(label): ST central")
                XCTAssertLessThan(abs(rightward(spot(5), field: field, side: side)), 0.2, "\(label): unknown roles fill the middle")
            }
        }
        // Generic back four read 2 (RB), 5, 4, 3 (LB) from the team's right.
        let generic = BoardDocument().lineupElements([], formation: .f433, fillsEmptySlots: true)
        let backFour = generic.filter { $0.position.x > 0.1 && $0.position.x < 0.2 }.sorted { rightward($0.position, field: .footballFull, side: .home) > rightward($1.position, field: .footballFull, side: .home) }
        XCTAssertEqual(backFour.compactMap(\.number), [2, 5, 4, 3])
    }

    func testFillRemainingSkipsCoveredSlotsAndNeverMovesPlayers() {
        var document = BoardDocument()
        let full = document.lineupElements([], formation: .f433, fillsEmptySlots: true)
        // Keep the keeper exactly in place, a defender nudged by ~2 m and a striker far from any slot.
        var nudged = full[1]
        nudged.position = nudged.position.offset(dx: 1.5 / 105, dy: 1.2 / 68)
        let stray = BoardElement(kind: .player, position: BoardPoint(0.48, 0.02), colorHex: document.homeColorHex, number: 30)
        document.elements = [full[0], nudged, stray]
        let before = document.elements

        XCTAssertEqual(document.coveredSlots(formation: .f433, side: .home), [0, 1])
        let added = document.fillRemainingElements(formation: .f433, side: .home)
        XCTAssertEqual(added.count, 9, "Only the nine uncovered slots are filled")
        XCTAssertFalse(added.contains { $0.kind == .goalkeeper }, "The keeper slot is covered")
        XCTAssertTrue(Set(added.compactMap(\.number)).isDisjoint(with: [1, 2, 30]))
        document.insertElements(added, recordingFrame: nil)
        XCTAssertEqual(Array(document.elements.prefix(3)), before, "Existing players are untouched")
        XCTAssertTrue(document.fillRemainingElements(formation: .f433, side: .home).isEmpty, "A full team has nothing left to fill")
        XCTAssertEqual(document.fillRemainingElements(formation: .f433, side: .away).count, 11, "Away is a separate team")

        // One player can cover only one slot.
        var crowded = BoardDocument()
        crowded.elements = [full[2]]
        XCTAssertEqual(crowded.coveredSlots(formation: .f433, side: .home).count, 1)
    }

    func testAwayLineupIsMirroredInTheOtherHalf() {
        for field in [BoardFieldType.footballFull, .futsal, .blank, .footballHalf] {
            var document = BoardDocument()
            document.fieldType = field
            for formation in SquadFormation.allCases {
                let home = document.lineupElements(eleven(), formation: formation, side: .home, fillsEmptySlots: true)
                let away = document.lineupElements([], formation: formation, side: .away, fillsEmptySlots: true)
                XCTAssertEqual(away.count, 11)
                XCTAssertTrue(away.allSatisfy { $0.colorHex == document.awayColorHex && ($0.kind == .player || $0.kind == .goalkeeper) }, "Away players wear the away colour")
                XCTAssertEqual(document.teamElements(.away).count, 0)
                for (h, a) in zip(home, away) {
                    XCTAssertEqual(a.position.x, 1 - h.position.x, accuracy: 1e-9)
                    XCTAssertEqual(a.position.y, 1 - h.position.y, accuracy: 1e-9)
                    XCTAssertTrue((0.02...0.98).contains(a.position.x) && (0.02...0.98).contains(a.position.y))
                    if field != .footballHalf { XCTAssertGreaterThanOrEqual(a.position.x, 0.5, "\(field) \(formation.title): away stays in the other half") }
                }
                var both = document
                both.insertElements(home + away, recordingFrame: nil)
                XCTAssertEqual(both.teamElements(.home).count, 11)
                XCTAssertEqual(both.teamElements(.away).count, 11)
            }
        }
    }

    func testFillingBothTeamsUndoesInOneStepEach() {
        var document = BoardDocument()
        document.insertKeyframe(after: nil)
        document.insertKeyframe(after: 0)
        var history = BoardHistory()
        let empty = document
        history.record(document)
        document.insertElements(document.lineupElements(Array(eleven().prefix(3)), formation: .f433, side: .home, fillsEmptySlots: true), recordingFrame: 1)
        let homeOnly = document
        history.record(document)
        document.insertElements(document.lineupElements([], formation: .f442, side: .away, fillsEmptySlots: true), recordingFrame: 1)
        XCTAssertEqual(document.elements.count, 22)
        XCTAssertEqual(document.keyframes[1].poses.count, 22, "New players are recorded in the current stage")
        XCTAssertTrue(document.keyframes[0].poses.isEmpty, "Earlier stages are untouched")
        XCTAssertEqual(history.undo(current: document), homeOnly, "One undo removes the whole away team")
        XCTAssertEqual(history.undo(current: homeOnly), empty)
    }

    func testSquadEditsPropagateToLinkedElements() {
        let id = UUID(), deletedID = UUID()
        var document = BoardDocument()
        var linked = document.element(for: snapshot("Sam Kerr", 20, .forward, id: id), at: BoardPoint(0.4, 0.4))
        linked.size = 1.4
        let orphan = document.element(for: snapshot("Gone Player", 5, .defender, id: deletedID), at: BoardPoint(0.2, 0.2))
        let unlinked = BoardElement(kind: .player, position: .center, colorHex: document.homeColorHex, number: 3, label: "Free")
        document.elements = [linked, orphan, unlinked]

        XCTAssertFalse(document.refreshSquadLinks([id: snapshot("Sam Kerr", 20, .forward, id: id)]), "No change when nothing was edited")
        let changed = document.refreshSquadLinks([id: snapshot("Sam Mewis", 9, .goalkeeper, id: id)])
        XCTAssertTrue(changed)
        XCTAssertEqual(document.elements[0].number, 9)
        XCTAssertEqual(document.elements[0].label, "Sam Mewis")
        XCTAssertEqual(document.elements[0].kind, .goalkeeper, "Position changes carry over")
        XCTAssertEqual(document.elements[0].colorHex, BoardPalette.keeper)
        XCTAssertEqual(document.elements[0].size, 1.4, "Board-only properties are kept")
        XCTAssertEqual(document.elements[1].number, 5, "A deleted player's element keeps its number")
        XCTAssertEqual(document.elements[1].label, "Gone Player")
        XCTAssertEqual(document.elements[1].playerID, deletedID)
        XCTAssertEqual(document.elements[2], unlinked)

        document.link(unlinked.id, to: snapshot("New Link", 14, .midfielder))
        XCTAssertEqual(document.elements[2].number, 14)
        XCTAssertNotNil(document.elements[2].playerID)
        document.link(unlinked.id, to: nil)
        XCTAssertNil(document.elements[2].playerID)
        XCTAssertEqual(document.elements[2].number, 14, "Unlinking keeps the number and label")
    }

    func testOldDocumentsWithoutPlayerIDDecodeAndNewOnesRoundTrip() throws {
        let fixture = try JSONDecoder().decode(BoardDocument.self, from: Data(TacticalBoardTests.phoneBoardJSON.utf8))
        XCTAssertEqual(fixture.elements.count, 27)
        XCTAssertTrue(fixture.elements.allSatisfy { $0.playerID == nil })
        let legacy = #"{"id":"6C1A1C2E-9C49-4C0B-9E60-6B1C83E8F7A1","kind":"player","position":{"x":0.2,"y":0.3},"points":[],"colorHex":"2F80ED","number":4,"label":"","size":1,"opacity":0.3,"rotation":0,"arrowStyle":"pass","isCurved":false,"isDoubleHeaded":false,"hasBlockEnd":false,"zoneShape":"rectangle"}"#
        XCTAssertNil(try JSONDecoder().decode(BoardElement.self, from: Data(legacy.utf8)).playerID)

        var document = BoardDocument()
        document.elements = document.lineupElements(eleven(), formation: .f352)
        let decoded = try JSONDecoder().decode(BoardDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.elements.compactMap(\.playerID).count, 11)
    }

    // MARK: Migration

    /// Opens a copy of a real phone store with the Squad schema added (never the snapshot itself).
    /// Run with `TEST_RUNNER_CAMELOT_BOARD_STORE_SNAPSHOT=<folder containing default.store>`.
    @MainActor
    func testPhoneStoreSnapshotOpensWithSquadSchema() throws {
        guard let path = ProcessInfo.processInfo.environment["CAMELOT_BOARD_STORE_SNAPSHOT"] else {
            throw XCTSkip("Set TEST_RUNNER_CAMELOT_BOARD_STORE_SNAPSHOT to a folder containing default.store")
        }
        let source = URL(filePath: path, directoryHint: .isDirectory)
        let folder = FileManager.default.temporaryDirectory.appending(path: "squad-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-shm", "-wal"] {
            let file = source.appending(path: "default.store\(suffix)")
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                try FileManager.default.copyItem(at: file, to: folder.appending(path: "default.store\(suffix)"))
            }
        }
        let url = folder.appending(path: "default.store")
        do {
            let container = try ModelContainer(for: Project.self, MatchEvent.self, Recording.self, VideoComposition.self, TacticalBoard.self, SquadPlayer.self,
                                               configurations: ModelConfiguration(url: url))
            let context = ModelContext(container)
            XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<Project>()), 0, "Existing projects survive")
            let boards = try context.fetch(FetchDescriptor<TacticalBoard>())
            XCTAssertFalse(boards.isEmpty, "Existing boards survive")
            XCTAssertTrue(boards.allSatisfy { !$0.decodedDocument.elements.isEmpty }, "Board documents still decode")
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SquadPlayer>()), 0)
            context.insert(SquadPlayer(name: "Migrated", number: 4, position: .defender, team: "U12"))
            try context.save()
        }
        let reopened = try ModelContainer(for: Project.self, MatchEvent.self, Recording.self, VideoComposition.self, TacticalBoard.self, SquadPlayer.self,
                                          configurations: ModelConfiguration(url: url))
        let players = try ModelContext(reopened).fetch(FetchDescriptor<SquadPlayer>())
        XCTAssertEqual(players.map(\.name), ["Migrated"])
        XCTAssertEqual(players.first?.team, "U12")
    }

    func testNamedTeamsComeBeforePlayersWithoutATeam() {
        let teams = ["", "U12", "First team", "UITest"].sorted(by: SquadView.teamOrder)
        XCTAssertEqual(teams, ["First team", "U12", "UITest", ""], "A lone untagged player must never be the default team")
    }

    #if DEBUG
    /// The UI-test cleanup hook is the only code that deletes squad players outright, and it runs on
    /// a phone holding real players. It must match both the name prefix and the test team.
    @MainActor
    func testRemovingUITestPlayersNeverTouchesRealOnes() throws {
        let context = try makeContext()
        let real = SquadPlayer(name: "Test Player", number: 15, position: .midfielder, role: "CM", team: "")
        let realNamedLikeATest = SquadPlayer(name: "UITest Alex Moreno", number: 1, position: .goalkeeper, role: "GK", team: "First team")
        let seeded = SquadPlayer(name: SquadDebugSeeding.prefix + "Alex Moreno", number: 1, position: .goalkeeper, role: "GK", team: SquadDebugSeeding.team)
        for player in [real, realNamedLikeATest, seeded] { context.insert(player) }
        try context.save()

        SquadDebugSeeding.remove(modelContext: context)

        let remaining = try context.fetch(FetchDescriptor<SquadPlayer>()).map(\.name).sorted()
        XCTAssertEqual(remaining, ["Test Player", "UITest Alex Moreno"], "Only players in the test team are removed")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SquadPlayer>()).first(where: { $0.name == "UITest Alex Moreno" })?.team, "First team")
    }
    #endif

}

/// Minimal thread-safe counter for concurrency tests.
private final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
