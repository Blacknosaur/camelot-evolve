import SwiftUI

struct RootView: View {
    let appState: AppState

    var body: some View {
        Group {
            if appState.isAuthenticated {
                MainTabView(appState: appState)
            } else {
                OnboardingView(appState: appState)
            }
        }
        .modifier(AppAppearanceModifier())
        .task {
            if NSClassFromString("XCTestCase") != nil { return }
            await appState.checkConnection()
        }
    }
}
