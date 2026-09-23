import AVFoundation
import Foundation
import SwiftData

struct CaptureJournal: Codable, Sendable {
    let recordingID: UUID
    let projectID: UUID
    let startedAt: Date
    let timezoneIdentifier: String
    let mode: String
    var promoted: Bool
    var mediaPath: String
}

private struct RecoveredCapture: Sendable {
    let journal: CaptureJournal
    let duration: Double
    let destination: URL
}

enum RecordingRecovery {
    static var directory: URL { URL.documentsDirectory.appending(path: "RecordingRecovery", directoryHint: .isDirectory) }
    static func mediaURL(for id: UUID) -> URL { directory.appending(path: id.uuidString).appendingPathExtension("mov") }
    static func journalURL(for id: UUID) -> URL { directory.appending(path: id.uuidString).appendingPathExtension("json") }

    static func create(recordingID: UUID, projectID: UUID, mode: String, promoted: Bool = false) throws -> CaptureJournal {
        try RecordingLibrary.prepareMediaDirectory(directory)
        let journal = CaptureJournal(recordingID: recordingID, projectID: projectID, startedAt: .now, timezoneIdentifier: TimeZone.current.identifier, mode: mode, promoted: promoted, mediaPath: mediaURL(for: recordingID).path())
        try JSONEncoder().encode(journal).write(to: journalURL(for: recordingID), options: .atomic)
        return journal
    }

    static func markPromoted(_ journal: CaptureJournal) throws {
        var value = journal; value.promoted = true
        try JSONEncoder().encode(value).write(to: journalURL(for: value.recordingID), options: .atomic)
    }

    static func removeJournal(for id: UUID) { try? FileManager.default.removeItem(at: journalURL(for: id)) }
    static func discard(_ journal: CaptureJournal) {
        try? FileManager.default.removeItem(at: URL(filePath: journal.mediaPath))
        removeJournal(for: journal.recordingID)
    }

    @MainActor static func recover(modelContext: ModelContext) async {
        let journals = await Task.detached(priority: .utility) { () -> [CaptureJournal] in
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
            return files.filter { $0.pathExtension == "json" }.compactMap {
                guard let data = try? Data(contentsOf: $0) else { return nil }
                return try? JSONDecoder().decode(CaptureJournal.self, from: data)
            }
        }.value
        let recovered = await withTaskGroup(of: RecoveredCapture?.self) { group in
            for journal in journals {
                group.addTask { await prepareRecovery(journal) }
            }
            var values: [RecoveredCapture] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        guard !recovered.isEmpty else { return }
        do {
            var existing = try modelContext.fetch(FetchDescriptor<Recording>())
            for item in recovered {
                guard !existing.contains(where: { $0.id == item.journal.recordingID }) else {
                    removeJournal(for: item.journal.recordingID)
                    continue
                }
                let index = existing.lazy.filter { $0.projectID == item.journal.projectID }.count
                let recording = Recording(
                    id: item.journal.recordingID,
                    projectID: item.journal.projectID,
                    localPath: item.destination.lastPathComponent,
                    duration: item.duration,
                    segmentIndex: index,
                    endedReason: "recovered-after-crash",
                    recordedAt: item.journal.startedAt,
                    timezone: TimeZone(identifier: item.journal.timezoneIdentifier) ?? .current
                )
                modelContext.insert(recording)
                existing.append(recording)
            }
            try modelContext.save()
            recovered.forEach { removeJournal(for: $0.journal.recordingID) }
        } catch {
            // Keep journals and finalized media in place so the next launch retries.
        }
    }

    private nonisolated static func prepareRecovery(_ journal: CaptureJournal) async -> RecoveredCapture? {
        if journal.mode == "rolling" && !journal.promoted { discard(journal); return nil }
        let manager = FileManager.default
        let source = URL(filePath: journal.mediaPath)
        let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        let destination = folder.appending(path: journal.recordingID.uuidString).appendingPathExtension("mov")
        let candidate = manager.fileExists(atPath: source.path()) ? source : destination
        guard manager.fileExists(atPath: candidate.path()),
              ((try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            discard(journal); return nil
        }
        let asset = AVURLAsset(url: candidate)
        guard (try? await asset.load(.isPlayable)) == true,
              let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0.05,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            try? manager.removeItem(at: candidate)
            removeJournal(for: journal.recordingID)
            return nil
        }
        do {
            try RecordingLibrary.prepareMediaDirectory(folder)
            if candidate != destination {
                if manager.fileExists(atPath: destination.path()) { try manager.removeItem(at: candidate) }
                else { try manager.moveItem(at: candidate, to: destination) }
            }
            return RecoveredCapture(journal: journal, duration: duration, destination: destination)
        } catch {
            return nil
        }
    }
}
