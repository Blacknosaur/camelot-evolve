import AVFoundation
import Foundation
import SwiftData

#if DEBUG
/// Test hook: `-seedSampleVideo <path>` creates a "Weekend Match" project containing the given video
/// so UI walkthroughs can reach the editor and player without the photo picker.
/// `-removeUITestBoards` deletes tactical boards whose name starts with "UITest " (and their thumbnails),
/// so board UI tests leave no data behind on a phone with real boards. It never touches other boards.
/// `-uiTestBoards` names boards created in the Boards tab with that prefix from the start.
enum DebugSeeding {
    static let uiTestBoardPrefix = "UITest "
    /// Names used when `-seedVideoCount` asks for more than one video.
    static let extraVideoNames = ["First half", "Second half", "Warm up drills"]

    /// `-removeUITestProjects`: deletes projects named "UITest …" with their videos, events and
    /// generated clips, so multi-cam UI tests leave nothing behind on a phone with real projects.
    @MainActor static func removeUITestProjects(modelContext: ModelContext) {
        let projects = ((try? modelContext.fetch(FetchDescriptor<Project>())) ?? []).filter { $0.name.hasPrefix(uiTestBoardPrefix) }
        for project in projects {
            let id = project.id
            let recordings = (try? modelContext.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.projectID == id }))) ?? []
            for recording in recordings {
                try? FileManager.default.removeItem(at: recording.fileURL)
                modelContext.delete(recording)
            }
            for event in (try? modelContext.fetch(FetchDescriptor<MatchEvent>(predicate: #Predicate { $0.projectID == id }))) ?? [] { modelContext.delete(event) }
            for composition in (try? modelContext.fetch(FetchDescriptor<VideoComposition>(predicate: #Predicate { $0.projectID == id }))) ?? [] { modelContext.delete(composition) }
            modelContext.delete(project)
        }
        try? modelContext.save()
    }

    @MainActor static func seedIfRequested(modelContext: ModelContext) async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-removeUITestBoards") {
            let boards = (try? modelContext.fetch(FetchDescriptor<TacticalBoard>())) ?? []
            for board in boards where board.name.hasPrefix(uiTestBoardPrefix) { board.delete(from: modelContext) }
            try? modelContext.save()
        }
        if arguments.contains("-removeUITestProjects") { removeUITestProjects(modelContext: modelContext) }
        SquadDebugSeeding.run(arguments: arguments, modelContext: modelContext)
        guard let index = arguments.firstIndex(of: "-seedSampleVideo"), arguments.indices.contains(index + 1) else { return }
        // A relative path resolves inside Documents, so a file copied onto a physical device can be used.
        let argument = arguments[index + 1]
        let source = argument.hasPrefix("/") ? URL(filePath: argument) : URL.documentsDirectory.appending(path: argument)
        guard FileManager.default.fileExists(atPath: source.path()) else { return }
        func intArgument(_ name: String) -> Int? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return Int(arguments[index + 1])
        }
        func stringArgument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let eventCount = intArgument("-seedEventCount")
        // `-seedVideoCount` adds extra named videos so library search and filters have something to sift.
        let videoCount = max(1, min(6, intArgument("-seedVideoCount") ?? 1))
        // `-seedProjectName` keeps a test's videos out of the projects a real user already owns.
        let customName = stringArgument("-seedProjectName")
        let seedReason = customName.map { "seeded-\($0)" } ?? (eventCount == nil ? "seeded" : "seeded-editor")
        let projectName = customName ?? (eventCount == nil ? "Weekend Match" : "Editor stress test")
        let recordings = (try? modelContext.fetch(FetchDescriptor<Recording>())) ?? []
        guard !recordings.contains(where: { $0.endedReason == seedReason }) else { return }
        let existing = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        let project = existing.first(where: { $0.name == projectName }) ?? Project(name: projectName, opponent: "Rovers")
        if project.modelContext == nil { modelContext.insert(project) }
        do {
            let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
            try RecordingLibrary.prepareMediaDirectory(folder)
            for video in 0..<videoCount {
                let id = UUID()
                let destination = folder.appending(path: id.uuidString).appendingPathExtension(source.pathExtension)
                try FileManager.default.copyItem(at: source, to: destination)
                let duration = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? 0
                let recording = Recording(
                    id: id,
                    projectID: project.id,
                    localPath: destination.lastPathComponent,
                    name: videoCount == 1 ? "" : extraVideoNames[video % extraVideoNames.count],
                    duration: duration,
                    endedReason: seedReason
                )
                modelContext.insert(recording)
                // The first video keeps the original mix; later ones only carry shots and notes,
                // so a kind filter such as "Goal" narrows the list in a predictable way.
                let moments: [(EventKind, Double, String)]
                if let eventCount, video == 0 {
                    moments = (0..<max(1, min(2000, eventCount))).map { index in
                        (EventKind.allCases[index % EventKind.allCases.count], duration * Double(index + 1) / Double(eventCount + 1), "Moment \(index + 1)")
                    }
                } else if video == 0 {
                    moments = [(EventKind.goal, 8.0, videoCount == 1 ? "" : "Penalty kick"), (.shot, 15.0, ""), (.save, 22.0, ""), (.foul, 30.0, "")]
                } else {
                    moments = [(EventKind.shot, 10.0, "Long range effort"), (.note, 20.0, "Substitution")]
                }
                for (kind, offset, note) in moments {
                    let event = MatchEvent(projectID: project.id, recordingID: id, kind: kind.rawValue)
                    event.offsetSeconds = min(duration, offset)
                    event.note = note
                    event.preRollSeconds = kind.defaultPreRoll
                    event.postRollSeconds = kind.defaultPostRoll
                    modelContext.insert(event)
                }
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
        }
    }
}
#endif
