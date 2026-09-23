import XCTest
import SwiftData
import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
@testable import Camelot

/// Isolated import fixtures: no Photos selection or writes to user projects.
final class VideoImporterTests: XCTestCase {
    @MainActor
    func testImportsVideoIntoTheSelectedProjectAndAllowsTheSameVideoAgain() async throws {
        let container = try ModelContainer(for: Recording.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let projectID = UUID(), otherProjectID = UUID()
        context.insert(Recording(projectID: projectID, localPath: "existing.mp4", segmentIndex: 7))
        context.insert(Recording(projectID: otherProjectID, localPath: "other.mp4", segmentIndex: 50))
        try context.save()
        let folder = FileManager.default.temporaryDirectory.appending(path: "import-test-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sequence-test", withExtension: "mp4"))
        var importedIDs: Set<UUID> = []
        for index in 0..<2 {
            let staged = folder.appending(path: "staged-\(index).mp4")
            try FileManager.default.copyItem(at: fixture, to: staged)
            let imported = try await VideoImporter.importMovie(at: staged, name: "Soccer clip", projectID: projectID,
                context: context, directory: folder.appending(path: "Recordings"))
            importedIDs.insert(imported.id)
            XCTAssertEqual(imported.projectID, projectID)
            XCTAssertEqual(imported.name, "Soccer clip")
            XCTAssertEqual(imported.endedReason, "imported")
            XCTAssertEqual(imported.segmentIndex, 8 + index)
            XCTAssertGreaterThan(imported.duration, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "Recordings/\(imported.localPath)").path))
        }
        XCTAssertEqual(importedIDs.count, 2)
        let saved = try ModelContext(container).fetch(FetchDescriptor<Recording>())
        XCTAssertEqual(saved.filter { $0.projectID == projectID }.count, 3)
        XCTAssertEqual(saved.filter { $0.projectID == otherProjectID }.count, 1)
    }

    @MainActor
    func testUnreadableVideoDoesNotLeaveARecordingOrOrphanedFile() async throws {
        let container = try ModelContainer(for: Recording.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let folder = FileManager.default.temporaryDirectory.appending(path: "invalid-import-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let staged = folder.appending(path: "invalid.mov")
        try Data("not a video".utf8).write(to: staged)
        do {
            _ = try await VideoImporter.importMovie(at: staged, name: "Invalid", projectID: UUID(), context: container.mainContext,
                                                   directory: folder.appending(path: "Recordings"))
            XCTFail("Unreadable media must report an error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Recording>()).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @MainActor
    func testCancelledImportCleansUpItsTemporaryFile() async throws {
        let container = try ModelContainer(for: Recording.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let staged = FileManager.default.temporaryDirectory.appending(path: "cancel-import-\(UUID()).mov")
        try Data().write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let task = Task { @MainActor in
            _ = try await VideoImporter.importMovie(at: staged, name: "Cancelled", projectID: UUID(), context: container.mainContext)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("The import must stop") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    @MainActor
    func testPhotoPickerPresentsAndCanReopenFromPersistentHostOnPhone() async throws {
        let container = try ModelContainer(for: Project.self, Recording.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "Import presentation fixture")
        container.mainContext.insert(project)
        let appState = AppState(), state = ImportPresentationState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack {
            Text("Import presentation fixture")
                .videoImporter(project: project,
                    isPresented: Binding(get: { state.picker }, set: { state.picker = $0 }),
                    isImporting: Binding(get: { state.importing }, set: { state.importing = $0 }))
        }.modelContainer(container).environment(appState))
        defer { host.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        func photoPicker(in controller: UIViewController) -> PHPickerViewController? {
            if let picker = controller as? PHPickerViewController { return picker }
            for child in controller.children {
                if let picker = photoPicker(in: child) { return picker }
            }
            if let presented = controller.presentedViewController { return photoPicker(in: presented) }
            return nil
        }
        for pass in 0..<2 {
            state.picker = true
            for _ in 0..<50 {
                if photoPicker(in: host) != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            _ = try XCTUnwrap(photoPicker(in: host), "The system photo picker must open on pass \(pass)")
            try await Task.sleep(for: .milliseconds(350))
            if pass == 0, ProcessInfo.processInfo.environment["CAMELOT_CAPTURE_IMPORT_PICKER"] == "1" {
                // Photos uses remote content that drawHierarchy cannot capture.
                // Allow a native device screenshot during explicit visual review.
                print("IMPORT_PICKER_READY")
                try await Task.sleep(for: .seconds(8))
            }
            state.picker = false
            for _ in 0..<20 {
                if host.presentedViewController == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(host.presentedViewController)
        }
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Recording>()).isEmpty, "Presentation checks must not import user media")
    }
}

@Observable @MainActor
private final class ImportPresentationState {
    var picker = false
    var importing = false
}

final class ProjectVideoFilterTests: XCTestCase {
    /// Read-only profiling of the user's fixture. Never seeds or saves projects.
    @MainActor
    func testOpeningExistingStressProject() async throws {
        let url = URL.applicationSupportDirectory.appending(path: "default.store")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Run on the fixture phone")
        let schema = Schema([Project.self, MatchEvent.self, Recording.self, VideoComposition.self, TacticalBoard.self, SquadPlayer.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, allowsSave: false))
        let context = ModelContext(container); context.autosaveEnabled = false
        let project = try XCTUnwrap(context.fetch(FetchDescriptor<Project>()).first { $0.name == "Editor stress test" })
        let id = project.id
        let videos = try context.fetch(FetchDescriptor<VideoComposition>(predicate: #Predicate { $0.projectID == id && !$0.pendingDeletion }))
        let start = CFAbsoluteTimeGetCurrent()
        var clipCount = 0
        for video in videos { clipCount += video.decodedClips?.count ?? 0 }
        print("PROJECT_OPEN full_decode_ms=\((CFAbsoluteTimeGetCurrent() - start) * 1000) edits=\(videos.count) clips=\(clipCount) manifest_bytes=\(videos.reduce(0) { $0 + $1.clipManifest.utf8.count })")
        let summaryStart = CFAbsoluteTimeGetCurrent()
        let summaries = try videos.map { try JSONDecoder().decode([CompositionClipSummary].self, from: Data($0.clipManifest.utf8)) }
        print("PROJECT_OPEN summary_decode_ms=\((CFAbsoluteTimeGetCurrent() - summaryStart) * 1000)")
        XCTAssertEqual(summaries.reduce(0) { $0 + $1.count }, clipCount)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let appState = AppState()
        defer { window.isHidden = true; previous?.makeKey() }
        for pass in 0..<2 {
            let started = CFAbsoluteTimeGetCurrent()
            let host = UIHostingController(rootView: NavigationStack {
                ProjectDetailView(project: project, appState: appState)
            }.modelContainer(container).environment(appState))
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            print("PROJECT_OPEN pass=\(pass) initial_layout_ms=\((CFAbsoluteTimeGetCurrent() - started) * 1000)")
            try await Task.sleep(for: .seconds(1))
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = "Project opening pass \(pass)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertFalse(context.hasChanges, "Opening a project must not modify user data")
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    @MainActor
    func testLibrarySummaryPreservesTimingAndUpdatesWhenAnEditChanges() throws {
        let recordingID = UUID()
        var normal = CompositionClip(recordingID: recordingID, startSeconds: 2, endSeconds: 8, rate: 2)
        var freeze = normal; freeze.freezeDuration = 5
        let video = VideoComposition(projectID: UUID(), name: "Summary fixture", kind: "edit", clips: [normal, freeze])
        let summary = try XCTUnwrap(video.libraryClips)
        XCTAssertEqual(summary.map(\.recordingID), [recordingID, recordingID])
        XCTAssertEqual(summary.map(\.playbackDuration), [3, 5])
        XCTAssertEqual(summary, video.libraryClips, "Reopening reuses the summary")
        let mutationID = video.mutationID
        normal.endSeconds = 12
        video.clipManifest = String(decoding: try JSONEncoder().encode([normal]), as: UTF8.self)
        XCTAssertEqual(video.mutationID, mutationID)
        XCTAssertEqual(video.libraryClips?.first?.endSeconds, 12, "A changed manifest invalidates cached metadata even before a save")
        XCTAssertEqual(video.libraryClips?.first?.playbackDuration, normal.playbackDuration)
        video.clipManifest = "invalid"
        XCTAssertNil(video.libraryClips)
        video.clipManifest = "[]"
        XCTAssertEqual(video.libraryClips, [])
    }

    @MainActor
    func testLibrarySummaryReadsLegacyRangesWithoutMaterializingTrackingData() throws {
        let id = UUID()
        let video = VideoComposition(projectID: UUID(), name: "Legacy fixture", kind: "edit", clips: [])
        // Unknown nested edit data must not be required to display a library row.
        video.clipManifest = """
        [{"recordingID":"\(id)","startSeconds":3,"endSeconds":9,
          "annotations":{"futureFormat":true},"trackingLibrary":{"samples":[1,2,3]}}]
        """
        let summary = try XCTUnwrap(video.libraryClips?.first)
        XCTAssertEqual(summary.recordingID, id)
        XCTAssertEqual(summary.playbackDuration, 6)
        XCTAssertEqual(summary.rate, 1)
        XCTAssertNil(summary.freezeDuration)
    }

    private let firstHalf = VideoSearchIndex(
        id: "source-1",
        title: "First half",
        subtitle: "Recorded with Camelot",
        eventKinds: ["Goal", "Shot", "Save"],
        eventNotes: ["Penalty kick by Alvarez", "", "Diving stop"]
    )
    private let secondHalf = VideoSearchIndex(
        id: "source-2",
        title: "Second half",
        subtitle: "Imported video",
        eventKinds: ["Shot", "Note"],
        eventNotes: ["Long range effort", "Substitution"]
    )
    private let warmUp = VideoSearchIndex(
        id: "generated-3",
        title: "Warm up drills",
        subtitle: "Today, 10:09",
        eventKinds: [],
        eventNotes: []
    )

    private var all: [VideoSearchIndex] { [firstHalf, secondHalf, warmUp] }

    private func ids(query: String = "", kinds: Set<String> = []) -> [String] {
        ProjectVideoFilter.matching(all, query: query, kinds: kinds).map(\.id)
    }

    func testNoQueryAndNoKindsKeepsEveryVideo() {
        XCTAssertEqual(ids(), ["source-1", "source-2", "generated-3"])
        XCTAssertEqual(ids(query: "   "), ["source-1", "source-2", "generated-3"])
    }

    func testTitleMatchIsCaseAndAccentInsensitive() {
        XCTAssertEqual(ids(query: "second"), ["source-2"])
        XCTAssertEqual(ids(query: "WARM"), ["generated-3"])
        XCTAssertEqual(ids(query: "Álvarez"), ["source-1"], "Accents fold on both sides")
    }

    func testDescriptionMatch() {
        XCTAssertEqual(ids(query: "imported"), ["source-2"])
        XCTAssertEqual(ids(query: "recorded with camelot"), ["source-1"])
    }

    func testEventKindTextMatch() {
        XCTAssertEqual(ids(query: "goal"), ["source-1"])
        XCTAssertEqual(ids(query: "shot"), ["source-1", "source-2"])
    }

    func testEventNoteMatch() {
        XCTAssertEqual(ids(query: "penalty"), ["source-1"])
        XCTAssertEqual(ids(query: "substitution"), ["source-2"])
    }

    func testAllWordsMustMatchSomewhere() {
        XCTAssertEqual(ids(query: "half penalty"), ["source-1"])
        XCTAssertEqual(ids(query: "half substitution"), ["source-2"])
        XCTAssertTrue(ids(query: "penalty substitution").isEmpty)
    }

    func testKindFilterKeepsVideosContainingAnySelectedKind() {
        XCTAssertEqual(ids(kinds: ["Goal"]), ["source-1"])
        XCTAssertEqual(ids(kinds: ["Note"]), ["source-2"])
        XCTAssertEqual(ids(kinds: ["Goal", "Note"]), ["source-1", "source-2"], "Several kinds mean any of them")
        XCTAssertTrue(ids(kinds: ["Card"]).isEmpty)
    }

    func testSearchAndKindFilterCombine() {
        XCTAssertEqual(ids(query: "half", kinds: ["Shot"]), ["source-1", "source-2"])
        XCTAssertEqual(ids(query: "second", kinds: ["Shot"]), ["source-2"])
        XCTAssertTrue(ids(query: "warm", kinds: ["Goal"]).isEmpty, "A video without the kind never matches")
    }

    func testNoMatchesReturnsEmpty() {
        XCTAssertTrue(ids(query: "corner").isEmpty)
        XCTAssertTrue(ids(query: "first half", kinds: ["Note"]).isEmpty)
    }

    /// The stress-test shape: 240 events over 12 videos. Building the index and filtering it
    /// stays far below a frame, so there is nothing to cache between keystrokes.
    func testFilteringStaysFastOnAStressProject() {
        let kinds = EventKind.allCases.map(\.rawValue)
        let indexes = (0..<12).map { video in
            VideoSearchIndex(
                id: "source-\(video)",
                title: "Clip \(video)",
                subtitle: "Recorded with Camelot",
                eventKinds: (0..<20).map { kinds[$0 % kinds.count] },
                eventNotes: (0..<20).map { "Moment \(video * 20 + $0)" }
            )
        }
        let start = Date()
        for _ in 0..<50 { _ = ProjectVideoFilter.matching(indexes, query: "moment 5", kinds: ["Goal"]) }
        let perKeystroke = Date().timeIntervalSince(start) / 50
        XCTAssertLessThan(perKeystroke, 0.016, "Filtering 240 events must cost well under one frame")
    }
}
