@preconcurrency import MultipeerConnectivity
import Network

/// TCP transport for non-Apple cameras (the Android companion). Advertised over Bonjour as
/// `_camelot-sock._tcp`; every frame is a 4-byte big-endian length followed by a body that starts
/// with the same `MultiCamWireTag` byte as the Multipeer channel (control JSON, video packet), plus
/// tag 3 for file chunks: `[3][16-byte recording id][bytes]`.
final class MultiCamSocketServer: @unchecked Sendable {
    static let serviceType = "_camelot-sock._tcp"
    static let fileChunkTag: UInt8 = 3

    var onConnect: (@Sendable (MCPeerID) -> Void)?
    var onDisconnect: (@Sendable (MCPeerID) -> Void)?
    /// Whole frames (without the length prefix), on the server queue.
    var onFrame: (@Sendable (Data, MCPeerID) -> Void)?

    private let listener: NWListener?
    /// "192.168.1.40:53084" once the listener is up: what a companion types when mDNS is blocked.
    let address = LockedValue<String?>(nil)
    private let queue = DispatchQueue(label: "com.camelot.multicam.socket")
    private var connections: [ObjectIdentifier: (connection: NWConnection, peer: MCPeerID)] = [:]

    init(name: String, txtRecord: [String: String]) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        listener = try? NWListener(using: parameters)
        listener?.service = NWListener.Service(name: String(name.prefix(60)), type: Self.serviceType, txtRecord: NWTXTRecord(txtRecord))
        listener?.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener?.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let port = self?.listener?.port?.rawValue, let ip = Self.wifiAddress() else { return }
            self?.address.value = "\(ip):\(port)"
        }
        listener?.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            connections.values.forEach { $0.connection.cancel() }
            connections.removeAll()
        }
    }

    func send(_ body: Data, to peer: MCPeerID) {
        queue.async { [self] in
            guard let entry = connections.values.first(where: { $0.peer == peer }) else { return }
            var frame = Data(capacity: body.count + 4)
            frame.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
            frame.append(body)
            entry.connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    func peers() -> [MCPeerID] { queue.sync { connections.values.map(\.peer) } }

    /// This device's IPv4 address on Wi-Fi, which is the one a companion can reach.
    static func wifiAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    private func accept(_ connection: NWConnection) {
        let peer = MCPeerID(displayName: "Camera \(connections.count + 1)")
        connections[ObjectIdentifier(connection)] = (connection, peer)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onConnect?(peer)
                self.readFrame(from: connection, peer: peer)
            case .failed, .cancelled:
                self.queue.async {
                    if self.connections.removeValue(forKey: ObjectIdentifier(connection)) != nil { self.onDisconnect?(peer) }
                }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func readFrame(from connection: NWConnection, peer: MCPeerID) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, let header, header.count == 4, error == nil else { connection.cancel(); return }
            let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard length > 0, length < 64 * 1_024 * 1_024 else { connection.cancel(); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self, let body, body.count == length, error == nil else { connection.cancel(); return }
                self.onFrame?(body, peer)
                self.readFrame(from: connection, peer: peer)
            }
        }
    }
}
