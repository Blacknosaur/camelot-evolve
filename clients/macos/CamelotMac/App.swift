import SwiftData
import SwiftUI

@main
struct CamelotMacApp: App {
    @State private var appState = AppState()
    @State private var windows = AppWindows()

    var body: some Scene {
        WindowGroup {
            RootView(appState: appState)
                .environment(appState)
                .environment(windows)
                .frame(minWidth: 720, minHeight: 480)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self])
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    NotificationCenter.default.post(name: .camelotNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Sync now") {
                    NotificationCenter.default.post(name: .camelotSyncNow, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(appState: appState)
                .environment(appState)
                .environment(windows)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self])

        Window("Camera", id: AppWindowID.camera) {
            CameraWindow()
                .environment(appState)
                .environment(windows)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self])
        .defaultSize(width: 1180, height: 780)

        Window("Editor", id: AppWindowID.editor) {
            EditorWindow()
                .environment(appState)
                .environment(windows)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self])
        .defaultSize(width: 1280, height: 840)

        Window("Video", id: AppWindowID.composition) {
            CompositionWindow()
                .environment(appState)
                .environment(windows)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self])
        .defaultSize(width: 1100, height: 760)

        Window("Video", id: AppWindowID.remote) {
            RemoteVideoWindow()
                .environment(appState)
                .environment(windows)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self])
        .defaultSize(width: 1100, height: 760)

        Window("Analysis", id: AppWindowID.analysis) {
            AnalysisWindow()
                .environment(appState)
                .environment(windows)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self])
        .defaultSize(width: 1280, height: 840)

        Window("Align field", id: AppWindowID.calibration) {
            CalibrationWindow()
                .environment(appState)
                .environment(windows)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self])
        .defaultSize(width: 1000, height: 700)

        Window("Place field", id: AppWindowID.fieldPlacement) {
            FieldPlacementWindow()
                .environment(appState)
                .environment(windows)
        }
        .modelContainer(for: [Project.self, MatchEvent.self, Recording.self, VideoComposition.self])
        .defaultSize(width: 1000, height: 720)
    }
}

extension Notification.Name {
    static let camelotSyncNow = Notification.Name("camelot.syncNow")
    static let camelotNewProject = Notification.Name("camelot.newProject")
}