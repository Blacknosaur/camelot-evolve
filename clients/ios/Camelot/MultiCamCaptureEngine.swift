@preconcurrency import AVFoundation
import CoreImage
import Combine
import UIKit

/// Capture for multi-cam roles. Unlike `CameraRecorder` (movie file output), this one sees every
/// frame, so it can write the local full-quality file, feed the encoder for the host's preview,
/// and — on a switcher host — write the live program cut from its own or a remote camera.
/// Where the engine writes and how it journals for crash recovery; the main app backs this with
/// `RecordingRecovery`, the companion camera app with a plain folder.
protocol MultiCamCaptureStorage: Sendable {
    func mediaURL(for id: UUID) -> URL
    func beginRecording(id: UUID, projectID: UUID, mode: String) throws
    func discardRecording(id: UUID)
}

/// Files under Documents/MultiCamCapture with no journal; the caller moves them on when done.
struct TemporaryCaptureStorage: MultiCamCaptureStorage {
    var directory: URL = URL.documentsDirectory.appending(path: "MultiCamCapture", directoryHint: .isDirectory)
    func mediaURL(for id: UUID) -> URL { directory.appending(path: id.uuidString).appendingPathExtension("mov") }
    func beginRecording(id: UUID, projectID: UUID, mode: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func discardRecording(id: UUID) { try? FileManager.default.removeItem(at: mediaURL(for: id)) }
}

@MainActor
final class MultiCamCaptureEngine: NSObject, ObservableObject {
    struct Finished: Sendable {
        let id: UUID; let url: URL; let duration: Double; let firstFrameHostTime: Double?; let startedAt: Date
    }
    struct FinishedRecording: Sendable {
        let local: Finished
        let program: Finished?
        let switches: MultiCamSwitchTimeline
    }

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let captureQueue = DispatchQueue(label: "com.camelot.multicam.capture", qos: .userInitiated)
    private let sink = MultiCamFrameSink()
    private var camera: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    let storage: MultiCamCaptureStorage
    /// `AVCaptureDevice.RotationCoordinator` on iOS 17; device-orientation notifications before.
    private var rotationCoordinator: AnyObject?
    private var rotationObservation: NSKeyValueObservation?
    private var orientationObserver: NSObjectProtocol?
    private var timerTask: Task<Void, Never>?
    private var activeID: UUID?
    private var programID: UUID?
    private var startedAt = Date.now
    private var switches = MultiCamSwitchTimeline()
    private var programSourceStart = 0.0

    @Published var isReady = false
    @Published var isConfiguring = false
    @Published var isRecording = false
    @Published var isFinishing = false
    @Published var permissionDenied = false
    @Published var statusMessage: String?
    @Published var elapsed: Duration = .zero
    @Published var quality: CaptureQuality = .hd
    @Published var zoomFactor: CGFloat = 1
    @Published var maximumZoomFactor: CGFloat = 1
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = 0...0
    /// Switcher: which source the program is showing right now (nil = this phone).
    @Published private(set) var programSource: UUID?

    /// Set by the owner: maps a capture timestamp (local host clock) to session time.
    var hostTime: @Sendable (Double) -> Double {
        get { sink.hostTime.value }
        set { sink.hostTime.value = newValue }
    }

    var firstFrameHostTime: Double? { sink.firstFrameHostTime.value }
    /// The newest camera frame, for the alignment preview. Sampled, not every frame.
    var latestFrame: CVPixelBuffer? { sink.latestFrame.value }

    init(storage: MultiCamCaptureStorage = TemporaryCaptureStorage()) {
        self.storage = storage
        super.init()
    }

    // MARK: Session

    func prepare(quality: CaptureQuality) async {
        guard !isReady, !isConfiguring else { return }
        isConfiguring = true; permissionDenied = false; statusMessage = nil
        let videoAllowed = await AVCaptureDevice.requestAccess(for: .video)
        let audioAllowed = videoAllowed ? await AVCaptureDevice.requestAccess(for: .audio) : false
        guard videoAllowed, audioAllowed else {
            permissionDenied = true; isConfiguring = false
            statusMessage = "Allow camera and microphone access to record videos."
            return
        }
        do {
            let result: (AVCaptureDevice, CaptureQuality) = try await withCheckedThrowingContinuation { continuation in
                captureQueue.async { [session, videoOutput, audioOutput, sink] in
                    do {
                        session.beginConfiguration()
                        defer { session.commitConfiguration() }
                        guard let camera = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                              let microphone = AVCaptureDevice.default(for: .audio) else { throw CocoaError(.fileNoSuchFile) }
                        if session.inputs.isEmpty {
                            let videoInput = try AVCaptureDeviceInput(device: camera), audioInput = try AVCaptureDeviceInput(device: microphone)
                            guard session.canAddInput(videoInput), session.canAddInput(audioInput) else { throw CocoaError(.featureUnsupported) }
                            session.addInput(videoInput); session.addInput(audioInput)
                            videoOutput.alwaysDiscardsLateVideoFrames = true
                            // Deliver directly on the sink's serial queue. Hopping from the capture
                            // queue used to make delivery look instantaneous to AVFoundation, so
                            // `alwaysDiscardsLateVideoFrames` could not shed load and an unbounded
                            // backlog built up while scaling/encoding multi-cam previews.
                            videoOutput.setSampleBufferDelegate(sink, queue: sink.processingQueue)
                            audioOutput.setSampleBufferDelegate(sink, queue: sink.processingQueue)
                            guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else { throw CocoaError(.featureUnsupported) }
                            session.addOutput(videoOutput); session.addOutput(audioOutput)
                        }
                        let chosen = session.canSetSessionPreset(quality.preset) ? quality : .hd
                        session.sessionPreset = chosen.preset
                        try camera.lockForConfiguration()
                        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
                        let frame = CMTime(value: 1, timescale: 30)
                        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                            camera.activeVideoMinFrameDuration = frame; camera.activeVideoMaxFrameDuration = frame
                        }
                        camera.unlockForConfiguration()
                        if let connection = videoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = .standard
                        }
                        continuation.resume(returning: (camera, chosen))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            captureQueue.async { [session] in if !session.isRunning { session.startRunning() } }
            camera = result.0; self.quality = result.1
            maximumZoomFactor = min(result.0.maxAvailableVideoZoomFactor, 6)
            exposureBiasRange = result.0.minExposureTargetBias...result.0.maxExposureTargetBias
            exposureBias = result.0.exposureTargetBias
            configureRotation()
            isReady = true; isConfiguring = false
        } catch {
            isConfiguring = false
            statusMessage = "Could not start the camera: \(error.localizedDescription)"
        }
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        guard previewLayer !== layer else { return }
        previewLayer = layer
        configureRotation()
    }

    func shutdown() {
        guard !isRecording, !isFinishing else { return }
        timerTask?.cancel(); timerTask = nil
        rotationObservation = nil; rotationCoordinator = nil
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
        orientationObserver = nil
        sink.stopStreaming()
        isReady = false
        captureQueue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    func setZoom(_ factor: CGFloat) {
        guard let camera else { return }
        let value = max(1, min(factor, maximumZoomFactor))
        zoomFactor = value
        captureQueue.async {
            guard (try? camera.lockForConfiguration()) != nil else { return }
            camera.videoZoomFactor = value
            camera.unlockForConfiguration()
        }
    }

    func focus(at point: CGPoint) {
        guard let camera else { return }
        let point = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        captureQueue.async {
            guard (try? camera.lockForConfiguration()) != nil else { return }
            if camera.isFocusPointOfInterestSupported {
                camera.focusPointOfInterest = point
                if camera.isFocusModeSupported(.autoFocus) { camera.focusMode = .autoFocus }
            }
            if camera.isExposurePointOfInterestSupported {
                camera.exposurePointOfInterest = point
                if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            }
            camera.unlockForConfiguration()
        }
    }

    func setExposureBias(_ bias: Float) {
        guard let camera else { return }
        let value = min(exposureBiasRange.upperBound, max(exposureBiasRange.lowerBound, bias))
        exposureBias = value
        captureQueue.async {
            guard (try? camera.lockForConfiguration()) != nil else { return }
            camera.setExposureTargetBias(value, completionHandler: nil)
            camera.unlockForConfiguration()
        }
    }

    // MARK: Streaming

    /// Starts sending a 720p H.264 feed of every frame; safe to call before recording.
    func startStreaming(_ send: @escaping @Sendable (MultiCamVideoPacket) -> Void) { sink.startStreaming(send) }
    func stopStreaming() { sink.stopStreaming() }

    // MARK: Recording

    /// `program`: also write the switcher's live cut (720p) next to the full-quality local file.
    func startRecording(id: UUID, projectID: UUID, program: Bool) {
        guard isReady, !isRecording, !isFinishing else { return }
        guard let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              (values.volumeAvailableCapacityForImportantUsage ?? .max) >= 500 * 1_024 * 1_024 else {
            statusMessage = "Not enough storage to record safely. Free at least 500 MB and try again."
            return
        }
        applyCaptureRotation()
        do {
            try storage.beginRecording(id: id, projectID: projectID, mode: "multicam")
            var programURL: URL?
            if program {
                let programID = UUID()
                try storage.beginRecording(id: programID, projectID: projectID, mode: "multicam-program")
                programURL = storage.mediaURL(for: programID)
                self.programID = programID
            }
            activeID = id; startedAt = .now; elapsed = .zero
            switches = MultiCamSwitchTimeline(); programSource = nil; programSourceStart = 0
            let videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
            let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
            sink.start(localURL: storage.mediaURL(for: id), programURL: programURL, videoSettings: videoSettings, audioSettings: audioSettings)
            isRecording = true
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    self.elapsed = .seconds(self.sink.elapsedSeconds)
                }
            }
        } catch {
            statusMessage = "Could not prepare crash recovery: \(error.localizedDescription)"
        }
    }

    /// Switcher: route the program to a remote camera's frames (`recordingID`) or back to this phone (nil).
    func switchProgram(to source: UUID?) {
        guard programSource != source else { return }
        programSource = source
        switches.switchTo(source, at: sink.elapsedSeconds)
        sink.setProgramSource(source)
    }

    /// Decoded frames from a remote camera; only the program writer consumes them.
    nonisolated func appendRemoteFrame(_ pixelBuffer: CVPixelBuffer, from source: UUID) {
        sink.remoteFrame(pixelBuffer, from: source)
    }

    func stopRecording() async -> FinishedRecording? {
        guard isRecording, let id = activeID else { return nil }
        isFinishing = true
        timerTask?.cancel(); timerTask = nil
        let result = await sink.finish()
        isRecording = false; isFinishing = false
        elapsed = .zero
        let local = Finished(id: id, url: storage.mediaURL(for: id), duration: result.localDuration, firstFrameHostTime: result.firstFrameHostTime, startedAt: startedAt)
        var program: Finished?
        if let programID, let duration = result.programDuration {
            program = Finished(id: programID, url: storage.mediaURL(for: programID), duration: duration, firstFrameHostTime: result.firstFrameHostTime, startedAt: startedAt)
        } else if let programID {
            storage.discardRecording(id: programID)
        }
        activeID = nil; programID = nil
        if let error = result.error { statusMessage = error }
        return FinishedRecording(local: local, program: program, switches: switches)
    }

    // MARK: Rotation

    private func configureRotation() {
        guard let camera, let previewLayer else { return }
        if #available(iOS 17.0, *) {
            if let existing = rotationCoordinator as? AVCaptureDevice.RotationCoordinator, existing.device === camera, existing.previewLayer === previewLayer { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor in self?.rotatePreview(to: angle) }
            }
        } else {
            guard orientationObserver == nil else { return }
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rotatePreview(to: Self.legacyRotationAngle) }
            }
            rotatePreview(to: Self.legacyRotationAngle)
        }
        applyCaptureRotation()
    }

    private func rotatePreview(to angle: CGFloat) {
        guard let connection = previewLayer?.connection, Self.isRotationSupported(angle, on: connection) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        Self.rotate(connection, to: angle)
        CATransaction.commit()
        // The stream and the file follow the phone until recording locks the angle.
        if !isRecording { applyCaptureRotation() }
    }

    private func applyCaptureRotation() {
        let angle: CGFloat
        if #available(iOS 17.0, *), let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
            angle = coordinator.videoRotationAngleForHorizonLevelCapture
        } else {
            angle = Self.legacyRotationAngle
        }
        guard let connection = videoOutput.connection(with: .video), Self.isRotationSupported(angle, on: connection) else { return }
        captureQueue.async { Self.rotate(connection, to: angle) }
    }

    /// Degrees like `videoRotationAngle`: 90 for portrait, 0 / 180 for the two landscapes.
    private static var legacyRotationAngle: CGFloat {
        switch UIDevice.current.orientation {
        case .landscapeLeft: 0
        case .landscapeRight: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }

    private nonisolated static func isRotationSupported(_ angle: CGFloat, on connection: AVCaptureConnection) -> Bool {
        if #available(iOS 17.0, *) { return connection.isVideoRotationAngleSupported(angle) }
        return connection.isVideoOrientationSupported
    }

    private nonisolated static func rotate(_ connection: AVCaptureConnection, to angle: CGFloat) {
        if #available(iOS 17.0, *) {
            if abs(connection.videoRotationAngle - angle) > 0.01 { connection.videoRotationAngle = angle }
        } else {
            let orientation: AVCaptureVideoOrientation = switch angle { case 0: .landscapeRight; case 180: .landscapeLeft; case 270: .portraitUpsideDown; default: .portrait }
            if connection.videoOrientation != orientation { connection.videoOrientation = orientation }
        }
    }
}

// MARK: - Frame sink

/// Runs on the capture queue: writes files, scales, encodes. Remote frames and control changes are
/// funnelled onto the same queue so the writers never see two threads.
final class MultiCamFrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Result: Sendable { let localDuration: Double; let programDuration: Double?; let firstFrameHostTime: Double?; let error: String? }

    let hostTime = LockedValue<@Sendable (Double) -> Double>({ $0 })
    let firstFrameHostTime = LockedValue<Double?>(nil)
    let latestFrame = LockedValue<CVPixelBuffer?>(nil)
    private var frameCounter = 0
    private let elapsed = LockedValue<Double>(0)
    let processingQueue = DispatchQueue(label: "com.camelot.multicam.sink", qos: .userInitiated)
    private var local: MultiCamMovieWriter?
    private var program: MultiCamMovieWriter?
    private var programSource: UUID?
    private let programSourceSnapshot = LockedValue<UUID?>(nil)
    private var programScaler: MultiCamFrameScaler?
    private var encoder: MultiCamVideoEncoder?
    private var streamScaler: MultiCamFrameScaler?
    private var videoSettings: [String: Any]?
    private var audioSettings: [String: Any]?
    private var lastStreamedAt = 0.0
    static let programSize = CGSize(width: 1280, height: 720)

    var elapsedSeconds: Double { elapsed.value }

    func startStreaming(_ send: @escaping @Sendable (MultiCamVideoPacket) -> Void) {
        processingQueue.async { [self] in
            encoder?.invalidate()
            encoder = MultiCamVideoEncoder(onPacket: send)
        }
    }

    func stopStreaming() {
        processingQueue.async { [self] in encoder?.invalidate(); encoder = nil; streamScaler = nil }
    }

    func start(localURL: URL, programURL: URL?, videoSettings: [String: Any]?, audioSettings: [String: Any]?) {
        // Recommended writer settings are plain property lists; they only cross to the sink queue.
        nonisolated(unsafe) let videoSettings = videoSettings, audioSettings = audioSettings
        processingQueue.async { [self] in
            self.videoSettings = videoSettings; self.audioSettings = audioSettings
            firstFrameHostTime.value = nil; elapsed.value = 0
            local = MultiCamMovieWriter(url: localURL, audioSettings: audioSettings)
            program = programURL.map { MultiCamMovieWriter(url: $0, audioSettings: audioSettings) }
            programSource = nil
        }
    }

    func setProgramSource(_ source: UUID?) {
        programSourceSnapshot.value = source
        processingQueue.async { [self] in programSource = source }
    }

    func remoteFrame(_ pixelBuffer: CVPixelBuffer, from source: UUID) {
        // Do not retain and enqueue frames from cameras that are only visible as thumbnails.
        guard programSourceSnapshot.value == source else { return }
        nonisolated(unsafe) let pixelBuffer = pixelBuffer
        processingQueue.async { [self] in
            guard let program, programSource == source else { return }
            let time = CMClockGetTime(CMClockGetHostTimeClock())
            let frame = programFrame(pixelBuffer)
            program.appendVideo(frame, at: time, settings: Self.programSettings(for: frame))
        }
    }

    func finish() async -> Result {
        await withCheckedContinuation { continuation in
            processingQueue.async { [self] in
                let localWriter = local, programWriter = program
                local = nil; program = nil
                Task {
                    let localResult = await localWriter?.finish()
                    let programResult = await programWriter?.finish()
                    continuation.resume(returning: Result(localDuration: localResult?.duration ?? 0, programDuration: programResult?.duration,
                        firstFrameHostTime: self.firstFrameHostTime.value, error: localResult?.error ?? programResult?.error))
                }
            }
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // AVFoundation calls this directly on `processingQueue`, which keeps its late-frame
        // dropping effective instead of allowing a second queue to grow without bound.
        if output is AVCaptureAudioDataOutput { audio(sampleBuffer); return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCounter += 1
        if frameCounter % 10 == 0 { latestFrame.value = pixelBuffer }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let local {
            if firstFrameHostTime.value == nil { firstFrameHostTime.value = hostTime.value(time.seconds) }
            local.appendVideo(sampleBuffer, settings: videoSettings)
            elapsed.value = local.duration
            if let program, programSource == nil {
                let frame = programFrame(pixelBuffer)
                program.appendVideo(frame, at: time, settings: Self.programSettings(for: frame))
            }
        }
        if let encoder, time.seconds - lastStreamedAt >= 1.0 / 15.0 {
            lastStreamedAt = time.seconds
            let size = MultiCamFrameScaler.streamSize(for: pixelBuffer)
            if streamScaler?.size != size { streamScaler = MultiCamFrameScaler(size: size) }
            if let scaled = streamScaler?.scale(pixelBuffer) { encoder.encode(scaled, hostTime: hostTime.value(time.seconds)) }
        }
    }

    private func audio(_ sampleBuffer: CMSampleBuffer) {
        local?.appendAudio(sampleBuffer)
        program?.appendAudio(sampleBuffer)
    }

    private func programFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let size = width >= height ? Self.programSize : CGSize(width: Self.programSize.height, height: Self.programSize.width)
        if CGFloat(width) == size.width, CGFloat(height) == size.height { return pixelBuffer }
        if programScaler?.size != size { programScaler = MultiCamFrameScaler(size: size) }
        return programScaler?.scale(pixelBuffer) ?? pixelBuffer
    }

    private static func programSettings(for frame: CVPixelBuffer) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: CVPixelBufferGetWidth(frame), AVVideoHeightKey: CVPixelBufferGetHeight(frame),
         AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: 30]]
    }
}

// MARK: - Movie writer

/// One fragmented QuickTime file. Inputs are created on the first frame so their dimensions
/// match what actually arrives (rotation, program size).
final class MultiCamMovieWriter: @unchecked Sendable {
    struct Outcome: Sendable { let duration: Double; let error: String? }
    private let writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var lastTime: CMTime?
    private let audioSettings: [String: Any]?
    private(set) var duration = 0.0

    init(url: URL, audioSettings: [String: Any]?) {
        self.audioSettings = audioSettings
        try? FileManager.default.removeItem(at: url)
        writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
        writer?.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, settings: [String: Any]?) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard begin(at: time, settings: settings, pixelBuffer: nil) else { return }
        guard let video, video.isReadyForMoreMediaData else { return }
        if video.append(sampleBuffer) { note(time) }
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime, settings: [String: Any]) {
        guard begin(at: time, settings: settings, pixelBuffer: pixelBuffer) else { return }
        if let lastTime, time <= lastTime { return }
        guard let adaptor, let video, video.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) { note(time) }
    }

    /// Audio before the first video frame is dropped; the session starts at that frame.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard startTime != nil, let audio, audio.isReadyForMoreMediaData else { return }
        audio.append(sampleBuffer)
    }

    func finish() async -> Outcome {
        guard let writer, writer.status == .writing else { return Outcome(duration: duration, error: writer?.error?.localizedDescription) }
        video?.markAsFinished(); audio?.markAsFinished()
        await writer.finishWriting()
        return Outcome(duration: duration, error: writer.error?.localizedDescription)
    }

    private func begin(at time: CMTime, settings: [String: Any]?, pixelBuffer: CVPixelBuffer?) -> Bool {
        guard let writer else { return false }
        if startTime == nil {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            video = input
            if pixelBuffer != nil {
                adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            }
            // Inputs must exist before writing starts, so audio is added here even if no sample arrived yet.
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) { writer.add(audioInput); audio = audioInput }
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        return writer.status == .writing
    }

    private func note(_ time: CMTime) {
        lastTime = time
        if let startTime { duration = (time - startTime).seconds }
    }
}
