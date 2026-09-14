import AVFoundation
import Foundation
import SwiftData

#if DEBUG
/// Test hook: `-seedSampleVideo <path>` creates a "Weekend Match" project containing the given video
/// so UI walkthroughs can reach the editor and player without the photo picker.
enum DebugSeeding {
    @MainActor static func seedIfRequested(modelContext: ModelContext) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-seedSampleVideo"), arguments.indices.contains(index + 1) else { return }
        // A relative path resolves inside Documents, so a file copied onto a physical device can be used.
        let argument = arguments[index + 1]
        let source = argument.hasPrefix("/") ? URL(filePath: argument) : URL.documentsDirectory.appending(path: argument)
        guard FileManager.default.fileExists(atPath: source.path()) else { return }
        let countIndex = arguments.firstIndex(of: "-seedEventCount")
        let eventCount = countIndex.flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
        let seedReason = eventCount == nil ? "seeded" : "seeded-editor"
        let projectName = eventCount == nil ? "Weekend Match" : "Editor stress test"
        let recordings = (try? modelContext.fetch(FetchDescriptor<Recording>())) ?? []
        guard !recordings.contains(where: { $0.endedReason == seedReason }) else { return }
        let existing = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        let project = existing.first(where: { $0.name == projectName }) ?? Project(name: projectName, opponent: "Rovers")
        if project.modelContext == nil { modelContext.insert(project) }
        do {
            let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
            try RecordingLibrary.prepareMediaDirectory(folder)
            let id = UUID()
            let destination = folder.appending(path: id.uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            let duration = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? 0
            let recording = Recording(id: id, projectID: project.id, localPath: destination.lastPathComponent, duration: duration, endedReason: seedReason)
            modelContext.insert(recording)
            let moments: [(EventKind, Double)]
            if let eventCount {
                moments = (0..<max(1, min(2000, eventCount))).map { index in
                    (EventKind.allCases[index % EventKind.allCases.count], duration * Double(index + 1) / Double(eventCount + 1))
                }
            } else {
                moments = [(EventKind.goal, 8.0), (.shot, 15.0), (.save, 22.0), (.foul, 30.0)]
            }
            for (index, moment) in moments.enumerated() {
                let (kind, offset) = moment
                let event = MatchEvent(projectID: project.id, recordingID: id, kind: kind.rawValue)
                event.offsetSeconds = min(duration, offset)
                if eventCount != nil { event.note = "Moment \(index + 1)" }
                event.preRollSeconds = kind.defaultPreRoll
                event.postRollSeconds = kind.defaultPostRoll
                modelContext.insert(event)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
        }
    }
}
#endif
