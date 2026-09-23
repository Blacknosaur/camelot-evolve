import SwiftUI

/// Camelot Camera: a lightweight companion (iOS 16+) that turns any spare phone into a second
/// camera or an event remote for a session hosted by the main Camelot app.
@main
struct CamelotCameraApp: App {
    var body: some Scene {
        WindowGroup { CompanionRootView() }
    }
}

struct CompanionRootView: View {
    @AppStorage("companion.name") private var name = ""
    @AppStorage("companion.deviceID") private var storedDeviceID = ""
    /// Bumped to rebuild the join screen with a fresh controller after leaving a session.
    @State private var generation = 0

    var body: some View {
        MultiCamJoinView(controller: MultiCamPeerController(displayName: displayName, deviceID: deviceID, store: CompanionStore())) {
            generation += 1
        }
        .id(generation)
        .safeAreaInset(edge: .top) { nameField }
    }

    private var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Camera · \(UIDevice.current.model)" : name }

    private var deviceID: UUID {
        if let id = UUID(uuidString: storedDeviceID) { return id }
        let id = UUID(); storedDeviceID = id.uuidString; return id
    }

    /// Shown only while looking for a session; the host sees this name on its previews.
    @ViewBuilder private var nameField: some View {
        if generation >= 0 {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                TextField("This phone's name (shown to the host)", text: $name)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .onSubmit { generation += 1 }
            }
            .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
            .background(Color(.systemGroupedBackground))
            .accessibilityIdentifier("companion-name")
        }
    }
}

/// The companion keeps every recorded file under Documents/Recordings, visible in the Files app,
/// so nothing is lost if a transfer fails.
struct CompanionStore: MultiCamPeerStore {
    @MainActor func save(_ finished: MultiCamCaptureEngine.Finished, projectID: UUID, projectName: String, sessionID: UUID, deviceName: String) throws -> URL {
        let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = finished.startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space)).replacingOccurrences(of: ":", with: "-")
        let safeProject = projectName.replacingOccurrences(of: "/", with: "-")
        let destination = folder.appending(path: "\(safeProject.isEmpty ? "Session" : safeProject) \(stamp) \(finished.id.uuidString.prefix(8)).mov")
        try FileManager.default.moveItem(at: finished.url, to: destination)
        return destination
    }
}
