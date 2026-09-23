import AVFoundation
import Combine
@preconcurrency import MultipeerConnectivity
import SwiftData
import SwiftUI

// MARK: - Library

/// Puts a finished multi-cam file into the project library, like the camera does for its segments.
enum MultiCamLibrary {
    @discardableResult
    static func save(id: UUID, fileURL: URL, duration: Double, startedAt: Date, projectID: UUID, role: MultiCamRecordingRole, sessionID: UUID,
                     deviceName: String, offsetSeconds: Double, switches: MultiCamSwitchTimeline? = nil, name: String = "", modelContext: ModelContext) throws -> Recording {
        let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try RecordingLibrary.prepareMediaDirectory(folder)
        let destination = folder.appending(path: id.uuidString).appendingPathExtension("mov")
        if FileManager.default.fileExists(atPath: destination.path()) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: fileURL, to: destination)
        let count = try modelContext.fetchCount(FetchDescriptor<Recording>(predicate: #Predicate<Recording> { $0.projectID == projectID }))
        let recording = Recording(id: id, projectID: projectID, localPath: destination.lastPathComponent, name: name, duration: duration, segmentIndex: count, recordedAt: startedAt)
        recording.multiCamSessionID = sessionID
        recording.multiCamRole = role.rawValue
        recording.multiCamDeviceName = deviceName
        recording.multiCamOffsetSeconds = offsetSeconds
        if let switches, let data = try? JSONEncoder().encode(switches) { recording.multiCamSwitches = String(decoding: data, as: UTF8.self) }
        modelContext.insert(recording)
        try modelContext.save()
        RecordingRecovery.removeJournal(for: id)
        return recording
    }

    /// The camera phone keeps its video under the host's project so both libraries agree.
    static func project(id: UUID, name: String, modelContext: ModelContext) throws -> Project {
        if let existing = try modelContext.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })).first { return existing }
        let project = Project(name: name.isEmpty ? "Multi-cam session" : name)
        project.id = id
        modelContext.insert(project)
        try modelContext.save()
        return project
    }

    @MainActor static func displayName(for appState: AppState) -> String { "\(appState.userName) · \(UIDevice.current.model)" }
}

/// Journaled capture files, recovered into the library after a crash like normal recordings.
struct RecordingRecoveryStorage: MultiCamCaptureStorage {
    func mediaURL(for id: UUID) -> URL { RecordingRecovery.mediaURL(for: id) }
    func beginRecording(id: UUID, projectID: UUID, mode: String) throws { _ = try RecordingRecovery.create(recordingID: id, projectID: projectID, mode: mode) }
    func discardRecording(id: UUID) { RecordingRecovery.removeJournal(for: id) }
}

/// The main app as a camera phone: the video lands in the (mirrored) project, like any recording.
struct SwiftDataPeerStore: MultiCamPeerStore {
    let modelContext: ModelContext

    @MainActor func save(_ finished: MultiCamCaptureEngine.Finished, projectID: UUID, projectName: String, sessionID: UUID, deviceName: String) throws -> URL {
        _ = try MultiCamLibrary.project(id: projectID, name: projectName, modelContext: modelContext)
        return try MultiCamLibrary.save(id: finished.id, fileURL: finished.url, duration: finished.duration, startedAt: finished.startedAt, projectID: projectID,
            role: .camera, sessionID: sessionID, deviceName: deviceName, offsetSeconds: 0, modelContext: modelContext).fileURL
    }
}

extension MultiCamPeerController {
    /// The main app's peer: library-backed storage and journaled capture.
    @MainActor convenience init(appState: AppState, modelContext: ModelContext) {
        self.init(displayName: MultiCamLibrary.displayName(for: appState), deviceID: appState.deviceID,
                  store: SwiftDataPeerStore(modelContext: modelContext), captureStorage: RecordingRecoveryStorage())
    }
}

// MARK: - Host

/// The main phone: owns the capture, the previews of every camera, the synced start/stop, the
/// events coming from remotes, and the file transfers after the session.
@MainActor
final class MultiCamHost: ObservableObject {
    struct Transfer: Identifiable { let id: MCPeerID; var name: String; var fraction: Double; var isDone: Bool }

    let project: Project
    let mode: MultiCamMode
    let session: MultiCamSession
    let engine = MultiCamCaptureEngine(storage: RecordingRecoveryStorage())
    @Published private(set) var feeds: [UUID: MultiCamFeed] = [:]
    /// Which camera phone owns which feed/recording id, assigned when the camera says hello.
    @Published private(set) var cameraIDs: [MCPeerID: UUID] = [:]
    @Published private(set) var primaryRecordingID: UUID?
    @Published private(set) var taggedEvents: [EventKind] = []
    @Published private(set) var lastTag: EventKind?
    @Published private(set) var savedCount = 0
    @Published private(set) var awaitingTransfers = 0
    @Published var statusMessage: String?
    private var modelContext: ModelContext?
    private var primaryFirstFrame: Double?
    private var lastSessionID = UUID()
    private var statusTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var forwarding: [AnyCancellable] = []
    /// Peer → feed lookup usable from the Multipeer receive queue.
    private let feedSnapshot = LockedValue<[MCPeerID: MultiCamFeed]>([:])

    init(project: Project, mode: MultiCamMode, appState: AppState) {
        self.project = project
        self.mode = mode
        session = MultiCamSession(role: .host, displayName: MultiCamLibrary.displayName(for: appState), deviceID: appState.deviceID)
        forwarding = [session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                      engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }]
    }

    var isRecording: Bool { engine.isRecording }
    var cameras: [MultiCamSession.Peer] { session.peers.filter { $0.role == .camera } }
    var remotes: [MultiCamSession.Peer] { session.peers.filter { $0.role == .remote } }
    func feed(for peer: MultiCamSession.Peer) -> MultiCamFeed? { cameraIDs[peer.id].flatMap { feeds[$0] } }
    var transfers: [Transfer] {
        cameras.compactMap { peer in
            guard peer.recordingID != nil, !isRecording else { return nil }
            return Transfer(id: peer.id, name: peer.name, fraction: peer.transfer?.fractionCompleted ?? (peer.isTransferred ? 1 : 0), isDone: peer.isTransferred)
        }
    }

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        engine.hostTime = { $0 }
        session.onMessage = { [weak self] message, peer in self?.handle(message, from: peer) }
        session.onVideoPacket = { [weak self] packet, peer in
            // Feeds are keyed by the id handed out at hello; unknown peers are ignored until then.
            guard let feed = self?.feedSnapshot.value[peer] else { return }
            feed.receive(packet)
        }
        session.onResource = { [weak self] name, url, peer in self?.receivedFile(named: name, at: url, from: peer) }
        session.startHosting(mode: mode, projectID: project.id, projectName: project.name)
        if mode == .eventRemote {
            let session = self.session
            engine.startStreaming { packet in session.sendVideo(packet) }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.session.send(.hostStatus(isRecording: self.isRecording, elapsedSeconds: self.engine.elapsed.totalSeconds))
                self.session.send(.cameraCapabilities(maxZoom: Double(self.engine.maximumZoomFactor), minExposure: self.engine.exposureBiasRange.lowerBound,
                    maxExposure: self.engine.exposureBiasRange.upperBound, zoom: Double(self.engine.zoomFactor), exposure: self.engine.exposureBias))
            }
        }
    }

    func end() {
        statusTask?.cancel(); transferTask?.cancel()
        session.end()
        feeds.values.forEach { $0.invalidate() }
        feeds.removeAll(); feedSnapshot.value = [:]
        engine.shutdown()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Recording

    func startRecording() {
        guard engine.isReady, !isRecording else { return }
        let id = UUID()
        primaryRecordingID = id; primaryFirstFrame = nil
        taggedEvents.removeAll(); lastTag = nil
        lastSessionID = session.sessionID
        engine.startRecording(id: id, projectID: project.id, program: mode == .switcher)
        guard engine.isRecording else { primaryRecordingID = nil; return }
        let now = session.hostNow()
        for (peer, recordingID) in cameraIDs { session.send(.startRecording(recordingID: recordingID, hostTime: now), to: [peer]) }
    }

    func stopRecording() {
        guard isRecording, let modelContext else { return }
        session.send(.stopRecording(hostTime: session.hostNow()))
        awaitingTransfers = cameras.filter(\.isRecording).count
        if awaitingTransfers > 0 {
            // `Progress` is KVO, not Combine: tick the transfer list while bytes arrive.
            transferTask = Task { [weak self] in
                while !Task.isCancelled, (self?.awaitingTransfers ?? 0) > 0 {
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.objectWillChange.send()
                }
            }
        }
        Task {
            guard let finished = await engine.stopRecording() else { return }
            primaryFirstFrame = finished.local.firstFrameHostTime
            do {
                try MultiCamLibrary.save(id: finished.local.id, fileURL: finished.local.url, duration: finished.local.duration, startedAt: finished.local.startedAt,
                    projectID: project.id, role: .primary, sessionID: lastSessionID, deviceName: session.localPeer.displayName, offsetSeconds: 0, modelContext: modelContext)
                savedCount += 1
                if let program = finished.program {
                    try MultiCamLibrary.save(id: program.id, fileURL: program.url, duration: program.duration, startedAt: program.startedAt, projectID: project.id, role: .program,
                        sessionID: lastSessionID, deviceName: session.localPeer.displayName, offsetSeconds: 0, switches: finished.switches, name: "Live cut", modelContext: modelContext)
                    savedCount += 1
                }
                statusMessage = awaitingTransfers > 0 ? "Saved. Receiving \(awaitingTransfers == 1 ? "the other camera's video" : "\(awaitingTransfers) camera videos")…" : "Saved \(timecode(finished.local.duration)) locally"
            } catch {
                statusMessage = error.localizedDescription
            }
            // Fresh ids for the next take, so a second recording never collides with the first.
            for peer in cameraIDs.keys { assignFeed(to: peer) }
        }
    }

    /// Switcher: put this camera (or nil, this phone) on the program.
    func switchProgram(to source: UUID?) { engine.switchProgram(to: source) }

    func addEvent(_ kind: EventKind) {
        guard isRecording else { return }
        insertEvent(kind, at: engine.elapsed.totalSeconds)
    }

    private func insertEvent(_ kind: EventKind, at offset: Double) {
        guard let modelContext, let recordingID = primaryRecordingID else { return }
        let event = MatchEvent(projectID: project.id, recordingID: recordingID, kind: kind.rawValue)
        event.offsetSeconds = max(0, offset)
        event.preRollSeconds = kind.defaultPreRoll
        event.postRollSeconds = kind.defaultPostRoll
        modelContext.insert(event)
        try? modelContext.save()
        taggedEvents.append(kind)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.snappy(duration: 0.18)) { lastTag = kind }
        Task { try? await Task.sleep(for: .milliseconds(900)); withAnimation { if lastTag == kind { lastTag = nil } } }
    }

    var eventCounts: [EventKind: Int] { Dictionary(grouping: taggedEvents, by: { $0 }).mapValues(\.count) }

    // MARK: Peers

    private func handle(_ message: MultiCamMessage, from peer: MCPeerID) {
        switch message {
        case .hello:
            if mode.streamsVideo, cameraIDs[peer] == nil { assignFeed(to: peer) }
            if isRecording, let recordingID = cameraIDs[peer] {
                // Joined mid-take: record from now; alignment still comes from the first frame time.
                session.send(.startRecording(recordingID: recordingID, hostTime: session.hostNow()), to: [peer])
            }
        case let .event(kind, hostTime):
            guard isRecording, let kind = EventKind(rawValue: kind), let firstFrame = engine.firstFrameHostTime else { return }
            insertEvent(kind, at: hostTime - firstFrame)
        case let .cameraControl(zoom, focusX, focusY, exposure):
            guard mode == .eventRemote else { return }
            if let zoom { engine.setZoom(zoom) }
            if let focusX, let focusY { engine.focus(at: CGPoint(x: focusX, y: focusY)) }
            if let exposure { engine.setExposureBias(exposure) }
        default: break
        }
    }

    private func assignFeed(to peer: MCPeerID) {
        if let old = cameraIDs[peer], let feed = feeds[old] { feed.invalidate(); feeds[old] = nil }
        let id = UUID()
        let feed = MultiCamFeed(id: id)
        if mode == .switcher {
            let engine = self.engine
            feed.onFrame = { pixelBuffer in engine.appendRemoteFrame(pixelBuffer, from: id) }
        }
        feeds[id] = feed
        cameraIDs[peer] = id
        feedSnapshot.value[peer] = feed
    }

    private func receivedFile(named name: String, at url: URL, from peer: MCPeerID) {
        guard let modelContext, let info = session.peer(peer), let recordingID = info.recordingID else { return }
        let offset = MultiCamAlignment.offsetSeconds(cameraFirstFrame: info.firstFrameHostTime ?? primaryFirstFrame ?? 0, hostFirstFrame: primaryFirstFrame ?? 0)
        do {
            try MultiCamLibrary.save(id: recordingID, fileURL: url, duration: info.transferDuration, startedAt: .now, projectID: project.id, role: .camera,
                sessionID: lastSessionID, deviceName: info.name, offsetSeconds: offset, name: info.name, modelContext: modelContext)
            savedCount += 1
            awaitingTransfers = max(0, awaitingTransfers - 1)
            session.send(.transferReceived(recordingID: recordingID), to: [peer])
            statusMessage = awaitingTransfers == 0 ? "All videos are in the project." : "Received \(info.name). \(awaitingTransfers) to go."
        } catch {
            statusMessage = "Could not save \(info.name)'s video: \(error.localizedDescription)"
        }
    }
}
