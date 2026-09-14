import AVFoundation
import CoreTransferable
import Photos
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct VideoImportButton: View {
    let project: Project
    /// Shorter title for tight action rows; the accessibility label stays "Import video".
    var compact = false
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @State private var selectedItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        PhotosPicker(selection: $selectedItem, matching: .videos) {
            Label(compact ? "Import" : "Import video", systemImage: "square.and.arrow.down")
        }
        .accessibilityLabel("Import video")
        .disabled(isImporting)
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            Task { await importVideo(item) }
        }
        .alert("Could not import video", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    @MainActor private func importVideo(_ item: PhotosPickerItem) async {
        isImporting = true
        defer { isImporting = false; selectedItem = nil }
        do {
            guard let imported = try await item.loadTransferable(type: ImportedMovie.self) else { throw ImportError.unavailable }
            let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
            try RecordingLibrary.prepareMediaDirectory(folder)
            let id = UUID()
            let destination = folder.appending(path: id.uuidString).appendingPathExtension(imported.url.pathExtension.isEmpty ? "mov" : imported.url.pathExtension)
            try FileManager.default.moveItem(at: imported.url, to: destination)
            let asset = AVURLAsset(url: destination)
            async let loadedDuration = asset.load(.duration)
            async let loadedMetadata = originalMetadata(for: asset, photoIdentifier: item.itemIdentifier)
            let (assetDuration, metadata) = try await (loadedDuration, loadedMetadata)
            let recordings = try modelContext.fetch(FetchDescriptor<Recording>()).filter { $0.projectID == project.id }
            modelContext.insert(Recording(
                id: id,
                projectID: project.id,
                localPath: destination.lastPathComponent,
                duration: assetDuration.seconds.isFinite ? assetDuration.seconds : 0,
                segmentIndex: recordings.count,
                endedReason: "imported",
                recordedAt: metadata.date,
                timezone: metadata.timezone
            ))
            try modelContext.save()
            Task { await appState.sync(modelContext: modelContext) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func originalMetadata(for asset: AVAsset, photoIdentifier: String?) async throws -> (date: Date, timezone: TimeZone) {
        let photoDate = photoIdentifier.flatMap {
            PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject?.creationDate
        }
        let metadata = try await asset.load(.commonMetadata)
        let creationItem = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierCreationDate
        ).first
        let embeddedDate = try await creationItem?.load(.dateValue)
        let embeddedString = try await creationItem?.load(.stringValue)
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

    private func timezoneFromCreationMetadata(_ value: String) -> TimeZone? {
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
