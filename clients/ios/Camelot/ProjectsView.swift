import SwiftData
import SwiftUI

struct ProjectsView: View {
    let appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.scheduledAt, order: .reverse) private var projects: [Project]
    @State private var showingNewProject = false
    @State private var joiningSession = false
    @State private var editingProject: Project?
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            AdaptiveLayout { layout in
                Group {
                    if projects.isEmpty {
                        emptyState
                    } else if filteredProjects.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else if layout.gridColumns > 1 {
                        projectGrid(columns: layout.gridColumns)
                    } else {
                        projectList
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Projects")
            .searchable(text: $searchText, prompt: "Search by name or opponent")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New project", systemImage: "plus") { showingNewProject = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Join a session", systemImage: "dot.radiowaves.left.and.right") { joiningSession = true }
                        .accessibilityIdentifier("projects-join-session")
                }
            }
            .fullScreenCover(isPresented: $joiningSession) {
                MultiCamJoinView(controller: MultiCamPeerController(appState: appState, modelContext: modelContext)) { joiningSession = false }
            }
            .navigationDestination(for: UUID.self) { id in
                if let project = projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project, appState: appState)
                }
            }
            .sheet(isPresented: $showingNewProject) { ProjectFormView(project: nil) }
            .sheet(item: $editingProject) { ProjectFormView(project: $0) }
        }
    }

    private var filteredProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projects }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.opponent.localizedCaseInsensitiveContains(query)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No projects yet", systemImage: "sportscourt")
        } description: {
            Text("A project is one match or training session. It is saved on this phone immediately and syncs later.")
        } actions: {
            Button("Create project") { showingNewProject = true }.buttonStyle(.borderedProminent)
        }
    }

    private var projectList: some View {
        List {
            ForEach(filteredProjects) { project in
                NavigationLink(value: project.id) {
                    ProjectRow(project: project)
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .swipeActions(edge: .trailing) {
                    Button("Edit", systemImage: "pencil") { editingProject = project }.tint(Theme.brand)
                }
                .contextMenu { Button("Edit project", systemImage: "pencil") { editingProject = project } }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func projectGrid(columns: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.lg), count: columns), spacing: Theme.Space.lg) {
                ForEach(filteredProjects) { project in
                    NavigationLink(value: project.id) {
                        ProjectCard(project: project)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Edit project", systemImage: "pencil") { editingProject = project } }
                }
            }
            .padding(Theme.Space.lg)
        }
    }
}

// MARK: - Shared project summary

/// Loads the counts and preview frame for a project once, shared by list rows, grid cards and the record picker.
@MainActor
struct ProjectSummary {
    let videoCount: Int
    let highlightCount: Int
    let eventCount: Int
    let preview: (url: URL?, seconds: Double)

    init(videos: [Recording], generatedVideos: [VideoComposition], events: [MatchEvent]) {
        videoCount = videos.count
        highlightCount = generatedVideos.count
        eventCount = events.count
        preview = Self.preview(videos: videos, generatedVideos: generatedVideos)
    }

    private static func preview(videos: [Recording], generatedVideos: [VideoComposition]) -> (url: URL?, seconds: Double) {
        let availableVideos = videos.filter { FileManager.default.fileExists(atPath: $0.fileURL.path()) }
        if let generated = generatedVideos.first,
           generated.createdAt > (availableVideos.first?.createdAt ?? .distantPast) {
            if let exported = CompositionRenderer.existingExportURL(id: generated.id) { return (exported, 0.5) }
            if let remote = generated.remoteMediaURL { return (remote, 0.5) }
            if let clips = generated.libraryClips,
               let clip = clips.first(where: { clip in availableVideos.contains { $0.id == clip.recordingID } }),
               let source = availableVideos.first(where: { $0.id == clip.recordingID }) {
                return (source.fileURL, min(max(0, clip.startSeconds + 0.25), max(0, source.duration - 0.1)))
            }
        }
        if let latest = availableVideos.first {
            return (latest.fileURL, min(1, max(0, latest.duration / 2)))
        }
        if let remote = videos.first?.remoteMediaURL { return (remote, 0.5) }
        return (nil, 0)
    }
}

extension Project {
    var subtitle: String {
        opponent.isEmpty ? friendlyDate(scheduledAt) : "vs \(opponent) · \(friendlyDate(scheduledAt))"
    }
}

/// Compact row for phone lists.
private struct ProjectRow: View {
    let project: Project
    @Query private var videos: [Recording]
    @Query private var generatedVideos: [VideoComposition]
    @Query private var events: [MatchEvent]

    init(project: Project) {
        self.project = project
        let projectID = project.id
        _videos = Query(filter: #Predicate<Recording> { $0.projectID == projectID && !$0.pendingDeletion }, sort: \Recording.createdAt, order: .reverse)
        _generatedVideos = Query(filter: #Predicate<VideoComposition> { $0.projectID == projectID && !$0.pendingDeletion }, sort: \VideoComposition.createdAt, order: .reverse)
        _events = Query(filter: #Predicate<MatchEvent> { $0.projectID == projectID && !$0.pendingDeletion })
    }

    var body: some View {
        let summary = ProjectSummary(videos: videos, generatedVideos: generatedVideos, events: events)
        HStack(spacing: Theme.Space.md) {
            VideoThumbnailView(url: summary.preview.url, seconds: summary.preview.seconds, icon: "video.fill", tint: Theme.brand)
                .frame(width: 96, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.headline).lineLimit(1)
                Text(project.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: Theme.Space.md) {
                    MetaLabel("\(summary.videoCount + summary.highlightCount)", symbol: "play.rectangle.fill")
                    MetaLabel("\(summary.eventCount)", symbol: "flag.fill")
                }
            }
            Spacer(minLength: 0)
            if project.needsSync {
                Image(systemName: "arrow.up.circle").foregroundStyle(.orange).accessibilityLabel("Waiting to sync")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Larger card for grids on iPad and landscape.
private struct ProjectCard: View {
    let project: Project
    @Query private var videos: [Recording]
    @Query private var generatedVideos: [VideoComposition]
    @Query private var events: [MatchEvent]

    init(project: Project) {
        self.project = project
        let projectID = project.id
        _videos = Query(filter: #Predicate<Recording> { $0.projectID == projectID && !$0.pendingDeletion }, sort: \Recording.createdAt, order: .reverse)
        _generatedVideos = Query(filter: #Predicate<VideoComposition> { $0.projectID == projectID && !$0.pendingDeletion }, sort: \VideoComposition.createdAt, order: .reverse)
        _events = Query(filter: #Predicate<MatchEvent> { $0.projectID == projectID && !$0.pendingDeletion })
    }

    var body: some View {
        let summary = ProjectSummary(videos: videos, generatedVideos: generatedVideos, events: events)
        VStack(alignment: .leading, spacing: 0) {
            VideoThumbnailView(url: summary.preview.url, seconds: summary.preview.seconds, icon: "video.fill", tint: Theme.brand)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if project.needsSync {
                        StatusPill(text: "Waiting to sync", tint: .orange, symbol: "arrow.up.circle")
                            .background(.regularMaterial, in: .capsule)
                            .padding(Theme.Space.sm)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(project.name).font(.headline).lineLimit(1)
                Text(project.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: Theme.Space.md) {
                    MetaLabel("\(summary.videoCount + summary.highlightCount) videos", symbol: "play.rectangle.fill")
                    MetaLabel("\(summary.eventCount) events", symbol: "flag.fill")
                }
            }
            .padding(Theme.Space.md)
        }
        .card()
        .contentShape(.rect(cornerRadius: Theme.Radius.large))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Create / edit form

struct ProjectFormView: View {
    let project: Project?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name: String
    @State private var opponent: String
    @State private var date: Date
    @FocusState private var nameFocused: Bool

    init(project: Project?) {
        self.project = project
        _name = State(initialValue: project?.name ?? "")
        _opponent = State(initialValue: project?.opponent ?? "")
        _date = State(initialValue: project?.scheduledAt ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.next)
                    TextField("Opponent (optional)", text: $opponent)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Match")
                } footer: {
                    Text("Use the opponent field for matches. Leave it empty for training sessions.")
                }
                Section("When") {
                    DatePicker("Date", selection: $date)
                }
            }
            .navigationTitle(project == nil ? "New project" : "Edit project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(project == nil ? "Create" : "Save", action: save)
                        .bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if project == nil { nameFocused = true } }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedOpponent = opponent.trimmingCharacters(in: .whitespaces)
        if let project {
            project.name = trimmedName
            project.opponent = trimmedOpponent
            project.scheduledAt = date
            project.needsSync = true
            project.mutationID = UUID()
        } else {
            modelContext.insert(Project(name: trimmedName, opponent: trimmedOpponent, scheduledAt: date))
        }
        try? modelContext.save()
        dismiss()
    }
}
