import Foundation

// MARK: - Roles and modes

/// What a phone does in a multi-cam session. The host owns the project, the clock and the
/// recording state; cameras record locally and stream a preview; remotes only tag events.
enum MultiCamRole: String, Codable, Sendable {
    case host, camera, remote
}

/// The experience the host picked. Cameras behave the same in `dualCamera` and `switcher`;
/// the difference is what the host records and what happens after the files arrive.
enum MultiCamMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Two phones cover the pitch; the second recording is stitched to the host's after the game.
    case dualCamera
    /// The host sees every camera and records a live program cut of whichever it selects.
    case switcher
    /// The host records; other phones only add events.
    case eventRemote

    var id: Self { self }
    var title: String {
        switch self {
        case .dualCamera: "Two cameras"
        case .switcher: "Multi-cam switcher"
        case .eventRemote: "Event remote"
        }
    }
    var summary: String {
        switch self {
        case .dualCamera: "A second phone records the other half of the pitch. Both videos are joined into one wide view you can zoom around."
        case .switcher: "See every connected camera and pick which one goes into the live cut. Every phone still keeps its own full-quality video."
        case .eventRemote: "This phone records. Other phones tag goals, shots and fouls on the same timeline."
        }
    }
    var symbol: String {
        switch self {
        case .dualCamera: "rectangle.split.2x1"
        case .switcher: "rectangle.3.group"
        case .eventRemote: "dot.radiowaves.left.and.right"
        }
    }
    /// The role a joining phone takes in this mode.
    var peerRole: MultiCamRole { self == .eventRemote ? .remote : .camera }
    var streamsVideo: Bool { self != .eventRemote }
}

// MARK: - Messages

/// Control messages, JSON over the reliable channel. Video packets use `MultiCamVideoPacket`.
/// Every time value is in host-clock seconds (see `MultiCamClockSync`).
enum MultiCamMessage: Codable, Equatable, Sendable {
    /// Peer → host, right after connecting.
    case hello(deviceName: String, deviceID: UUID)
    /// Host → peer: the session it joined and which role it plays.
    case welcome(sessionID: UUID, mode: MultiCamMode, projectID: UUID, projectName: String, hostName: String)
    /// Clock sync round trip. `sentAt` is the peer's local clock; the pong adds host time.
    case clockPing(id: UUID, sentAt: Double)
    case clockPong(id: UUID, sentAt: Double, hostReceivedAt: Double, hostSentAt: Double)
    /// Host → cameras: start a local recording (`recordingID` is chosen by the host so both
    /// libraries agree on the identity) and stream video.
    case startRecording(recordingID: UUID, hostTime: Double)
    case stopRecording(hostTime: Double)
    /// Camera → host: the first video frame is at this host time; alignment uses it.
    case recordingStarted(recordingID: UUID, firstFrameHostTime: Double)
    /// Camera → host, periodically while recording.
    case cameraStatus(isRecording: Bool, elapsedSeconds: Double, batteryLevel: Float, freeMegabytes: Int)
    /// Host → everyone: what the host is doing, so remotes can show a timer.
    case hostStatus(isRecording: Bool, elapsedSeconds: Double)
    /// Host camera capabilities and current values, shown by event remotes.
    case cameraCapabilities(maxZoom: Double, minExposure: Float, maxExposure: Float, zoom: Double, exposure: Float)
    /// Event remote → host camera. Focus coordinates are normalized to the preview.
    case cameraControl(zoom: Double?, focusX: Double?, focusY: Double?, exposure: Float?)
    /// Remote/camera → host: an event tapped at this host time.
    case event(kind: String, hostTime: Double)
    /// Host → camera: the host is about to pull the file; camera answers with `transferReady`.
    case requestTransfer(recordingID: UUID)
    /// Camera → host, before `sendResource`.
    case transferReady(recordingID: UUID, byteCount: Int64, durationSeconds: Double, firstFrameHostTime: Double, deviceName: String)
    /// Host → camera, after the resource landed in the library.
    case transferReceived(recordingID: UUID)
    /// Host → everyone: the session ended; peers should leave.
    case endSession

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> MultiCamMessage { try JSONDecoder().decode(MultiCamMessage.self, from: data) }
}

/// One byte on the wire says what follows, so control JSON and video share the channel.
enum MultiCamWireTag: UInt8 {
    case control = 1, video = 2
}

extension MultiCamMessage {
    func wireData() throws -> Data { Data([MultiCamWireTag.control.rawValue]) + (try encoded()) }
}

// MARK: - Clock sync

/// NTP-style offset estimate: `hostTime = localTime + offset`. Keeps the samples with the
/// shortest round trips because their midpoint is the most trustworthy.
struct MultiCamClockSync: Sendable {
    struct Sample: Sendable { let offset: Double; let roundTrip: Double }
    private(set) var samples: [Sample] = []
    var keeps = 8

    var isSynced: Bool { !samples.isEmpty }
    /// Median offset of the best samples; 0 before any pong arrives.
    var offset: Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.map(\.offset).sorted()
        return sorted[sorted.count / 2]
    }
    /// Half the best round trip: the uncertainty of `offset`.
    var uncertainty: Double { (samples.map(\.roundTrip).min() ?? 0) / 2 }

    mutating func record(sentAt: Double, hostReceivedAt: Double, hostSentAt: Double, receivedAt: Double) {
        let roundTrip = (receivedAt - sentAt) - (hostSentAt - hostReceivedAt)
        guard roundTrip >= 0 else { return }
        let offset = ((hostReceivedAt - sentAt) + (hostSentAt - receivedAt)) / 2
        samples.append(Sample(offset: offset, roundTrip: roundTrip))
        samples.sort { $0.roundTrip < $1.roundTrip }
        if samples.count > keeps { samples.removeLast(samples.count - keeps) }
    }

    func hostTime(forLocal local: Double) -> Double { local + offset }
    func localTime(forHost host: Double) -> Double { host - offset }
}

// MARK: - Switch timeline

/// Which source the switcher's program showed, and from when. Saved with the program video so a
/// full-quality cut can be rebuilt from the local recordings later.
struct MultiCamSwitchTimeline: Codable, Equatable, Sendable {
    struct Cut: Codable, Equatable, Sendable {
        /// Seconds into the program.
        var at: Double
        /// `nil` is the host's own camera; otherwise the camera recording it switched to.
        var recordingID: UUID?
    }
    var cuts: [Cut] = []

    mutating func switchTo(_ recordingID: UUID?, at seconds: Double) {
        if let last = cuts.last {
            if last.recordingID == recordingID { return }
            if last.at >= seconds { cuts[cuts.count - 1].recordingID = recordingID; return }
        }
        cuts.append(Cut(at: max(0, seconds), recordingID: recordingID))
    }

    func source(at seconds: Double) -> UUID? {
        cuts.last { $0.at <= seconds }?.recordingID
    }
}

// MARK: - Alignment

/// Where a camera's recording starts relative to the host's, so the editor and the stitcher can
/// line both up on one timeline. Positive: the camera started later.
enum MultiCamAlignment {
    static func offsetSeconds(cameraFirstFrame: Double, hostFirstFrame: Double) -> Double {
        cameraFirstFrame - hostFirstFrame
    }

    /// The overlapping time range on the host's timeline, or nil when the two never overlap.
    static func sharedRange(hostDuration: Double, cameraDuration: Double, cameraOffset: Double) -> ClosedRange<Double>? {
        let start = max(0, cameraOffset)
        let end = min(hostDuration, cameraOffset + cameraDuration)
        return end > start ? start...end : nil
    }
}

// MARK: - Video packets

/// One compressed H.264 access unit. Keyframes carry SPS/PPS so a receiver can join mid-stream.
struct MultiCamVideoPacket: Equatable, Sendable {
    var presentationHostTime: Double
    var isKeyframe: Bool
    var parameterSets: [Data]
    /// AVCC payload: 4-byte big-endian length before each NAL unit.
    var payload: Data

    func wireData() -> Data {
        var data = Data([MultiCamWireTag.video.rawValue, isKeyframe ? 1 : 0])
        data.append(contentsOf: withUnsafeBytes(of: presentationHostTime.bitPattern.bigEndian, Array.init))
        data.append(UInt8(parameterSets.count))
        for set in parameterSets {
            data.append(contentsOf: withUnsafeBytes(of: UInt16(set.count).bigEndian, Array.init))
            data.append(set)
        }
        data.append(payload)
        return data
    }

    /// Parses a packet after its wire tag; nil for malformed input.
    static func decode(_ data: Data) -> MultiCamVideoPacket? {
        var index = data.startIndex
        func take(_ count: Int) -> Data? {
            guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else { return nil }
            defer { index += count }
            return data[index..<index + count]
        }
        guard let tag = take(1)?.first, tag == MultiCamWireTag.video.rawValue, let flags = take(1)?.first,
              let timeBytes = take(8), let count = take(1)?.first else { return nil }
        let time = Double(bitPattern: UInt64(bigEndian: timeBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }))
        var sets: [Data] = []
        for _ in 0..<Int(count) {
            guard let lengthBytes = take(2) else { return nil }
            let length = Int(UInt16(bigEndian: lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }))
            guard let set = take(length) else { return nil }
            sets.append(Data(set))
        }
        return MultiCamVideoPacket(presentationHostTime: time, isKeyframe: flags & 1 == 1, parameterSets: sets, payload: Data(data[index...]))
    }
}

extension Duration {
    /// Whole seconds plus the fractional part, for clocks that speak in seconds.
    var totalSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
