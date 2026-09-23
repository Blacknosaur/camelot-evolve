import SwiftData
import SwiftUI

/// Desktop shell: a project browser in the sidebar and the selected project in
/// the detail pane. Account settings live in the standard Settings window (⌘,).
struct MainTabView: View {
    let appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Project.scheduledAt, order: .reverse) private var projects: [Project]
    @State private var selectedProjectID: UUID?
    @State private var searchText = ""
    @State private var showingNewProject = false
    @State private var editingProject: Project?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Camelot")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New project", systemImage: "plus") { showingNewProject = true }
            }
            ToolbarItem(placement: .automatic) {
                Button("Account", systemImage: "person.crop.circle") { openSettings() }
                    .help("Account and sync settings")
            }
        }
        .sheet(isPresented: $showingNewProject) { ProjectFormView(project: nil) }
        .sheet(item: $editingProject) { ProjectFormView(project: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .camelotNewProject)) { _ in showingNewProject = true }
        .task(id: appState.organizationID) {
            #if DEBUG
            if NSClassFromString("XCTestCase") != nil { return }
            await DebugSeeding.seedIfRequested(modelContext: modelContext)
            #endif
            await RecordingRecovery.recover(modelContext: modelContext)
            await RecordingLibrary.reconcile(modelContext: modelContext)
            while !Task.isCancelled {
                await appState.sync(modelContext: modelContext)
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: projects.count, initial: true) {
            if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = projects.first?.id
            }
        }
    }

    private var filteredProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projects }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.opponent.localizedCaseInsensitiveContains(query)
        }
    }

    private var sidebar: some View {
        List(selection: $selectedProjectID) {
            if filteredProjects.isEmpty {
                Text(projects.isEmpty ? "No projects yet" : "No matches")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredProjects) { project in
                    ProjectSidebarRow(project: project)
                        .tag(project.id)
                        .contextMenu {
                            Button("Edit project", systemImage: "pencil") { editingProject = project }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Projects")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search projects")
        .safeAreaInset(edge: .bottom) {
            connectionFooter
        }
    }

    private var connectionFooter: some View {
        HStack(spacing: Theme.Space.sm) {
            ConnectionBadge(state: appState.connectionState)
            Spacer(minLength: 0)
            if appState.isWorking { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var detail: some View {
        if let id = selectedProjectID, let project = projects.first(where: { $0.id == id }) {
            ProjectDetailView(project: project, appState: appState)
        } else {
            ContentUnavailableView {
                Label("No project selected", systemImage: "rectangle.stack")
            } description: {
                Text("Choose a project from the sidebar, or create one to start recording and analysing video.")
            } actions: {
                Button("Create project") { showingNewProject = true }
            }
        }
    }
}

/// Compact sidebar row: preview, name, opponent/date and counts.
private struct ProjectSidebarRow: View {
    let project: Project
    @Query private var videos: [Recording]
    @Query private var generatedVideos: [VideoComposition]
    @Query private var events: [MatchEvent]

    init(project: Project) {
        self.project = project
        let id = project.id
        _videos = Query(filter: #Predicate<Recording> { $0.projectID == id && !$0.pendingDeletion }, sort: \Recording.createdAt, order: .reverse)
        _generatedVideos = Query(filter: #Predicate<VideoComposition> { $0.projectID == id && !$0.pendingDeletion }, sort: \VideoComposition.createdAt, order: .reverse)
        _events = Query(filter: #Predicate<MatchEvent> { $0.projectID == id && !$0.pendingDeletion })
    }

    var body: some View {
        let summary = ProjectSummary(videos: videos, generatedVideos: generatedVideos, events: events)
        HStack(spacing: Theme.Space.sm) {
            VideoThumbnailView(url: summary.preview.url, seconds: summary.preview.seconds, icon: "video.fill", tint: Theme.brand)
                .frame(width: 48, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.body).lineLimit(1)
                Text(project.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if project.needsSync {
                Image(systemName: "arrow.up.circle").foregroundStyle(.orange)
                    .help("Waiting to sync")
                    .accessibilityLabel("Waiting to sync")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    let appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var storage = StorageUsage()
    @State private var showingSignOut = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: Theme.Space.lg) {
                    Text(initials)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
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

            Section("Sync") {
                LabeledContent("Status") {
                    Text(syncStatusText).foregroundStyle(.secondary)
                }
                Button {
                    Task { await appState.sync(modelContext: modelContext) }
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if appState.isWorking { ProgressView().controlSize(.small) }
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
            }

            Section("On this device") {
                LabeledContent("Original videos", value: byteCount(storage.recordings))
                LabeledContent("Rendered videos", value: byteCount(storage.exports))
                LabeledContent("Thumbnail cache", value: byteCount(storage.cache))
            }

            Section {
                Button("Sign out", role: .destructive) { showingSignOut = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .task { storage = await StorageUsage.measure() }
        .confirmationDialog("Sign out of Camelot?", isPresented: $showingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { appState.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Projects and videos stay on this Mac. Sign in again to keep syncing.")
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