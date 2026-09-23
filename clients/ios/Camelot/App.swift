import SwiftData
import SwiftUI

@main
struct CamelotApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView(appState: appState)
                .environment(appState)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self, TacticalBoard.self, SquadPlayer.self])
    }
}
