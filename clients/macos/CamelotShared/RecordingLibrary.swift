import AVFoundation
import Foundation
import SwiftData

enum RecordingLibrary {
    static func prepareMediaDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    @MainActor static func reconcile(modelContext: ModelContext) async {
        await removeAbandonedExports()
        let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try? prepareMediaDirectory(folder)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let playable = files.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
        guard let recordings = try? modelContext.fetch(FetchDescriptor<Recording>()) else { return }

        for recording in recordings {
            if recording.localPath.isEmpty, recording.shareURL != nil {
                recording.uploadState = "remote"
                continue
            }
            let filename = recording.localPath.isEmpty ? "" : URL(filePath: recording.localPath).lastPathComponent
            if recording.localPath != filename { recording.localPath = filename }
            recording.uploadState = FileManager.default.fileExists(atPath: recording.fileURL.path())
                ? (recording.uploadState == "missing" ? "local" : recording.uploadState)
                : "missing"
        }

        let knownFiles = Set(recordings.map { URL(filePath: $0.localPath).lastPathComponent })
        let orphaned = playable.filter { !knownFiles.contains($0.lastPathComponent) }
        guard !orphaned.isEmpty else { try? modelContext.save(); return }

        let projects = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        let destinationProject: Project
        if projects.count == 1, let project = projects.first {
            destinationProject = project
        } else if let recovered = projects.first(where: { $0.name == "Recovered videos" }) {
            destinationProject = recovered
        } else {
            destinationProject = Project(name: "Recovered videos")
            modelContext.insert(destinationProject)
        }

        var index = recordings.filter { $0.projectID == destinationProject.id }.count
        for file in orphaned.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) ?? UUID()
            let asset = AVURLAsset(url: file)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let values = try? file.resourceValues(forKeys: [.creationDateKey])
            modelContext.insert(Recording(
                id: id,
                projectID: destinationProject.id,
                localPath: file.lastPathComponent,
                duration: duration.isFinite ? duration : 0,
                segmentIndex: index,
                endedReason: "recovered-from-disk",
                recordedAt: values?.creationDate ?? .now
            ))
            index += 1
        }
        try? modelContext.save()
    }

    private static func removeAbandonedExports() async {
        let folder = URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try? prepareMediaDirectory(folder)
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for file in files where file.lastPathComponent.contains(".partial.") {
                try? manager.removeItem(at: file)
            }
        }.value
    }
}

extension RecordingLibrary {
    /// Keep deletion identical whether it starts in the library or the editor.
    @MainActor static func deleteVideo(recording: Recording? = nil, composition: VideoComposition? = nil, context: ModelContext) throws {
        var files: [URL] = []
        var edits = composition.map { [$0] } ?? []
        if let recording {
            let id = recording.id
            let events = try context.fetch(FetchDescriptor<MatchEvent>(predicate: #Predicate { $0.recordingID == id }))
            let projectID = recording.projectID
            edits += try context.fetch(FetchDescriptor<VideoComposition>(predicate: #Predicate { $0.projectID == projectID }))
                .filter { $0.decodedClips?.contains { $0.recordingID == id } == true }
            for event in events {
                event.pendingDeletion = true; event.needsSync = true; event.mutationID = UUID()
            }
            recording.pendingDeletion = true; recording.needsSync = true; recording.mutationID = UUID()
            if !recording.localPath.isEmpty { files.append(recording.fileURL) }
        }
        let folder = URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        for edit in edits {
            edit.pendingDeletion = true; edit.needsSync = true; edit.mutationID = UUID()
            files += ["mp4", "mov"].map { folder.appending(path: edit.id.uuidString).appendingPathExtension($0) }
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
        for file in files {
            // A malformed or empty legacy path can resolve to the media directory.
            // Deletion must only ever remove an individual regular file.
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
