import CryptoKit
import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var opponent: String
    var scheduledAt: Date
    var createdAt: Date
    var serverVersion: Int?
    var needsSync: Bool
    var mutationID: UUID = UUID()

    init(name: String, opponent: String = "", scheduledAt: Date = .now) {
        id = UUID()
        self.name = name
        self.opponent = opponent
        self.scheduledAt = scheduledAt
        createdAt = .now
        needsSync = true
        mutationID = UUID()
    }
}

@Model
final class MatchEvent {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var kind: String
    var note: String
    var occurredAt: Date
    var serverVersion: Int?
    var needsSync: Bool
    var mutationID: UUID = UUID()
    var recordingID: UUID?
    var offsetSeconds: Double = 0
    var preRollSeconds: Double = 10
    var postRollSeconds: Double = 10
    var colorHex: String = ""
    var contextRecordingIDs: String = "[]"
    var pendingDeletion: Bool = false

    init(projectID: UUID, recordingID: UUID, kind: String, note: String = "", occurredAt: Date = .now) {
        id = UUID()
        self.projectID = projectID
        self.kind = kind
        self.note = note
        self.occurredAt = occurredAt
        self.recordingID = recordingID
        needsSync = true
        mutationID = UUID()
    }
}

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var localPath: String
    var name: String = ""
    var createdAt: Date
    var duration: Double
    var needsSync: Bool
    var serverVersion: Int?
    var mutationID: UUID = UUID()
    var uploadState: String = "local"
    var uploadedBytes: Int64 = 0
    var shareURL: String?
    var pendingDeletion: Bool = false
    var segmentIndex: Int = 0
    var endedReason: String = "user"
    var recordedAt: Date = Date()
    var timezoneIdentifier: String = TimeZone.current.identifier
    var utcOffsetSeconds: Int = TimeZone.current.secondsFromGMT()
    /// Multi-cam: the session this video belongs to, the phone that shot it, and where it starts
    /// relative to the host's own recording (`multiCamOffsetSeconds`, positive = started later).
    var multiCamSessionID: UUID?
    var multiCamRole: String = ""
    var multiCamDeviceName: String = ""
    var multiCamOffsetSeconds: Double = 0
    /// Switcher program only: JSON `MultiCamSwitchTimeline`.
    var multiCamSwitches: String = ""

    var fileURL: URL {
        let filename = localPath.isEmpty ? "" : URL(filePath: localPath).lastPathComponent
        let validFilename = !["", ".", "..", "/"].contains(filename)
        return URL.documentsDirectory
            .appending(path: "Recordings", directoryHint: .isDirectory)
            .appending(path: validFilename ? filename : "\(id.uuidString).missing")
    }


    var remoteMediaURL: URL? {
        guard let shareURL, var components = URLComponents(string: shareURL) else { return nil }
        components.path = components.path.replacingOccurrences(of: "/api/watch/", with: "/api/public/media/")
        return components.url
    }

    init(id: UUID = UUID(), projectID: UUID, localPath: String, name: String = "", duration: Double = 0, segmentIndex: Int = 0, endedReason: String = "user", recordedAt: Date = .now, timezone: TimeZone = .current) {
        self.id = id
        self.projectID = projectID
        self.localPath = localPath.isEmpty ? "" : URL(filePath: localPath).lastPathComponent
        self.name = name
        createdAt = .now
        self.duration = duration
        needsSync = true
        mutationID = UUID()
        uploadState = "local"
        uploadedBytes = 0
        self.segmentIndex = segmentIndex
        self.endedReason = endedReason
        self.recordedAt = recordedAt
        timezoneIdentifier = timezone.identifier
        utcOffsetSeconds = timezone.secondsFromGMT(for: recordedAt)
    }
}

/// Values for `Recording.multiCamRole`.
enum MultiCamRecordingRole: String {
    /// The host's own full-quality video; other videos of the session are aligned to it.
    case primary
    /// A camera phone's full-quality video, pulled over after the session.
    case camera
    /// The switcher's live cut.
    case program
    /// The wide view built from the primary and a camera video.
    case stitched
}

extension Recording {
    var multiCamRecordingRole: MultiCamRecordingRole? { MultiCamRecordingRole(rawValue: multiCamRole) }
    var switchTimeline: MultiCamSwitchTimeline? {
        guard !multiCamSwitches.isEmpty, let data = multiCamSwitches.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MultiCamSwitchTimeline.self, from: data)
    }
}

@Model
final class VideoComposition {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var name: String
    var kind: String
    var createdAt: Date
    var clipManifest: String
    var aspectRatio: String = "original"
    var needsSync: Bool
    var serverVersion: Int?
    var mutationID: UUID
    var uploadState: String = "local"
    var uploadedBytes: Int64 = 0
    var shareURL: String?
    var pendingDeletion: Bool = false

    var remoteMediaURL: URL? {
        guard let shareURL, var components = URLComponents(string: shareURL) else { return nil }
        components.path = components.path.replacingOccurrences(of: "/api/watch/", with: "/api/public/media/")
        return components.url
    }

    init(projectID: UUID, name: String, kind: String, clips: [CompositionClip], aspectRatio: String = "original") {
        id = UUID(); self.projectID = projectID; self.name = name; self.kind = kind; createdAt = .now
        clipManifest = (try? String(data: JSONEncoder().encode(clips), encoding: .utf8)) ?? "[]"
        self.aspectRatio = aspectRatio
        needsSync = true; mutationID = UUID(); uploadState = "local"; uploadedBytes = 0
    }
}

extension VideoComposition {
    /// Library rows need only source ranges, never per-frame tracking or effects.
    @MainActor
    var libraryClips: [CompositionClipSummary]? {
        CompositionSummaryCache.shared.clips(id: id, manifest: clipManifest)
    }

    var decodedClips: [CompositionClip]? {
        clipManifest.data(using: .utf8).flatMap { try? JSONDecoder().decode([CompositionClip].self, from: $0) }
    }

    var renderRevision: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let manifest = (try? encoder.encode(decodedClips ?? [])) ?? Data()
        return SHA256.hash(data: manifest + Data(aspectRatio.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func invalidateRender() throws {
        let folder = URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        for ext in ["mp4", "mov"] {
            let url = folder.appending(path: id.uuidString).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path()) { try FileManager.default.removeItem(at: url) }
        }
    }

    @MainActor
    func saveEdit(clips: [CompositionClip], aspectRatio: String, name: String, context: ModelContext) throws {
        let mediaChanged = decodedClips != clips || self.aspectRatio != aspectRatio
        guard mediaChanged || self.name != name || context.hasChanges else { return }
        let manifest = String(decoding: try JSONEncoder().encode(clips), as: UTF8.self)
        // Invalidate rendered media only when footage, order, speed or crop changes.
        // The source files and the editable clip manifest remain independent of rendering.
        if mediaChanged {
            try invalidateRender()
            uploadState = "local"; uploadedBytes = 0; shareURL = nil
        }
        clipManifest = manifest; self.aspectRatio = aspectRatio; self.name = name
        needsSync = true; mutationID = UUID()
        try context.save()
    }
}

/// Decode only the fields needed for duration, events, source availability and
/// thumbnails. Large annotation and tracking payloads stay unopened until editing.
struct CompositionClipSummary: Decodable, Equatable, Sendable {
    let recordingID: UUID
    let startSeconds: Double
    let endSeconds: Double
    var rate: Double = 1
    var freezeDuration: Double?

    var playbackDuration: Double { freezeDuration ?? max(0, endSeconds - startSeconds) / max(0.25, min(4, rate)) }

    private enum CodingKeys: String, CodingKey { case recordingID, startSeconds, endSeconds, rate, freezeDuration }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recordingID = try values.decode(UUID.self, forKey: .recordingID)
        startSeconds = try values.decode(Double.self, forKey: .startSeconds)
        endSeconds = try values.decode(Double.self, forKey: .endSeconds)
        rate = try values.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        freezeDuration = try values.decodeIfPresent(Double.self, forKey: .freezeDuration)
    }
}

@MainActor
private final class CompositionSummaryCache {
    private final class Entry {
        let manifest: String
        let clips: [CompositionClipSummary]?
        init(manifest: String) {
            self.manifest = manifest
            clips = manifest.data(using: .utf8).flatMap { try? JSONDecoder().decode([CompositionClipSummary].self, from: $0) }
        }
    }
    static let shared = CompositionSummaryCache()
    private let entries = NSCache<NSUUID, Entry>()

    private init() {
        entries.countLimit = 64
        entries.totalCostLimit = 32 * 1_024 * 1_024
    }

    func clips(id: UUID, manifest: String) -> [CompositionClipSummary]? {
        if let entry = entries.object(forKey: id as NSUUID), entry.manifest == manifest { return entry.clips }
        let entry = Entry(manifest: manifest)
        entries.setObject(entry, forKey: id as NSUUID, cost: manifest.utf8.count)
        return entry.clips
    }
}

struct CompositionClip: Codable, Identifiable, Equatable {
    var id: UUID
    let recordingID: UUID
    var startSeconds: Double
    var endSeconds: Double
    var rate: Double
    var annotations: [AnalysisAnnotation] = []
    var freezeDuration: Double? = nil
    var trackingLibrary: AnalysisTrackingLibrary? = nil
    var groundCalibration: GroundCalibration? = nil

    var playbackDuration: Double { freezeDuration ?? max(0, endSeconds - startSeconds) / max(0.25, min(4, rate)) }
    var annotationRate: Double { freezeDuration == nil ? max(0.25, min(4, rate)) : 1 }
    var annotationEnd: Double { startSeconds + playbackDuration * annotationRate }

    init(id: UUID = UUID(), recordingID: UUID, startSeconds: Double, endSeconds: Double, rate: Double = 1) {
        self.id = id
        self.recordingID = recordingID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.rate = rate
    }

    private enum CodingKeys: String, CodingKey { case id, recordingID, startSeconds, endSeconds, rate, annotations, freezeDuration, trackingLibrary, groundCalibration }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        recordingID = try values.decode(UUID.self, forKey: .recordingID)
        startSeconds = try values.decode(Double.self, forKey: .startSeconds)
        endSeconds = try values.decode(Double.self, forKey: .endSeconds)
        rate = try values.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        annotations = try values.decodeIfPresent([AnalysisAnnotation].self, forKey: .annotations) ?? []
        freezeDuration = try values.decodeIfPresent(Double.self, forKey: .freezeDuration)
        trackingLibrary = try values.decodeIfPresent(AnalysisTrackingLibrary.self, forKey: .trackingLibrary)
        groundCalibration = try values.decodeIfPresent(GroundCalibration.self, forKey: .groundCalibration)
    }
}
