import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Sets up a board from a coach's description with Apple's on-device model. The model never writes
/// the board itself: it calls the tools below, which change a `BoardAssistantDraft`, and the editor
/// applies the finished draft as one undoable change. Nothing leaves the phone.
enum BoardAssistant {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let reason): reason }
        }
    }

    /// Nil when the model can be used, otherwise a sentence saying why not.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This iPhone can't run Apple Intelligence, which the assistant needs."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use the assistant."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready. Try again in a few minutes."
            case .unavailable: return "The on-device model isn't available right now."
            }
        }
        #endif
        return "The assistant needs iOS 26 or later with Apple Intelligence."
    }

    /// Runs one request and returns the model's short summary. The draft holds the result.
    static func run(_ request: String, draft: BoardAssistantDraft) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), unavailableReason == nil {
            draft.request = request
            let session = LanguageModelSession(tools: tools(for: draft), instructions: instructions(for: draft))
            do {
                let response = try await session.respond(to: request)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                throw Failure.unavailable(message(for: error))
            }
        }
        #endif
        throw Failure.unavailable(unavailableReason ?? "The assistant isn't available.")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: "That request is too long for the on-device model. Try a shorter description."
        case .guardrailViolation, .refusal: "The assistant couldn't handle that request. Try rephrasing it as a football setup."
        case .unsupportedLanguageOrLocale: "The assistant doesn't support this language yet. Try English."
        case .rateLimited, .concurrentRequests: "The assistant is busy. Try again in a moment."
        default: "The assistant couldn't finish that setup. Try again or describe it differently."
        }
    }
    #endif

    static func instructions(for draft: BoardAssistantDraft) -> String {
        """
        You set up a football tactics board for a coach using the tools. Pick the tool that matches \
        the request: placeFormation for team shapes, drill for training exercises, setPiece for \
        corners, free kicks, penalties, throw-ins, goal kicks and kick-offs, markZone to shade an \
        area, drawMovement for passes, runs and dribbles. Our team is "home" and attacks the \
        opponents' goal. Only use placeFormation when the coach asks for a formation or team shape. \
        Call each tool once per thing asked; don't repeat a call. Then reply with \
        one short sentence saying what you set up.
        """
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    static func tools(for draft: BoardAssistantDraft) -> [any Tool] {
        [FormationTool(draft: draft), DrillTool(draft: draft), SetPieceTool(draft: draft), ZoneTool(draft: draft), MovementTool(draft: draft)]
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct FormationTool: Tool {
    let draft: BoardAssistantDraft
    let name = "placeFormation"
    let description = "Places a full team of 11, keeper included, in a formation in its own half."
    @Generable struct Arguments {
        @Guide(description: "Which team", .anyOf(["home", "away"]))
        var team: String
        @Guide(description: "Formation", .anyOf(["4-3-3", "4-4-2", "4-2-3-1", "3-5-2", "3-4-3"]))
        var formation: String
    }
    func call(arguments: Arguments) async throws -> String { draft.placeFormation(arguments.formation, team: arguments.team) }
}

@available(iOS 26.0, *)
struct DrillTool: Tool {
    let draft: BoardAssistantDraft
    let name = "drill"
    let description = "Sets up a training exercise."
    @Generable struct Arguments {
        @Guide(description: "Exercise", .anyOf(["rondo", "possession square", "small-sided game", "attack vs defence"]))
        var kind: String
        @Guide(description: "Our players", .range(1...10))
        var attackers: Int
        @Guide(description: "Opponents", .range(0...8))
        var defenders: Int
        @Guide(description: "Size in metres, if given")
        var size: Double?
    }
    func call(arguments: Arguments) async throws -> String {
        draft.drill(arguments.kind, attackers: arguments.attackers, defenders: arguments.defenders, size: arguments.size)
    }
}

@available(iOS 26.0, *)
struct SetPieceTool: Tool {
    let draft: BoardAssistantDraft
    let name = "setPiece"
    let description = "Sets up a set piece for our team."
    @Generable struct Arguments {
        @Guide(description: "Set piece", .anyOf(["corner", "free kick", "penalty", "throw-in", "goal kick", "kick-off"]))
        var kind: String
        @Guide(description: "Side of the pitch", .anyOf(["left", "right"]))
        var side: String
    }
    func call(arguments: Arguments) async throws -> String { draft.setPiece(arguments.kind, side: arguments.side) }
}

@available(iOS 26.0, *)
struct ZoneTool: Tool {
    let draft: BoardAssistantDraft
    let name = "markZone"
    let description = "Shades an area, e.g. where to press."
    @Generable struct Arguments {
        @Guide(description: "Area", .anyOf(["left wing", "right wing", "centre", "left half-space", "right half-space", "our box", "their box", "our half", "their half", "final third", "middle third"]))
        var area: String
        @Guide(description: "Short label")
        var label: String?
    }
    func call(arguments: Arguments) async throws -> String { draft.markZone(arguments.area, label: arguments.label) }
}

@available(iOS 26.0, *)
struct MovementTool: Tool {
    let draft: BoardAssistantDraft
    let name = "drawMovement"
    let description = "Draws a pass, run or dribble between listed players (home 2) or spots."
    @Generable struct Arguments {
        @Guide(description: "Kind", .anyOf(["pass", "run", "dribble"]))
        var kind: String
        @Guide(description: "Player (home 2) or spot: near post, far post, penalty spot, edge of the box, left wing, right wing, centre circle")
        var from: String
        @Guide(description: "Player or spot")
        var to: String
    }
    func call(arguments: Arguments) async throws -> String { draft.drawMovement(arguments.kind, from: arguments.from, to: arguments.to) }
}
#endif
