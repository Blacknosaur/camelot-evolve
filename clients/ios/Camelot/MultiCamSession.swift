import CoreMedia
@preconcurrency import MultipeerConnectivity
import Combine
import UIKit

/// Peer-to-peer link between the phones of one session (Wi‑Fi or direct, no router needed).
/// One instance per phone: the host advertises and answers clock pings; cameras and remotes
/// browse, join, and keep their clock aligned to the host's.
@MainActor
final class MultiCamSession: NSObject, ObservableObject {
    /// Bonjour service type; also listed under `NSBonjourServices` in Info.plist.
    static let serviceType = "camelot-cam"

    struct Peer: Identifiable {
        let id: MCPeerID
        var name: String
        var role: MultiCamRole
        var deviceID: UUID?
        var isRecording = false
        var elapsedSeconds = 0.0
        var batteryLevel: Float = -1
        var freeMegabytes = 0
        var recordingID: UUID?
        var firstFrameHostTime: Double?
        var hasVideo = false
        var lastFrameAt = 0.0
        var transfer: Progress?
        var transferByteCount: Int64 = 0
        var transferDuration = 0.0
        var isTransferred = false
    }

    struct DiscoveredHost: Identifiable {
        let id: MCPeerID
        var name: String
        var projectName: String
        var mode: MultiCamMode?
    }

    enum State: Equatable { case idle, browsing, connecting, connected, ended }

    let role: MultiCamRole
    let deviceID: UUID
    let localPeer: MCPeerID
    @Published private(set) var state: State = .idle
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var hostPeer: MCPeerID?
    @Published private(set) var hostName = ""
    @Published private(set) var sessionID = UUID()
    @Published private(set) var mode: MultiCamMode?
    @Published private(set) var projectID: UUID?
    @Published private(set) var projectName = ""
    @Published private(set) var clock = MultiCamClockSync()
    /// `clock.offset` for capture-queue code that must not touch the actor.
    let offsetSnapshot = LockedValue<Double>(0)
    @Published var lastError: String?
    /// Where a companion can connect by hand when the network blocks Bonjour.
    @Published private(set) var manualAddress: String?
    private var addressTask: Task<Void, Never>?

    /// Control messages, on the main actor.
    var onMessage: ((MultiCamMessage, MCPeerID) -> Void)?
    /// Compressed video, on the receive queue: hand it to a decoder, never to SwiftUI directly.
    var onVideoPacket: (@Sendable (MultiCamVideoPacket, MCPeerID) -> Void)? {
        get { videoHandler.value }
        set { videoHandler.value = newValue }
    }
    private let videoHandler = LockedValue<(@Sendable (MultiCamVideoPacket, MCPeerID) -> Void)?>(nil)
    /// A finished file transfer (already moved to a temporary location the caller owns).
    var onResource: ((String, URL, MCPeerID) -> Void)?

    /// MCSession is thread-safe; the encoder queue sends video and the invitation callback hands it over.
    private nonisolated(unsafe) let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    /// Non-Apple cameras (the Android companion) connect over TCP with the same wire format.
    private var socketServer: MultiCamSocketServer?
    private var socketPeers: Set<MCPeerID> = []
    private let incomingFiles = LockedValue<[UUID: IncomingFile]>([:])
    private let expectedFileSizes = LockedValue<[UUID: Int64]>([:])
    private var browser: MCNearbyServiceBrowser?

    private struct IncomingFile {
        let peer: MCPeerID
        let url: URL
        let handle: FileHandle
        let progress: Progress
    }
    private var clockTask: Task<Void, Never>?
    private var pendingPings: [UUID: Double] = [:]

    init(role: MultiCamRole, displayName: String, deviceID: UUID) {
        self.role = role
        self.deviceID = deviceID
        localPeer = MCPeerID(displayName: String(displayName.prefix(63)))
        session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    /// Seconds on the capture clock (same clock as camera sample timestamps).
    nonisolated static func localNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    /// The session's shared clock: the host's own clock, or the peer's clock corrected by the sync.
    func hostNow() -> Double { role == .host ? Self.localNow() : clock.hostTime(forLocal: Self.localNow()) }

    var connectedPeers: [Peer] { peers }
    var cameras: [Peer] { peers.filter { $0.role == .camera } }
    var isConnected: Bool { role == .host ? !peers.isEmpty : hostPeer != nil && state == .connected }
    func peer(_ id: MCPeerID) -> Peer? { peers.first { $0.id == id } }

    // MARK: Host

    func startHosting(mode: MultiCamMode, projectID: UUID, projectName: String) {
        guard role == .host, state == .idle else { return }
        self.mode = mode; self.projectID = projectID; self.projectName = projectName
        sessionID = UUID()
        let info = ["project": String(projectName.prefix(60)), "mode": mode.rawValue]
        let advertiser = MCNearbyServiceAdvertiser(peer: localPeer, discoveryInfo: info, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        let server = MultiCamSocketServer(name: localPeer.displayName, txtRecord: info)
        server.onConnect = { peer in Task { @MainActor in self.socketPeers.insert(peer); self.updatePeer(peer) { _ in } } }
        server.onDisconnect = { peer in Task { @MainActor in self.socketPeers.remove(peer); self.peers.removeAll { $0.id == peer } } }
        server.onFrame = { [weak self] body, peer in self?.receivedWire(body, from: peer) }
        socketServer = server
        // The listener reports its port asynchronously; publish it once it is ready.
        addressTask = Task { [weak self] in
            for _ in 0..<40 {
                if let address = server.address.value { self?.manualAddress = address; return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        state = .connected
    }

    // MARK: Peer

    func startBrowsing() {
        guard role != .host, state == .idle || state == .browsing else { return }
        let browser = MCNearbyServiceBrowser(peer: localPeer, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        state = .browsing
    }

    func join(_ host: DiscoveredHost) {
        guard let browser, state == .browsing else { return }
        state = .connecting
        hostPeer = host.id; hostName = host.name
        browser.invitePeer(host.id, to: session, withContext: nil, timeout: 20)
    }

    // MARK: Messaging

    func send(_ message: MultiCamMessage, to targets: [MCPeerID]? = nil) {
        guard let data = try? message.wireData() else { return }
        let recipients = targets ?? (session.connectedPeers + socketPeers)
        let multipeer = recipients.filter { !socketPeers.contains($0) }
        if !multipeer.isEmpty {
            do { try session.send(data, toPeers: multipeer, with: .reliable) }
            catch { lastError = error.localizedDescription }
        }
        for peer in recipients where socketPeers.contains(peer) { socketServer?.send(data, to: peer) }
    }

    /// Video is sent from the encoder's queue; MCSession is thread-safe for sends.
    nonisolated func sendVideo(_ packet: MultiCamVideoPacket) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        try? session.send(packet.wireData(), toPeers: peers, with: .reliable)
    }

    func sendResource(at url: URL, name: String, to peer: MCPeerID) -> Progress? {
        session.sendResource(at: url, withName: name, toPeer: peer) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = "Transfer failed: \(error.localizedDescription)" }
        }
    }

    func end() {
        guard state != .ended else { return }
        if role == .host { send(.endSession) }
        clockTask?.cancel(); clockTask = nil
        addressTask?.cancel(); addressTask = nil
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        socketServer?.stop(); socketServer = nil; socketPeers.removeAll()
        session.disconnect()
        peers.removeAll(); hosts.removeAll(); hostPeer = nil
        state = .ended
    }

    // MARK: Clock

    private func startClockSync() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                guard let self, let host = self.hostPeer else { return }
                let id = UUID(), now = Self.localNow()
                self.pendingPings[id] = now
                self.send(.clockPing(id: id, sentAt: now), to: [host])
                round += 1
                try? await Task.sleep(for: .seconds(round < 10 ? 0.5 : 10))
            }
        }
    }

    // MARK: Incoming

    private func handle(_ message: MultiCamMessage, from peer: MCPeerID) {
        switch message {
        case let .hello(deviceName, id):
            guard role == .host, let mode else { return }
            updatePeer(peer) { $0.name = deviceName; $0.deviceID = id; $0.role = mode.peerRole }
            send(.welcome(sessionID: sessionID, mode: mode, projectID: projectID ?? UUID(), projectName: projectName, hostName: localPeer.displayName), to: [peer])
        case let .welcome(id, mode, projectID, projectName, hostName):
            sessionID = id; self.mode = mode; self.projectID = projectID; self.projectName = projectName; self.hostName = hostName
            state = .connected
            startClockSync()
        case let .clockPing(id, sentAt):
            let received = Self.localNow()
            send(.clockPong(id: id, sentAt: sentAt, hostReceivedAt: received, hostSentAt: Self.localNow()), to: [peer])
            return
        case let .clockPong(id, sentAt, hostReceivedAt, hostSentAt):
            guard pendingPings.removeValue(forKey: id) != nil else { return }
            clock.record(sentAt: sentAt, hostReceivedAt: hostReceivedAt, hostSentAt: hostSentAt, receivedAt: Self.localNow())
            offsetSnapshot.value = clock.offset
            return
        case let .recordingStarted(recordingID, firstFrame):
            updatePeer(peer) { $0.recordingID = recordingID; $0.firstFrameHostTime = firstFrame; $0.isRecording = true }
        case let .cameraStatus(isRecording, elapsed, battery, free):
            updatePeer(peer) { $0.isRecording = isRecording; $0.elapsedSeconds = elapsed; $0.batteryLevel = battery; $0.freeMegabytes = free }
        case let .transferReady(recordingID, bytes, duration, firstFrame, name):
            updatePeer(peer) { $0.recordingID = recordingID; $0.transferByteCount = bytes; $0.transferDuration = duration; $0.firstFrameHostTime = firstFrame; $0.name = name }
            expectedFileSizes.value[recordingID] = bytes
        case .endSession:
            if role != .host { end() }
        default: break
        }
        onMessage?(message, peer)
    }

    private func updatePeer(_ id: MCPeerID, _ change: (inout Peer) -> Void) {
        if let index = peers.firstIndex(where: { $0.id == id }) { change(&peers[index]) }
        else { var peer = Peer(id: id, name: id.displayName, role: mode?.peerRole ?? .remote); change(&peer); peers.append(peer) }
    }

    fileprivate func peerChanged(_ peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            if role == .host { updatePeer(peer) { _ in } }
            else if peer == hostPeer { send(.hello(deviceName: localPeer.displayName, deviceID: deviceID), to: [peer]) }
        case .notConnected:
            peers.removeAll { $0.id == peer }
            if role != .host, peer == hostPeer, self.state != .ended {
                hostPeer = nil; clockTask?.cancel(); clockTask = nil
                lastError = "Lost the connection to \(hostName)."
                self.state = .browsing
                browser?.startBrowsingForPeers()
            }
        case .connecting: break
        @unknown default: break
        }
    }

    fileprivate func markVideo(from peer: MCPeerID, at time: Double) {
        guard let index = peers.firstIndex(where: { $0.id == peer }) else { return }
        peers[index].hasVideo = true; peers[index].lastFrameAt = time
    }

    fileprivate func setTransferProgress(_ progress: Progress?, for peer: MCPeerID) {
        updatePeer(peer) { $0.transfer = progress }
    }

    fileprivate func finishedResource(named name: String, at url: URL, from peer: MCPeerID) {
        updatePeer(peer) { $0.transfer = nil; $0.isTransferred = true }
        onResource?(name, url, peer)
    }

    fileprivate func foundHost(_ peer: MCPeerID, info: [String: String]?) {
        let host = DiscoveredHost(id: peer, name: peer.displayName, projectName: info?["project"] ?? "", mode: info.flatMap { MultiCamMode(rawValue: $0["mode"] ?? "") })
        if let index = hosts.firstIndex(where: { $0.id == peer }) { hosts[index] = host } else { hosts.append(host) }
    }

    fileprivate func lostHost(_ peer: MCPeerID) { hosts.removeAll { $0.id == peer } }
    fileprivate func failed(_ message: String) { lastError = message; if state == .connecting { state = .browsing } }
}

// MARK: - MultipeerConnectivity delegates

extension MultiCamSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.peerChanged(peerID, state: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        receivedWire(data, from: peerID)
    }

    /// One body from either transport: control JSON, a video packet, or (sockets only) a file chunk.
    private nonisolated func receivedWire(_ data: Data, from peer: MCPeerID) {
        guard let tag = data.first else { return }
        switch MultiCamWireTag(rawValue: tag) {
        case .control:
            guard let message = try? MultiCamMessage.decode(data.dropFirst()) else { return }
            // Chunks can follow `transferReady` on the socket before the actor runs; size first.
            if case let .transferReady(recordingID, bytes, _, _, _) = message { expectedFileSizes.value[recordingID] = bytes }
            Task { @MainActor in self.handle(message, from: peer) }
        case .video:
            guard let packet = MultiCamVideoPacket.decode(data) else { return }
            onVideoPacketNonisolated(packet, from: peer)
        case nil:
            if tag == MultiCamSocketServer.fileChunkTag { receivedFileChunk(data.dropFirst(), from: peer) }
        }
    }

    /// Socket transfers arrive as chunks after `transferReady`; the file completes at the announced size.
    private nonisolated func receivedFileChunk(_ chunk: Data, from peer: MCPeerID) {
        guard chunk.count >= 16 else { return }
        let id = UUID(uuid: chunk.prefix(16).withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
        let bytes = chunk.dropFirst(16)
        guard let expected = expectedFileSizes.value[id] else { return }
        var finished: IncomingFile?
        incomingFiles.withValue { files in
            if files[id] == nil {
                let url = FileManager.default.temporaryDirectory.appending(path: "multicam-\(id.uuidString).mov")
                FileManager.default.createFile(atPath: url.path(), contents: nil)
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                let progress = Progress(totalUnitCount: expected)
                files[id] = IncomingFile(peer: peer, url: url, handle: handle, progress: progress)
                Task { @MainActor in self.setTransferProgress(progress, for: peer) }
            }
            guard let file = files[id] else { return }
            try? file.handle.write(contentsOf: bytes)
            file.progress.completedUnitCount += Int64(bytes.count)
            if file.progress.completedUnitCount >= expected {
                try? file.handle.close()
                files[id] = nil
                finished = file
            }
        }
        if let finished {
            expectedFileSizes.value[id] = nil
            Task { @MainActor in self.finishedResource(named: id.uuidString, at: finished.url, from: finished.peer) }
        }
    }

    /// Reads the handler without touching the actor; the handler itself is `@Sendable`.
    private nonisolated func onVideoPacketNonisolated(_ packet: MultiCamVideoPacket, from peer: MCPeerID) {
        videoHandler.value?(packet, peer)
        let time = Self.localNow()
        Task { @MainActor in self.markVideo(from: peer, at: time) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        Task { @MainActor in self.setTransferProgress(progress, for: peerID) }
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // The framework deletes `localURL` when this returns; keep our own copy first.
        var kept: URL?
        if let localURL, error == nil {
            let destination = FileManager.default.temporaryDirectory.appending(path: "multicam-\(UUID().uuidString).mov")
            if (try? FileManager.default.moveItem(at: localURL, to: destination)) != nil { kept = destination }
        }
        let message = error?.localizedDescription
        Task { @MainActor in
            if let kept { self.finishedResource(named: resourceName, at: kept, from: peerID) }
            else { self.setTransferProgress(nil, for: peerID); self.lastError = message.map { "Transfer failed: \($0)" } ?? "Transfer failed." }
        }
    }
}

extension MultiCamSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.failed("Could not start the session: \(message)") }
    }
}

extension MultiCamSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.foundHost(peerID, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.lostHost(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.failed("Could not look for sessions: \(message)") }
    }
}

/// A value shared between the main actor and the Multipeer receive queue.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T { try lock.withLock { try body(&stored) } }
}
