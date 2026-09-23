import AVFoundation
import CoreTransferable
import Photos
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The project screen owns presentation and transfer state. Menu rows only
/// request presentation: their view disappears as soon as the menu closes.
struct VideoImportModifier: ViewModifier {
    let project: Project
    @Binding var isPresented: Bool
    @Binding var isImporting: Bool
    let onImported: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @State private var selectedItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var didImport = false

    func body(content: Content) -> some View {
        content
        .photosPicker(isPresented: $isPresented, selection: $selectedItem, matching: .videos, preferredItemEncoding: .current)
        .task(id: selectedItem) {
            guard let selectedItem else { return }
            await importVideo(selectedItem)
        }
        .safeAreaInset(edge: .bottom) {
            if isImporting {
                ProgressView("Importing video…")
                    .padding().frame(maxWidth: .infinity).background(.regularMaterial)
                    .accessibilityIdentifier("project-video-import-progress")
            } else if didImport {
                HStack {
                    Label("Video imported", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { didImport = false }.labelStyle(.iconOnly)
                }.padding().background(.regularMaterial)
                    .accessibilityIdentifier("project-video-import-success")
            }
        }
        .alert("Could not import video", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    @MainActor private func importVideo(_ item: PhotosPickerItem) async {
        isImporting = true; didImport = false
        defer { isImporting = false; selectedItem = nil }
        do {
            guard let imported = try await item.loadTransferable(type: ImportedMovie.self) else { throw ImportError.unavailable }
            _ = try await VideoImporter.importMovie(at: imported.url, name: imported.name,
                photoIdentifier: item.itemIdentifier, projectID: project.id, context: modelContext)
            didImport = true; onImported()
            Task { await appState.sync(modelContext: modelContext) }
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }
}

extension View {
    func videoImporter(project: Project, isPresented: Binding<Bool>, isImporting: Binding<Bool>, onImported: @escaping () -> Void = {}) -> some View {
        modifier(VideoImportModifier(project: project, isPresented: isPresented, isImporting: isImporting, onImported: onImported))
    }
}

enum VideoImporter {
    /// Consumes an app-owned temporary copy, never the Photos original. Failed
    /// imports remove their files so reconciliation cannot recover an orphan
    /// into a different project on the next launch.
    @MainActor
    static func importMovie(at temporary: URL, name: String, photoIdentifier: String? = nil,
                            projectID: UUID, context: ModelContext,
                            directory: URL = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)) async throws -> Recording {
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: temporary)
        async let duration = asset.load(.duration)
        async let tracks = asset.loadTracks(withMediaType: .video)
        let (loadedDuration, videoTracks) = try await (duration, tracks)
        guard !videoTracks.isEmpty, loadedDuration.seconds.isFinite, loadedDuration.seconds > 0 else { throw ImportError.unavailable }
        let metadata = await originalMetadata(for: asset, photoIdentifier: photoIdentifier)
        try Task.checkCancellation()
        let recordings = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.projectID == projectID }))
        let nextIndex = (recordings.map(\.segmentIndex).max() ?? -1) + 1
        try RecordingLibrary.prepareMediaDirectory(directory)
        let id = UUID()
        let destination = directory.appending(path: id.uuidString).appendingPathExtension(temporary.pathExtension.isEmpty ? "mov" : temporary.pathExtension)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let recording = Recording(id: id, projectID: projectID, localPath: destination.lastPathComponent,
            name: name, duration: loadedDuration.seconds, segmentIndex: nextIndex, endedReason: "imported",
            recordedAt: metadata.date, timezone: metadata.timezone)
        context.insert(recording)
        do { try context.save() }
        catch {
            context.delete(recording)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return recording
    }

    private static func originalMetadata(for asset: AVAsset, photoIdentifier: String?) async -> (date: Date, timezone: TimeZone) {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let photoDate = (access == .authorized || access == .limited) ? photoIdentifier.flatMap {
            PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject?.creationDate
        } : nil
        // Missing or unsupported metadata must not reject an otherwise valid video.
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let creationItem = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierCreationDate
        ).first
        let embeddedDate = try? await creationItem?.load(.dateValue)
        let embeddedString = try? await creationItem?.load(.stringValue)
        let fallbackDate: Date?
        if let assetCreationItem = try? await asset.load(.creationDate) {
            fallbackDate = try? await assetCreationItem.load(.dateValue)
        } else {
            fallbackDate = nil
        }
        return (
            photoDate ?? embeddedDate ?? fallbackDate ?? .now,
            embeddedString.flatMap(timezoneFromCreationMetadata) ?? .current
        )
    }

    private static func timezoneFromCreationMetadata(_ value: String) -> TimeZone? {
        if value.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0) }
        let pattern = #"([+-])(\d{2}):?(\d{2})$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let signRange = Range(match.range(at: 1), in: value),
              let hourRange = Range(match.range(at: 2), in: value),
              let minuteRange = Range(match.range(at: 3), in: value),
              let hours = Int(value[hourRange]), let minutes = Int(value[minuteRange]) else { return nil }
        let sign = value[signRange] == "-" ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60))
    }
}

private struct ImportedMovie: Transferable {
    let url: URL
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: temporary)
            let filename = received.file.deletingPathExtension().lastPathComponent
            return ImportedMovie(url: temporary, name: filename.isEmpty ? "Imported video" : filename)
        }
    }
}

private enum ImportError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The selected video could not be read." }
}
