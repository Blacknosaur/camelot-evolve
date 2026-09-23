import SwiftData
import SwiftUI

struct MainTabView: View {
    let appState: AppState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            ProjectsView(appState: appState)
                .tabItem { Label("Projects", systemImage: "rectangle.stack.fill") }
            TacticalBoardsView()
                .tabItem { Label("Boards", systemImage: "sportscourt.fill") }
            SquadView()
                .tabItem { Label("Squad", systemImage: "person.3.fill") }
            SettingsView(appState: appState)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .tint(Theme.brand)
        .task(id: appState.organizationID) {
            // Hosted unit tests own their fixtures. Do not recover or sync those
            // transient files into the user's library while tests are running.
            if NSClassFromString("XCTestCase") != nil { return }
            #if DEBUG
            await DebugSeeding.seedIfRequested(modelContext: modelContext)
            #endif
            await RecordingRecovery.recover(modelContext: modelContext)
            await RecordingLibrary.reconcile(modelContext: modelContext)
            while !Task.isCancelled {
                await appState.sync(modelContext: modelContext)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

struct SettingsView: View {
    let appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var storage = StorageUsage()
    @State private var showingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Theme.Space.lg) {
                        Text(initials)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Theme.brand.gradient, in: .circle)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appState.userName).font(.headline)
                            Text(appState.organizationName ?? "Offline workspace")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ConnectionBadge(state: appState.connectionState)
                    }
                    .padding(.vertical, Theme.Space.xs)
                    .accessibilityElement(children: .combine)
                }

                Section("Appearance") {
                    AppearancePicker()
                }

                Section {
                    LabeledContent("Status") {
                        Text(syncStatusText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    Button {
                        Task { await appState.sync(modelContext: modelContext) }
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if appState.isWorking { ProgressView() }
                        }
                    }
                    .disabled(appState.isWorking)
                    if appState.connectionState == .offline {
                        Button("Test API connection", systemImage: "network") {
                            Task { await appState.checkConnection() }
                        }
                        if let issue = appState.connectionIssue {
                            Text(issue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text(appState.organizationID == nil
                         ? "Create or join an organization to sync. Everything stays saved on this device."
                         : "Camelot syncs metadata every 15 seconds and uploads videos in the background.")
                }

                Section {
                    LabeledContent("Original videos", value: byteCount(storage.recordings))
                    LabeledContent("Rendered videos", value: byteCount(storage.exports))
                    LabeledContent("Thumbnail cache", value: byteCount(storage.cache))
                } header: {
                    Text("On this device")
                } footer: {
                    Text("Videos are never included in iCloud backups. Delete a video from its project to free space.")
                }

                Section {
                    Button("Sign out", role: .destructive) { showingSignOut = true }
                }
            }
            .navigationTitle("Account")
            .refreshable {
                await appState.checkConnection()
                storage = await StorageUsage.measure()
            }
            .task { storage = await StorageUsage.measure() }
            .confirmationDialog("Sign out of Camelot?", isPresented: $showingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { appState.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Projects and videos stay on this device. Sign in again to keep syncing.")
            }
        }
    }

    private var initials: String {
        let parts = appState.userName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "C" : letters.uppercased()
    }

    private var syncStatusText: String {
        if appState.isWorking { return "Syncing…" }
        return appState.syncMessage ?? "Idle"
    }
}

private struct StorageUsage: Sendable {
    var recordings: Int64 = 0
    var exports: Int64 = 0
    var cache: Int64 = 0

    static func measure() async -> StorageUsage {
        await Task.detached(priority: .utility) {
            let documents = URL.documentsDirectory
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            return StorageUsage(
                recordings: size(of: documents.appending(path: "Recordings")),
                exports: size(of: documents.appending(path: "Exports")),
                cache: size(of: caches.appending(path: "VideoThumbnails"))
            )
        }.value
    }

    private static func size(of folder: URL) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
