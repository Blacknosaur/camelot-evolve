import XCTest
@testable import Camelot

final class BoardAssistantTests: XCTestCase {
    func testFormationsFillEachTeamsOwnHalf() {
        let draft = BoardAssistantDraft(document: BoardDocument())
        draft.placeFormation("4-3-3", team: "home")
        draft.placeFormation("4-4-2", team: "away")
        let document = draft.document
        XCTAssertEqual(document.teamElements(.home).count, 11)
        XCTAssertEqual(document.teamElements(.away).count, 11)
        XCTAssertTrue(document.teamElements(.home).allSatisfy { $0.position.x < 0.5 }, "Home defends along = 0")
        XCTAssertTrue(document.teamElements(.away).allSatisfy { $0.position.x > 0.5 })
        XCTAssertEqual(draft.changes.count, 2)
    }

    func testUnknownFormationChangesNothing() {
        let draft = BoardAssistantDraft(document: BoardDocument())
        XCTAssertTrue(draft.placeFormation("2-3-5", team: "home").hasPrefix("Unknown formation"))
        XCTAssertTrue(draft.document.elements.isEmpty)
        XCTAssertTrue(draft.changes.isEmpty)
    }

    func testMetresMapToTheBoardOnFullAndHalfPitches() {
        let full = BoardAssistantDraft.point(along: 52.5, across: 0, on: .footballFull)
        XCTAssertEqual(full.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(full.y, 0, accuracy: 0.001)
        // Half pitch: our goal at the top (y = 0), our left touchline at x = 1.
        let half = BoardAssistantDraft.point(along: 0, across: 0, on: .footballHalf)
        XCTAssertEqual(half.x, 1, accuracy: 0.001)
        XCTAssertEqual(half.y, 0, accuracy: 0.001)
        XCTAssertEqual(BoardAssistantDraft.size(of: .footballHalf).along, 52.5)
    }

    func testPlayersTakeTheNextNumbersAndLabels() {
        let draft = BoardAssistantDraft(document: BoardDocument())
        draft.addPlayers(team: "home", [.init(along: 30, across: 20), .init(along: 30, across: 48, label: "Winger")])
        draft.addPlayers(team: "keeper", [.init(along: 2, across: 34)])
        let players = draft.document.elements
        XCTAssertEqual(players.filter { $0.kind == .player }.compactMap(\.number), [1, 2])
        XCTAssertEqual(players.first { $0.label == "Winger" }?.number, 2)
        XCTAssertEqual(players.filter { $0.kind == .goalkeeper }.count, 1)
    }

    func testGridAndMovementsConnectToPlayers() throws {
        let draft = BoardAssistantDraft(document: BoardDocument())
        draft.addPlayers(team: "home", [.init(along: 20, across: 20), .init(along: 40, across: 30)])
        draft.drawMovement("pass", fromAlong: 20.5, fromAcross: 20, toAlong: 39, toAcross: 31)
        draft.drawMovement("run", fromAlong: 40, fromAcross: 30, toAlong: 60, toAcross: 30)
        draft.addGrid(centreAlong: 52.5, centreAcross: 34, length: 12, width: 12, label: "Rondo")
        let elements = draft.document.elements
        let pass = try XCTUnwrap(elements.first { $0.kind == .line && $0.lineStyle == .pass })
        XCTAssertNotNil(pass.startAttachment); XCTAssertNotNil(pass.endAttachment, "Both ends snap to the nearby players")
        let run = try XCTUnwrap(elements.first { $0.kind == .line && $0.lineStyle == .run })
        XCTAssertNotNil(run.startAttachment); XCTAssertNil(run.endAttachment, "Open space stays unattached")
        XCTAssertEqual(elements.filter { $0.kind == .cone }.count, 4)
        XCTAssertEqual(elements.filter { $0.kind == .zone }.count, 1)
        XCTAssertTrue(elements.contains { $0.kind == .text && $0.label == "Rondo" })
    }

    func testUnknownEquipmentIsReportedBack() {
        let draft = BoardAssistantDraft(document: BoardDocument())
        XCTAssertTrue(draft.addEquipment("trampoline", at: [(along: 10, across: 10)]).hasPrefix("Unknown item"))
        XCTAssertTrue(draft.addEquipment("mini goals", at: [(along: 10, across: 10)]).hasPrefix("Done"), "Plurals still match")
    }

    func testRondoPutsAttackersOnTheEdgeAndDefendersInside() {
        let draft = BoardAssistantDraft(document: BoardDocument())
        draft.drill("rondo", attackers: 5, defenders: 2, size: 12)
        let document = draft.document
        XCTAssertEqual(document.teamElements(.home).count, 5)
        XCTAssertEqual(document.teamElements(.away).count, 2)
        XCTAssertEqual(document.elements.filter { $0.kind == .cone }.count, 4)
        XCTAssertEqual(document.elements.filter { $0.kind == .ball }.count, 1)
        for player in document.teamElements(.home) {
            let m = BoardAssistantDraft.metres(of: player.position, on: .footballFull)
            XCTAssertEqual(max(abs(m.along - 52.5), abs(m.across - 34)), 6, accuracy: 0.1, "Attackers stand on the square's edge")
        }
    }

    func testCornerAndNamedMovements() throws {
        let draft = BoardAssistantDraft(document: BoardDocument())
        draft.setPiece("corner", side: "right")
        let taker = try XCTUnwrap(draft.document.elements.first { $0.label == "Taker" })
        XCTAssertGreaterThan(taker.position.x, 0.95); XCTAssertGreaterThan(taker.position.y, 0.95, "Right corner")
        XCTAssertTrue(draft.drawMovement("pass", from: "home \(taker.number ?? 0)", to: "near post").hasPrefix("Done"))
        XCTAssertTrue(draft.drawMovement("run", from: "nowhere", to: "near post").hasPrefix("Unknown start"))
        let pass = try XCTUnwrap(draft.document.elements.first { $0.kind == .line })
        XCTAssertEqual(pass.startAttachment, taker.id)
    }

    func testFormationReportsNumbersAndIsNotPlacedTwice() {
        let draft = BoardAssistantDraft(document: BoardDocument())
        XCTAssertTrue(draft.placeFormation("4-3-3", team: "home").contains("defence 2 5 4 3"))
        XCTAssertTrue(draft.placeFormation("4-3-3", team: "home").contains("already"))
        XCTAssertEqual(draft.document.teamElements(.home).count, 11)
        XCTAssertNotNil(draft.location(of: "home 9"))
    }

    func testZonesAndOtherSetPieces() {
        let draft = BoardAssistantDraft(document: BoardDocument())
        draft.markZone("their box", label: nil)
        for kind in BoardAssistantDraft.setPieces { draft.setPiece(kind, side: "left") }
        draft.drill("small-sided game", attackers: 4, defenders: 4, size: 40)
        draft.drill("attack vs defence", attackers: 3, defenders: 2, size: nil)
        XCTAssertEqual(draft.document.elements.filter { $0.kind == .zone }.count, 2)
        XCTAssertTrue(draft.document.elements.allSatisfy { (0...1).contains($0.position.x) && (0...1).contains($0.position.y) })
    }

    /// The real on-device model. Skips where Apple Intelligence is unavailable (most simulators).
    func testOnDeviceModelSetsUpTwoTeams() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The simulator reports the model available but cannot run its safety check")
        #endif
        if let reason = BoardAssistant.unavailableReason { throw XCTSkip(reason) }
        let draft = BoardAssistantDraft(document: BoardDocument())
        let summary = try await BoardAssistant.run("4-3-3 against a 4-4-2", draft: draft)
        print("ASSISTANT summary:", summary, "changes:", draft.changes)
        XCTAssertGreaterThanOrEqual(draft.document.teamElements(.home).count, 10)
        XCTAssertGreaterThanOrEqual(draft.document.teamElements(.away).count, 10)
    }
}
