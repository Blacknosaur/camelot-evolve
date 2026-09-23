import AVFoundation
import Combine
@preconcurrency import MultipeerConnectivity
import SwiftUI

/// Where a camera phone keeps the file it recorded before (and after) handing it to the host.
/// The main app files it in the project library; the companion app keeps a plain folder.
protocol MultiCamPeerStore {
    /// Moves the finished file into place and returns its final location.
    @MainActor func save(_ finished: MultiCamCaptureEngine.Finished, projectID: UUID, projectName: String, sessionID: UUID, deviceName: String) throws -> URL
}

/// A phone that joined someone else's session: a camera (records + streams on the host's
/// command, then hands over its file) or a remote (events only).
@MainActor
final class MultiCamPeerController: ObservableObject {
    let session: MultiCamSession
    let engine: MultiCamCaptureEngine
    let store: MultiCamPeerStore
    let hostFeed = MultiCamFeed(id: UUID())
    @Published private(set) var taggedEvents: [EventKind] = []
    @Published private(set) var lastTag: EventKind?
    @Published private(set) var hostIsRecording = false
    @Published private(set) var hostElapsed = 0.0
    @Published private(set) var hostMaximumZoom = 1.0
    @Published private(set) var hostExposureRange: ClosedRange<Float> = 0...0
    @Published private(set) var hostZoom = 1.0
    @Published private(set) var hostExposure: Float = 0
    @Published private(set) var transfer: Progress?
    @Published private(set) var transferState: TransferState = .none
    @Published var statusMessage: String?
    private var statusTask: Task<Void, Never>?
    private var startedTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var pendingTransfer: (id: UUID, url: URL)?
    private var forwarding: [AnyCancellable] = []

    enum TransferState: Equatable { case none, sending, received, failed(String) }

    init(displayName: String, deviceID: UUID, store: MultiCamPeerStore, captureStorage: MultiCamCaptureStorage = TemporaryCaptureStorage()) {
        session = MultiCamSession(role: .camera, displayName: displayName, deviceID: deviceID)
        engine = MultiCamCaptureEngine(storage: captureStorage)
        self.store = store
        // Views observe the controller only; changes in the session and engine surface through it.
        forwarding = [session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                      engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }]
    }

    var role: MultiCamRole? { session.mode?.peerRole }
    var isCamera: Bool { role == .camera }
    var eventCounts: [EventKind: Int] { Dictionary(grouping: taggedEvents, by: { $0 }).mapValues(\.count) }

    func start() {
        session.onMessage = { [weak self] message, _ in self?.handle(message) }
        let hostFeed = self.hostFeed
        session.onVideoPacket = { packet, _ in hostFeed.receive(packet) }
        session.startBrowsing()
    }

    func join(_ host: MultiCamSession.DiscoveredHost) { session.join(host) }

    func leave() {
        statusTask?.cancel(); startedTask?.cancel(); transferTask?.cancel()
        engine.stopStreaming()
        hostFeed.invalidate()
        session.end()
        engine.shutdown()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func tag(_ kind: EventKind) {
        guard hostIsRecording || isCamera && engine.isRecording else { return }
        session.send(.event(kind: kind.rawValue, hostTime: session.hostNow()))
        taggedEvents.append(kind)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.18)) { lastTag = kind }
        Task { try? await Task.sleep(for: .milliseconds(900)); withAnimation { if lastTag == kind { lastTag = nil } } }
    }

    func controlHostCamera(zoom: Double? = nil, focus: CGPoint? = nil, exposure: Float? = nil) {
        session.send(.cameraControl(zoom: zoom, focusX: focus.map { Double($0.x) }, focusY: focus.map { Double($0.y) }, exposure: exposure))
        if let zoom { hostZoom = zoom }
        if let exposure { hostExposure = exposure }
    }

    private func handle(_ message: MultiCamMessage) {
        switch message {
        case .welcome:
            UIApplication.shared.isIdleTimerDisabled = true
            if isCamera { Task { await becomeCamera() } }
        case let .hostStatus(isRecording, elapsed):
            hostIsRecording = isRecording; hostElapsed = elapsed
        case let .cameraCapabilities(maxZoom, minExposure, maxExposure, zoom, exposure):
            hostMaximumZoom = maxZoom; hostExposureRange = minExposure...maxExposure
            hostZoom = zoom; hostExposure = exposure
        case let .startRecording(recordingID, _):
            startLocalRecording(id: recordingID)
        case .stopRecording:
            Task { await stopLocalRecording() }
        case let .transferReceived(id):
            if pendingTransfer?.id == id { transferState = .received; transfer = nil; pendingTransfer = nil; transferTask?.cancel() }
        case .endSession:
            statusMessage = "\(session.hostName) ended the session."
        default: break
        }
    }

    private func becomeCamera() async {
        await engine.prepare(quality: .hd)
        guard engine.isReady else { return }
        let session = self.session
        let offset = session.offsetSnapshot
        // Runs on the sink queue: read the sync offset from the snapshot, never from the actor.
        engine.hostTime = { local in local + offset.value }
        engine.startStreaming { packet in session.sendVideo(packet) }
        UIDevice.current.isBatteryMonitoringEnabled = true
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let free = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
                self.session.send(.cameraStatus(isRecording: self.engine.isRecording, elapsedSeconds: self.engine.elapsed.totalSeconds,
                    batteryLevel: UIDevice.current.batteryLevel, freeMegabytes: Int(free / 1_048_576)))
            }
        }
    }

    private func startLocalRecording(id: UUID) {
        guard isCamera, engine.isReady, !engine.isRecording, let projectID = session.projectID else { return }
        transferState = .none
        engine.startRecording(id: id, projectID: projectID, program: false)
        startedTask?.cancel()
        startedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.engine.isRecording else { return }
                if let first = self.engine.firstFrameHostTime {
                    self.session.send(.recordingStarted(recordingID: id, firstFrameHostTime: first))
                    return
                }
            }
        }
    }

    private func stopLocalRecording() async {
        guard engine.isRecording, let projectID = session.projectID else { return }
        guard let finished = await engine.stopRecording() else { return }
        let local = finished.local
        do {
            let fileURL = try store.save(local, projectID: projectID, projectName: session.projectName, sessionID: session.sessionID, deviceName: session.localPeer.displayName)
            statusMessage = "Saved \(timecode(local.duration)) locally. Sending to \(session.hostName)…"
            guard let host = session.hostPeer else { return }
            let bytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            session.send(.transferReady(recordingID: local.id, byteCount: bytes, durationSeconds: local.duration, firstFrameHostTime: local.firstFrameHostTime ?? 0,
                deviceName: session.localPeer.displayName), to: [host])
            pendingTransfer = (local.id, fileURL)
            transferState = .sending
            transfer = session.sendResource(at: fileURL, name: local.id.uuidString, to: host)
            // `Progress` is KVO, not Combine: tick the view while the bytes move.
            transferTask = Task { [weak self] in
                while !Task.isCancelled, self?.transferState == .sending {
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.objectWillChange.send()
                }
            }
        } catch {
            statusMessage = error.localizedDescription
            transferState = .failed(error.localizedDescription)
        }
    }
}
