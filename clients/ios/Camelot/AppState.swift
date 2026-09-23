import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppState {
    enum ConnectionState { case checking, online, offline }

    private let api = APIClient()
    private let defaults = UserDefaults.standard
    var connectionState: ConnectionState = .checking
    var connectionIssue: String?
    var isWorking = false
    var errorMessage: String?
    var isAuthenticated: Bool
    var userName: String
    var organizationID: String?
    var organizationName: String?
    var syncMessage: String?
    var isCapturing = false
    let deviceID: UUID

    init() {
        if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") {
            defaults.removeObject(forKey: "authenticated")
            defaults.removeObject(forKey: "organizationID")
            defaults.removeObject(forKey: "organizationName")
        }
        isAuthenticated = defaults.bool(forKey: "authenticated")
        userName = defaults.string(forKey: "userName") ?? "Coach"
        organizationID = defaults.string(forKey: "organizationID")
        organizationName = defaults.string(forKey: "organizationName")
        if let stored = defaults.string(forKey: "deviceID"), let id = UUID(uuidString: stored) {
            deviceID = id
        } else {
            let id = UUID()
            deviceID = id
            defaults.set(id.uuidString, forKey: "deviceID")
        }
    }

    func checkConnection() async {
        connectionState = .checking
        connectionIssue = nil
        do {
            try await api.health()
            connectionState = .online
            connectionIssue = nil
        } catch {
            connectionState = .offline
            connectionIssue = error.localizedDescription
        }
    }

    func createAccount(name: String, email: String, password: String, organization: String) async {
        await authenticate {
            try await self.api.signUp(name: name, email: email, password: password)
            let org = try await self.api.createOrganization(name: organization)
            self.persistSession(name: name, organization: org)
        }
    }

    func signIn(email: String, password: String) async {
        await authenticate {
            try await self.api.signIn(email: email, password: password)
            let organization = try await self.api.listOrganizations().first
            self.persistSession(name: email, organization: organization)
        }
    }

    func continueOffline(name: String) {
        persistSession(name: name.isEmpty ? "Coach" : name, organization: nil)
        connectionState = .offline
    }

    func sync(modelContext: ModelContext) async {
        guard !isWorking else { return }
        guard !isCapturing else {
            syncMessage = "Sync paused while recording."
            return
        }
        guard let organizationID else {
            syncMessage = "Create or join an organization to sync. Your work remains saved locally."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let projects = try modelContext.fetch(FetchDescriptor<Project>()).filter(\.needsSync)
            let events = try modelContext.fetch(FetchDescriptor<MatchEvent>()).filter(\.needsSync)
            let recordings = try modelContext.fetch(FetchDescriptor<Recording>()).filter(\.needsSync)
            let compositions = try modelContext.fetch(FetchDescriptor<VideoComposition>()).filter(\.needsSync)
            let formatter = ISO8601DateFormatter()
            var mutations = projects.map {
                SyncMutation(mutationId: $0.mutationID, entityId: $0.id, entityType: "project", baseVersion: $0.serverVersion, parentId: nil,
                             payload: ["name": $0.name, "opponent": $0.opponent, "scheduledAt": formatter.string(from: $0.scheduledAt)], clientTimestamp: formatter.string(from: .now))
            }
            mutations += events.map {
                SyncMutation(mutationId: $0.mutationID, entityId: $0.id, entityType: "event", operation: $0.pendingDeletion ? "delete" : "upsert", baseVersion: $0.serverVersion, parentId: $0.projectID,
                             payload: ["kind": $0.kind, "color": $0.colorHex, "note": $0.note, "occurredAt": formatter.string(from: $0.occurredAt), "recordingId": $0.recordingID?.uuidString ?? "", "contextRecordingIds": $0.contextRecordingIDs, "offsetSeconds": String($0.offsetSeconds), "preRollSeconds": String($0.preRollSeconds), "postRollSeconds": String($0.postRollSeconds)], clientTimestamp: formatter.string(from: .now))
            }
            mutations += recordings.map {
                SyncMutation(mutationId: $0.mutationID, entityId: $0.id, entityType: "media", operation: $0.pendingDeletion ? "delete" : "upsert", baseVersion: $0.serverVersion, parentId: $0.projectID,
                             payload: ["name": $0.name, "state": $0.uploadState, "shareURL": $0.shareURL ?? "", "createdAt": formatter.string(from: $0.createdAt), "recordedAt": formatter.string(from: $0.recordedAt), "timezoneIdentifier": $0.timezoneIdentifier, "utcOffsetSeconds": String($0.utcOffsetSeconds), "duration": String($0.duration), "segmentIndex": String($0.segmentIndex), "endedReason": $0.endedReason], clientTimestamp: formatter.string(from: .now))
            }
            mutations += compositions.map {
                SyncMutation(mutationId: $0.mutationID, entityId: $0.id, entityType: "summary", operation: $0.pendingDeletion ? "delete" : "upsert", baseVersion: $0.serverVersion, parentId: $0.projectID,
                             payload: ["name": $0.name, "kind": $0.kind, "clips": $0.clipManifest, "aspectRatio": $0.aspectRatio, "shareURL": $0.shareURL ?? "", "uploadState": $0.uploadState], clientTimestamp: formatter.string(from: .now))
            }
            if !mutations.isEmpty {
                for batch in mutations.chunked(into: 100) {
                    let response = try await api.push(organizationID: organizationID, deviceID: deviceID, mutations: batch)
                    for result in response.results where result.status == "applied" || result.status == "duplicate" {
                        if let item = projects.first(where: { $0.mutationID == result.mutationId }) { item.needsSync = false; item.serverVersion = result.version }
                        if let item = events.first(where: { $0.mutationID == result.mutationId }) {
                            if item.pendingDeletion { modelContext.delete(item) }
                            else { item.needsSync = false; item.serverVersion = result.version }
                        }
                        if let item = recordings.first(where: { $0.mutationID == result.mutationId }) {
                            if item.pendingDeletion { modelContext.delete(item) }
                            else { item.needsSync = false; item.serverVersion = result.version }
                        }
                        if let item = compositions.first(where: { $0.mutationID == result.mutationId }) {
                            if item.pendingDeletion { modelContext.delete(item) }
                            else { item.needsSync = false; item.serverVersion = result.version }
                        }
                    }
                    for result in response.results where result.status == "conflict" {
                        guard let version = result.serverVersion else { continue }
                        if let item = projects.first(where: { $0.mutationID == result.mutationId }) { item.serverVersion = version; item.mutationID = UUID() }
                        if let item = events.first(where: { $0.mutationID == result.mutationId }) { item.serverVersion = version; item.mutationID = UUID() }
                        if let item = recordings.first(where: { $0.mutationID == result.mutationId }) { item.serverVersion = version; item.mutationID = UUID() }
                        if let item = compositions.first(where: { $0.mutationID == result.mutationId }) { item.serverVersion = version; item.mutationID = UUID() }
                    }
                }
            }
            try await pullChanges(organizationID: organizationID, modelContext: modelContext)
            try await uploadCompositions(organizationID: organizationID, modelContext: modelContext)
            try await uploadRecordings(organizationID: organizationID, modelContext: modelContext)
            try modelContext.save()
            connectionState = .online
            connectionIssue = nil
            syncMessage = "Synced successfully."
        } catch {
            if isCapturing {
                syncMessage = "Sync paused while recording."
            } else {
                connectionState = .offline
                connectionIssue = error.localizedDescription
                syncMessage = error.localizedDescription
            }
        }
    }

    private func uploadRecordings(organizationID: String, modelContext: ModelContext) async throws {
        let recordings = try modelContext.fetch(FetchDescriptor<Recording>()).filter {
            !$0.pendingDeletion && !$0.localPath.isEmpty && $0.uploadState != "uploaded" && $0.uploadState != "remote"
        }
        for recording in recordings {
            let fileURL = recording.fileURL
            guard FileManager.default.fileExists(atPath: fileURL.path()) else {
                recording.uploadState = "missing"
                continue
            }
            recording.uploadState = "uploading"
            try modelContext.save()
            do {
                var lastPersistedBytes = recording.uploadedBytes
                recording.uploadedBytes = try await api.uploadVideo(organizationID: organizationID, mediaID: recording.id, fileURL: fileURL) { bytes in
                    recording.uploadedBytes = bytes
                    if bytes - lastPersistedBytes >= 32 * 1_024 * 1_024 {
                        try? modelContext.save()
                        lastPersistedBytes = bytes
                    }
                } shouldContinue: { !self.isCapturing }
                recording.uploadState = "uploaded"
                if recording.shareURL == nil {
                    recording.shareURL = try await api.createShare(organizationID: organizationID, mediaID: recording.id).absoluteString
                }
                recording.needsSync = true
                recording.mutationID = UUID()
                try modelContext.save()
            } catch {
                recording.uploadState = "paused"
                try modelContext.save()
                throw error
            }
        }
    }

    private func uploadCompositions(organizationID: String, modelContext: ModelContext) async throws {
        let compositions = try modelContext.fetch(FetchDescriptor<VideoComposition>()).filter { !$0.pendingDeletion && $0.uploadState != "uploaded" }
        for composition in compositions {
            guard let fileURL = CompositionRenderer.existingExportURL(id: composition.id) else { continue }
            let revision = composition.renderRevision
            composition.uploadState = "uploading"
            try modelContext.save()
            do {
                var lastPersistedBytes = composition.uploadedBytes
                composition.uploadedBytes = try await api.uploadVideo(
                    organizationID: organizationID,
                    mediaID: composition.id,
                    fileURL: fileURL,
                    revision: revision
                ) { bytes in
                    guard composition.renderRevision == revision else { return }
                    composition.uploadedBytes = bytes
                    if bytes - lastPersistedBytes >= 32 * 1_024 * 1_024 {
                        try? modelContext.save()
                        lastPersistedBytes = bytes
                    }
                } shouldContinue: { !self.isCapturing && composition.renderRevision == revision }
                guard composition.renderRevision == revision else { composition.uploadedBytes = 0; continue }
                composition.uploadState = "uploaded"
                if composition.shareURL == nil {
                    composition.shareURL = try await api.createShare(organizationID: organizationID, mediaID: composition.id).absoluteString
                }
                composition.needsSync = true
                composition.mutationID = UUID()
                try modelContext.save()
            } catch {
                guard composition.renderRevision == revision else { composition.uploadedBytes = 0; continue }
                composition.uploadState = "paused"
                try modelContext.save()
                throw error
            }
        }
    }

    private func pullChanges(organizationID: String, modelContext: ModelContext) async throws {
        var cursor = defaults.string(forKey: "syncCursor.\(organizationID)") ?? "0"
        let formatter = ISO8601DateFormatter()
        repeat {
            let page = try await api.pull(organizationID: organizationID, cursor: cursor)
            let projects = try modelContext.fetch(FetchDescriptor<Project>())
            let events = try modelContext.fetch(FetchDescriptor<MatchEvent>())
            let recordings = try modelContext.fetch(FetchDescriptor<Recording>())
            let compositions = try modelContext.fetch(FetchDescriptor<VideoComposition>())
            for change in page.changes {
                if change.operation == "delete" {
                    if change.entityType == "event", let item = events.first(where: { $0.id == change.entityId }) { modelContext.delete(item) }
                    if change.entityType == "project", let item = projects.first(where: { $0.id == change.entityId }) { modelContext.delete(item) }
                    if (change.entityType == "summary" || change.entityType == "composition"), let item = compositions.first(where: { $0.id == change.entityId }) { modelContext.delete(item) }
                    if change.entityType == "media", let item = recordings.first(where: { $0.id == change.entityId }) { modelContext.delete(item) }
                    continue
                }
                switch change.entityType {
                case "project":
                    let item = projects.first(where: { $0.id == change.entityId }) ?? Project(name: change.payload["name"] ?? "Untitled")
                    if item.modelContext == nil { modelContext.insert(item) }
                    item.name = change.payload["name"] ?? item.name
                    item.opponent = change.payload["opponent"] ?? item.opponent
                    if let date = change.payload["scheduledAt"].flatMap(formatter.date) { item.scheduledAt = date }
                    item.serverVersion = change.version
                    item.needsSync = false
                case "event":
                    guard let projectID = change.parentId else { continue }
                    guard let recordingID = change.payload["recordingId"].flatMap(UUID.init(uuidString:)) else { continue }
                    let item = events.first(where: { $0.id == change.entityId }) ?? MatchEvent(projectID: projectID, recordingID: recordingID, kind: change.payload["kind"] ?? "Note")
                    if item.modelContext == nil { modelContext.insert(item) }
                    item.kind = change.payload["kind"] ?? item.kind
                    item.note = change.payload["note"] ?? item.note
                    if let date = change.payload["occurredAt"].flatMap(formatter.date) { item.occurredAt = date }
                    item.recordingID = change.payload["recordingId"].flatMap(UUID.init(uuidString:))
                    item.offsetSeconds = Double(change.payload["offsetSeconds"] ?? "") ?? item.offsetSeconds
                    item.preRollSeconds = Double(change.payload["preRollSeconds"] ?? "") ?? item.preRollSeconds
                    item.postRollSeconds = Double(change.payload["postRollSeconds"] ?? "") ?? item.postRollSeconds
                    item.colorHex = change.payload["color"] ?? item.colorHex
                    item.contextRecordingIDs = change.payload["contextRecordingIds"] ?? item.contextRecordingIDs
                    item.serverVersion = change.version
                    item.needsSync = false
                case "summary", "composition":
                    guard let projectID = change.parentId else { continue }
                    let clips = (change.payload["clips"]?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([CompositionClip].self, from: $0) } ?? []
                    let item = compositions.first(where: { $0.id == change.entityId }) ?? VideoComposition(projectID: projectID, name: change.payload["name"] ?? "Edit", kind: change.payload["kind"] ?? "custom", clips: clips)
                    if item.modelContext == nil { modelContext.insert(item) }
                    item.name = change.payload["name"] ?? item.name
                    item.kind = change.payload["kind"] ?? item.kind
                    if item.decodedClips != clips || item.aspectRatio != (change.payload["aspectRatio"] ?? item.aspectRatio) {
                        try item.invalidateRender()
                    }
                    item.clipManifest = change.payload["clips"] ?? item.clipManifest
                    item.aspectRatio = change.payload["aspectRatio"] ?? item.aspectRatio
                    item.shareURL = change.payload["shareURL"].flatMap { $0.isEmpty ? nil : $0 }
                    item.uploadState = change.payload["uploadState"] ?? item.uploadState
                    item.serverVersion = change.version
                    item.needsSync = false
                case "media":
                    guard let projectID = change.parentId else { continue }
                    let item = recordings.first(where: { $0.id == change.entityId }) ?? Recording(
                        id: change.entityId,
                        projectID: projectID,
                        localPath: "",
                        name: change.payload["name"] ?? "",
                        duration: Double(change.payload["duration"] ?? "") ?? 0,
                        segmentIndex: Int(change.payload["segmentIndex"] ?? "") ?? 0,
                        endedReason: change.payload["endedReason"] ?? "remote",
                        recordedAt: change.payload["recordedAt"].flatMap(formatter.date) ?? .now,
                        timezone: TimeZone(identifier: change.payload["timezoneIdentifier"] ?? "") ?? .current
                    )
                    if item.modelContext == nil { modelContext.insert(item) }
                    item.name = change.payload["name"] ?? item.name
                    item.duration = Double(change.payload["duration"] ?? "") ?? item.duration
                    item.segmentIndex = Int(change.payload["segmentIndex"] ?? "") ?? item.segmentIndex
                    item.endedReason = change.payload["endedReason"] ?? item.endedReason
                    if let date = change.payload["recordedAt"].flatMap(formatter.date) { item.recordedAt = date }
                    item.timezoneIdentifier = change.payload["timezoneIdentifier"] ?? item.timezoneIdentifier
                    item.utcOffsetSeconds = Int(change.payload["utcOffsetSeconds"] ?? "") ?? item.utcOffsetSeconds
                    item.shareURL = change.payload["shareURL"].flatMap { $0.isEmpty ? nil : $0 }
                    item.uploadState = item.localPath.isEmpty && item.shareURL != nil ? "remote" : (change.payload["state"] ?? item.uploadState)
                    item.serverVersion = change.version
                    item.needsSync = false
                default: break
                }
            }
            try modelContext.save()
            cursor = page.cursor
            defaults.set(cursor, forKey: "syncCursor.\(organizationID)")
            if !page.hasMore { break }
        } while true
    }

    func signOut() {
        isAuthenticated = false
        organizationID = nil
        organizationName = nil
        defaults.removeObject(forKey: "authenticated")
        defaults.removeObject(forKey: "organizationID")
        defaults.removeObject(forKey: "organizationName")
    }

    private func authenticate(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        do {
            try await work()
            connectionState = .online
            connectionIssue = nil
        } catch {
            errorMessage = error.localizedDescription
            connectionState = .offline
            connectionIssue = error.localizedDescription
        }
        isWorking = false
    }

    private func persistSession(name: String, organization: OrganizationResponse?) {
        userName = name
        organizationID = organization?.id
        organizationName = organization?.name
        isAuthenticated = true
        defaults.set(true, forKey: "authenticated")
        defaults.set(name, forKey: "userName")
        defaults.set(organization?.id, forKey: "organizationID")
        defaults.set(organization?.name, forKey: "organizationName")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
