@preconcurrency import AVFoundation
import Observation
import SwiftData
import SwiftUI
import UIKit

// MARK: - Capture

struct CameraCaptureView: View {
    let project: Project
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var recorder = CameraRecorder()
    @State private var eventCapture = CameraEventCapture()
    @State private var showingStopConfirmation = false
    @State private var taggedEvents: [EventKind] = []
    @State private var tagFeedback: EventKind?
    @State private var tagFeedbackToken = UUID()
    @State private var captureMode: CaptureMode = .full
    @AppStorage("camera.showsGrid") private var showsGrid = false
    @State private var lastSavedDuration: Double?
    @State private var savedCount = 0
    @AppStorage("camera.captureQuality") private var captureQualityRaw = CaptureQuality.hd.rawValue

    /// Whether to draw the recording-state chrome (timer, tag buttons). Debug builds can force it
    /// with `-previewRecordingChrome` so screenshot tests can check the layout without a camera.
    private var showsRecordingChrome: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-previewRecordingChrome") { return true }
        #endif
        return recorder.isRecording
    }

    var body: some View {
        AdaptiveLayout { layout in
            // Keep the capture layer at one structural identity in both orientations.
            // Replacing it reconnects AVFoundation during the rotation animation.
            ZStack {
                viewfinder(landscape: layout.isLandscape)
                VStack(spacing: 0) {
                    cameraHeader(landscape: layout.isLandscape)
                    Spacer(minLength: 0)
                    captureDock(isLandscape: layout.isLandscape)
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled(recorder.isRecording || recorder.isFinishing)
        .task { await recorder.prepare(quality: selectedQuality) }
        .task {
            while !Task.isCancelled {
                if !eventCapture.active.isEmpty, let id = recorder.activeSegmentID {
                    eventCapture.advance(recordingID: id, offset: recorder.currentOffset)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onDisappear {
            appState.isCapturing = false
            UIApplication.shared.isIdleTimerDisabled = false
            recorder.shutdown()
        }
        .onChange(of: recorder.quality) { captureQualityRaw = recorder.quality.rawValue }
        .onChange(of: recorder.isRecording) { _, isRecording in
            appState.isCapturing = isRecording
            UIApplication.shared.isIdleTimerDisabled = isRecording
            if !isRecording, scenePhase == .background { recorder.shutdown() }
        }
        .onChange(of: recorder.completedSegments.count) { saveCompletedSegments() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if recorder.isRecording { recorder.stop(reason: "background") }
                else { recorder.shutdown() }
            } else if phase == .active, !recorder.isReady {
                Task { await recorder.prepare(quality: selectedQuality) }
            }
        }
        .alert("Stop recording?", isPresented: $showingStopConfirmation) {
            Button(captureMode.isRolling && taggedEvents.isEmpty ? "Stop buffering" : "Stop and save", role: .destructive) { recorder.stop(reason: "user") }
            Button(recorder.isPaused ? "Stay paused" : "Keep recording", role: .cancel) {}
        } message: {
            Text(captureMode.isRolling && taggedEvents.isEmpty
                 ? "No event was marked. The unused buffer will be discarded."
                 : "Finish and save this recording?")
        }
        .task(id: recorder.statusMessage) {
            guard let message = recorder.statusMessage, message.hasPrefix("Saved ") else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, recorder.statusMessage == message { recorder.statusMessage = nil }
        }
        .alert("Recording interrupted", isPresented: $recorder.showsInterruption) {
            Button("Continue with a new segment") { startSegment() }
            Button("Finish", role: .cancel) {}
        } message: { Text("The completed part was saved safely. You can continue in a new segment and join them later.") }
    }

    private func cameraHeader(landscape: Bool) -> some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 18) }
                .accessibilityLabel("Close camera")
                .disabled(recorder.isRecording || recorder.isFinishing)
            if showsRecordingChrome {
                HStack(spacing: 6) {
                    Circle().fill(recorder.isPaused ? .orange : .red).frame(width: 7, height: 7)
                    Text(recorder.elapsed.formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                }.accessibilityLabel("Recording duration").accessibilityIdentifier("camera-recording-time")
            } else {
                Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            qualityMenu
            if landscape {
                Button { showsGrid.toggle() } label: { Image(systemName: "grid").frame(width: 18) }
                    .buttonStyle(EditorActionStyle(prominent: showsGrid))
                    .accessibilityLabel("Framing grid").accessibilityValue(showsGrid ? "On" : "Off")
                if recorder.hasTorch {
                    Button { recorder.toggleTorch() } label: { Image(systemName: recorder.isTorchOn ? "bolt.fill" : "bolt.slash").frame(width: 18) }
                        .buttonStyle(EditorActionStyle(prominent: recorder.isTorchOn))
                        .disabled(!recorder.isReady || recorder.isFinishing)
                        .accessibilityLabel("Camera light").accessibilityValue(recorder.isTorchOn ? "On" : "Off")
                }
            }
            cameraOptions
        }
        .buttonStyle(EditorActionStyle()).foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 44)
        .background { LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .top) }
    }

    private var cameraOptions: some View {
        Menu {
            Picker("Recording mode", selection: $captureMode) {
                ForEach(CaptureMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.disabled(!recorder.isReady || recorder.isRecording || recorder.isConfiguring || recorder.isFinishing)
            Toggle(isOn: $showsGrid) { Label("Framing grid", systemImage: "grid") }
            if recorder.hasTorch {
                Toggle(isOn: Binding(get: { recorder.isTorchOn }, set: { _ in recorder.toggleTorch() })) {
                    Label("Camera light", systemImage: "bolt")
                }.disabled(!recorder.isReady || recorder.isFinishing)
            }
        } label: { Image(systemName: "slider.horizontal.3").frame(width: 18) }
            .accessibilityLabel("Camera options").accessibilityValue(captureMode.shortTitle)
    }

    private func viewfinder(landscape: Bool) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(recorder: recorder, showsGrid: showsGrid)
                .ignoresSafeArea()
            if !recorder.isReady {
                VStack(spacing: 12) {
                    if recorder.isConfiguring { ProgressView().tint(.white) }
                    else { Image(systemName: recorder.permissionDenied ? "camera.badge.ellipsis" : "camera").font(.title2) }
                    Text(recorder.statusMessage ?? "Preparing camera…")
                        .font(.subheadline).multilineTextAlignment(.center)
                    if recorder.permissionDenied {
                        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                            .accessibilityIdentifier("camera-open-settings")
                    } else if !recorder.isConfiguring {
                        Button("Try again") { Task { await recorder.prepare(quality: selectedQuality) } }
                    }
                }.buttonStyle(EditorActionStyle()).padding(20).background(.black.opacity(0.8), in: .rect(cornerRadius: 12)).padding(20)
            }
            VStack(spacing: 8) {
                CameraEventCountdown(capture: eventCapture, canEnd: recorder.canMarkEvent, end: endEventNow, isPaused: recorder.isPaused)
                if recorder.isReady, let message = recorder.statusMessage {
                    HStack(spacing: 8) {
                        Text(message).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        Button { recorder.statusMessage = nil } label: { Image(systemName: "xmark").frame(width: 30, height: 30) }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss camera message")
                    }.padding(.leading, 12).padding(.trailing, 4).background(.black.opacity(0.75), in: .rect(cornerRadius: 10))
                }
                Spacer(minLength: 0)
                if recorder.isReady {
                    CameraZoomDial(value: recorder.zoomFactor, minimum: recorder.minimumZoomFactor,
                        maximum: recorder.maximumZoomFactor) { value, smooth in
                        recorder.setZoom(value, publishesValue: false, smoothly: smooth)
                    }
                    .disabled(recorder.isFinishing)

                }
            }.padding(.horizontal, 12).padding(.top, 54)
                .padding(.bottom, landscape ? 96 : 142)
        }.foregroundStyle(.white).accessibilityElement(children: .contain).accessibilityIdentifier("camera-viewfinder")
    }

    private func captureDock(isLandscape: Bool) -> some View {
        CameraCaptureDock(isRecording: showsRecordingChrome, isFinishing: recorder.isFinishing,
            canRecord: (recorder.isReady || showsRecordingChrome) && !recorder.isConfiguring && !recorder.isFinishing,
            mode: captureMode, tagCounts: Dictionary(grouping: taggedEvents, by: { $0 }).mapValues(\.count),
            lastTag: tagFeedback, savedCount: savedCount, lastSavedDuration: lastSavedDuration,
            bufferProgress: rollingBufferProgress, isLandscape: isLandscape, record: recordButtonPressed, mark: addEvent,
            isPaused: recorder.isPaused, isChangingPause: recorder.isChangingPause, supportsPause: recorder.supportsPause, pause: recorder.togglePause)
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(recorder.availableQualities) { quality in
                Button { recorder.setQuality(quality) } label: {
                    if recorder.quality == quality { Label(quality.title, systemImage: "checkmark") }
                    else { Text(quality.title) }
                }
            }
            if !recorder.availableQualities.contains(.ultraHD) { Text("4K is not available on this camera") }
        } label: {
            HStack(spacing: 5) {
                if recorder.isConfiguring, recorder.isReady { ProgressView().controlSize(.mini) }
                Text("\(recorder.quality.shortTitle) · \(recorder.framesPerSecond)").monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
        }
        .disabled(!recorder.isReady || recorder.isRecording || recorder.isConfiguring || recorder.isFinishing)
        .accessibilityLabel("Recording quality").accessibilityValue("\(recorder.quality.title), \(recorder.framesPerSecond) fps")
    }

    // MARK: Actions

    private func recordButtonPressed() {
        if showsRecordingChrome { showingStopConfirmation = true }
        else { startSegment() }
    }

    private func startSegment() {
        taggedEvents.removeAll()
        recorder.start(projectID: project.id, mode: captureMode)
        appState.isCapturing = recorder.isRecording
    }

    private func addEvent(_ kind: EventKind) {
        guard let recordingID = recorder.activeSegmentID, recorder.canMarkEvent else { return }
        let event = MatchEvent(projectID: project.id, recordingID: recordingID, kind: kind.rawValue)
        event.offsetSeconds = max(0, recorder.currentOffset)
        event.preRollSeconds = kind.defaultPreRoll
        event.postRollSeconds = kind.defaultPostRoll
        if let seconds = captureMode.bufferSeconds {
            event.preRollSeconds = min(kind.defaultPreRoll, seconds)
        }
        eventCapture.add(event)
        let bufferedIDs = captureMode.isRolling
            ? recorder.promoteRollingBuffer(until: eventCapture.endOffset(for: recordingID) ?? event.offsetSeconds + event.postRollSeconds)
            : []
        event.contextRecordingIDs = (try? String(data: JSONEncoder().encode(bufferedIDs), encoding: .utf8)) ?? "[]"
        modelContext.insert(event)
        taggedEvents.append(kind)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let token = UUID()
        tagFeedbackToken = token
        withAnimation(.snappy(duration: 0.18)) { tagFeedback = kind }
        Task { @MainActor in
            // Let the acknowledgement render before SwiftData performs durable I/O.
            await Task.yield()
            do {
                try modelContext.save()
            } catch {
                try? await Task.sleep(for: .milliseconds(250))
                do {
                    try modelContext.save()
                } catch {
                    recorder.statusMessage = "The event is pending and will be saved with the next change."
                }
            }
            try? await Task.sleep(for: .milliseconds(900))
            guard tagFeedbackToken == token else { return }
            withAnimation(.easeOut(duration: 0.18)) { tagFeedback = nil }
        }
    }

    private func endEventNow(_ id: UUID) {
        guard recorder.canMarkEvent, let recordingID = recorder.activeSegmentID,
              eventCapture.endNow(eventID: id, recordingID: recordingID, offset: recorder.currentOffset) else { return }
        if captureMode.isRolling {
            recorder.endRollingEventCapture(until: eventCapture.endOffset(for: recordingID))
        }
        do { try modelContext.save() }
        catch { recorder.statusMessage = "The shortened event is pending and will be saved with the recording." }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func saveCompletedSegments() {
        let segments = recorder.takeCompletedSegments()
        guard !segments.isEmpty else { return }
        for segment in segments { eventCapture.finishSegment(id: segment.id, duration: segment.duration) }
        let savedSegments = segments.filter { save($0) }
        guard !savedSegments.isEmpty else { return }
        savedCount += savedSegments.count
        lastSavedDuration = savedSegments.last?.duration
        recorder.statusMessage = savedSegments.count == 1
            ? "Saved \(timecode(savedSegments[0].duration)) locally"
            : "Saved \(savedSegments.count) video segments locally"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { await appState.sync(modelContext: modelContext) }
    }

    @discardableResult private func save(_ segment: CompletedSegment) -> Bool {
        do {
            let folder = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
            try RecordingLibrary.prepareMediaDirectory(folder)
            let destination = folder.appending(path: segment.id.uuidString).appendingPathExtension("mov")
            try FileManager.default.moveItem(at: segment.temporaryURL, to: destination)
            let projectID = project.id
            let count = try modelContext.fetchCount(FetchDescriptor<Recording>(
                predicate: #Predicate<Recording> { $0.projectID == projectID }
            ))
            modelContext.insert(Recording(id: segment.id, projectID: project.id, localPath: destination.lastPathComponent, duration: segment.duration, segmentIndex: count, endedReason: segment.reason, recordedAt: segment.startedAt, timezone: TimeZone(identifier: segment.timezoneIdentifier) ?? .current))
            try modelContext.save()
            RecordingRecovery.removeJournal(for: segment.id)
            return true
        } catch {
            recorder.statusMessage = error.localizedDescription
            return false
        }
    }

    private var rollingBufferProgress: Double {
        guard let seconds = captureMode.bufferSeconds, seconds > 0 else { return 0 }
        return min(1, max(0, recorder.currentOffset / seconds))
    }

    private var selectedQuality: CaptureQuality {
        CaptureQuality(rawValue: captureQualityRaw) ?? .hd
    }


}

// MARK: - Controls

enum CaptureQuality: String, CaseIterable, Identifiable, Sendable {
    case efficient = "720p", hd = "1080p", ultraHD = "4k"
    var id: Self { self }
    var title: String { switch self { case .efficient: "720p · smaller files"; case .hd: "1080p HD"; case .ultraHD: "4K Ultra HD" } }
    var shortTitle: String { switch self { case .efficient: "720p"; case .hd: "HD"; case .ultraHD: "4K" } }
    var preset: AVCaptureSession.Preset { switch self { case .efficient: .hd1280x720; case .hd: .hd1920x1080; case .ultraHD: .hd4K3840x2160 } }
    static func actual(for preset: AVCaptureSession.Preset) -> Self? { allCases.first { $0.preset == preset } }
}

struct CompletedSegment: Sendable {
    let id: UUID; let temporaryURL: URL; let duration: Double; let reason: String; let startedAt: Date; let timezoneIdentifier: String
}

@MainActor @Observable
final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let captureQueue = DispatchQueue(label: "com.camelot.capture", qos: .userInitiated)
    private var cameraDevice: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    private var pressureObservation: NSKeyValueObservation?
    private var activeID: UUID?
    private var activeJournal: CaptureJournal?
    private var activeProjectID: UUID?
    private var activeMode: CaptureMode = .full
    private var rollingPrevious: CompletedSegment?
    private var rollingWasPromoted = false
    private var startedAt: Date?
    private var startedTimezoneIdentifier = TimeZone.current.identifier
    private var stopReason = "user"
    private var timerTask: Task<Void, Never>?
    private var zoomUpdateTask: Task<Void, Never>?
    private var pendingZoomFactor: CGFloat?
    private var pendingZoomShouldRamp = false
    private var displayZoomMultiplier: CGFloat = 1
    private var lastZoomUpdateAt = 0.0
    private var storageCheckTick = 0
    private var sessionIsInterrupted = false
    private var interruptedRecordingPending = false
    private var prepareGeneration = 0
    var permissionDenied = false
    var isReady = false
    var isRecording = false
    var isPaused = false
    var isChangingPause = false
    private var accumulatedDuration = 0.0
    var supportsPause: Bool { if #available(iOS 18.0, *) { true } else { false } }
    var elapsed: Duration = .zero
    var completedSegments: [CompletedSegment] = []
    var statusMessage: String?
    var showsInterruption = false
    var zoomFactor: CGFloat = 1
    var minimumZoomFactor: CGFloat = 1
    var maximumZoomFactor: CGFloat = 1
    var quality: CaptureQuality = .hd
    var availableQualities: [CaptureQuality] = []
    var isConfiguring = false
    var isFinishing = false
    var framesPerSecond = 30
    var isTorchOn = false
    var hasTorch: Bool { cameraDevice?.hasTorch == true }
    var activeSegmentID: UUID? { activeID }
    var canMarkEvent: Bool { isRecording && !isFinishing && !isPaused && !isChangingPause && output.isRecording }
    var currentOffset: Double { output.recordedDuration.seconds.isFinite ? output.recordedDuration.seconds : 0 }

    func prepare(quality: CaptureQuality) async {
        guard !isReady, !isConfiguring else { return }
        prepareGeneration += 1
        let generation = prepareGeneration
        isConfiguring = true; permissionDenied = false; statusMessage = nil
        let videoAllowed = await AVCaptureDevice.requestAccess(for: .video)
        let audioAllowed = videoAllowed ? await AVCaptureDevice.requestAccess(for: .audio) : false
        guard generation == prepareGeneration else { return }
        guard !Task.isCancelled else { shutdown(); return }
        guard videoAllowed && audioAllowed else {
            permissionDenied = true; isConfiguring = false
            statusMessage = "Allow camera and microphone access to record videos."
            return
        }
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                captureQueue.async { [session, output] in
                    do {
                        // A suspended camera reuses its inputs and output. Configuring twice
                        // would attempt to add duplicate inputs after returning from Settings.
                        let camera: AVCaptureDevice
                        if let existing = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) {
                            camera = existing.device
                            if session.canSetSessionPreset(quality.preset) {
                                session.beginConfiguration(); session.sessionPreset = quality.preset; session.commitConfiguration()
                                Self.applyFrameRate(30, to: camera)
                            }
                        } else { camera = try Self.configure(session: session, output: output, quality: quality) }
                        session.startRunning()
                        let supported = CaptureQuality.allCases.filter { session.canSetSessionPreset($0.preset) }
                        continuation.resume(returning: (camera, supported, CaptureQuality.actual(for: session.sessionPreset) ?? .hd))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            guard generation == prepareGeneration else { return }
            guard !Task.isCancelled else { shutdown(); return }
            cameraDevice = result.0; availableQualities = result.1; self.quality = result.2
            framesPerSecond = 30
            if result.2 != quality { statusMessage = "\(quality.shortTitle) is unavailable. Using \(result.2.title)." }
            refreshZoomCapabilities(for: result.0)
            configureRotation(); configurePressureMonitoring()
            isReady = true; isConfiguring = false
            NotificationCenter.default.removeObserver(self)
            NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVCaptureSession.wasInterruptedNotification, object: session)
            NotificationCenter.default.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
        } catch {
            guard generation == prepareGeneration else { return }
            isConfiguring = false
            statusMessage = "Could not start the camera: \(error.localizedDescription)"
        }
    }

    private nonisolated static func configure(session: AVCaptureSession, output: AVCaptureMovieFileOutput, quality: CaptureQuality) throws -> AVCaptureDevice {
        session.beginConfiguration()
        do {
            guard let camera = bestRearCamera(),
                  let microphone = AVCaptureDevice.default(for: .audio) else { throw CocoaError(.fileNoSuchFile) }
            let videoInput = try AVCaptureDeviceInput(device: camera)
            let audioInput = try AVCaptureDeviceInput(device: microphone)
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            let frameDuration = CMTime(value: 1, timescale: 30)
            if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                camera.activeVideoMinFrameDuration = frameDuration
                camera.activeVideoMaxFrameDuration = frameDuration
            }
            camera.unlockForConfiguration()
            guard session.canAddInput(videoInput), session.canAddInput(audioInput), session.canAddOutput(output) else {
                throw CocoaError(.featureUnsupported)
            }
            session.addInput(videoInput)
            session.addInput(audioInput)
            session.addOutput(output)
            let supported = CaptureQuality.allCases.filter { session.canSetSessionPreset($0.preset) }
            guard let chosen = supported.contains(quality) ? quality : (supported.contains(.hd) ? .hd : supported.first) else { throw CocoaError(.featureUnsupported) }
            session.sessionPreset = chosen.preset
            output.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            if let connection = output.connection(with: .video) {
                if output.availableVideoCodecTypes.contains(.h264) {
                    output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                } else if output.availableVideoCodecTypes.contains(.hevc) {
                    output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                }
                if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .standard }
            }
            session.commitConfiguration()
            applyFrameRate(30, to: camera)
            return camera
        } catch {
            session.commitConfiguration()
            throw error
        }
    }

    private nonisolated static func bestRearCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private nonisolated static func zoomDisplayMultiplier(for camera: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            return camera.displayVideoZoomFactorMultiplier
        }
        guard camera.deviceType == .builtInTripleCamera || camera.deviceType == .builtInDualWideCamera,
              let firstSwitch = camera.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue,
              firstSwitch > 0 else { return 1 }
        return 1 / CGFloat(firstSwitch)
    }

    func start(projectID: UUID, mode: CaptureMode) {
        guard isReady, !isConfiguring, !isFinishing, !output.isRecording else { return }
        guard Self.hasRecordingCapacity else {
            statusMessage = "Not enough storage to record safely. Free at least 500 MB and try again."
            return
        }
        applyCaptureRotation()
        activeProjectID = projectID; activeMode = mode; rollingWasPromoted = false
        accumulatedDuration = 0; elapsed = .zero; isPaused = false; isChangingPause = false
        startFile(id: UUID())
    }

    func setQuality(_ quality: CaptureQuality) {
        guard isReady, !isRecording, !isConfiguring, !isFinishing, self.quality != quality,
              availableQualities.contains(quality), let cameraDevice else { return }
        isConfiguring = true
        let preset = quality.preset
        let generation = prepareGeneration
        captureQueue.async { [weak self, session] in
            guard session.canSetSessionPreset(preset) else {
                Task { @MainActor in
                    guard self?.prepareGeneration == generation else { return }
                    self?.isConfiguring = false
                    self?.statusMessage = "This camera does not support \(quality.title)."
                }
                return
            }
            session.beginConfiguration()
            session.sessionPreset = preset
            session.commitConfiguration()
            Self.applyFrameRate(30, to: cameraDevice)
            Task { @MainActor in
                guard self?.prepareGeneration == generation else { return }
                self?.quality = CaptureQuality.actual(for: session.sessionPreset) ?? quality
                self?.framesPerSecond = 30
                self?.isConfiguring = false
                self?.statusMessage = nil
                self?.refreshZoomCapabilities(for: cameraDevice)
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }

    private func refreshZoomCapabilities(for camera: AVCaptureDevice) {
        displayZoomMultiplier = Self.zoomDisplayMultiplier(for: camera)
        minimumZoomFactor = camera.minAvailableVideoZoomFactor * displayZoomMultiplier
        maximumZoomFactor = min(camera.maxAvailableVideoZoomFactor * displayZoomMultiplier, 6)
        zoomFactor = min(max(zoomFactor, minimumZoomFactor), maximumZoomFactor)
        setZoom(zoomFactor)
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        guard previewLayer !== layer else { return }
        previewLayer = layer
        configureRotation()
    }

    func shutdown() {
        guard !isRecording, !isFinishing, !output.isRecording else { return }
        prepareGeneration += 1
        isConfiguring = false
        setTorch(false)
        timerTask?.cancel(); timerTask = nil
        zoomUpdateTask?.cancel(); zoomUpdateTask = nil; pendingZoomFactor = nil
        NotificationCenter.default.removeObserver(self)
        rotationObservations.removeAll()
        pressureObservation?.invalidate(); pressureObservation = nil
        rotationCoordinator = nil
        isReady = false
        captureQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func startFile(id: UUID) {
        guard let projectID = activeProjectID else { return }
        activeID = id; startedAt = .now; startedTimezoneIdentifier = TimeZone.current.identifier; stopReason = activeMode.isRolling ? "buffer-rotation" : "user"; statusMessage = nil
        if !activeMode.isRolling { elapsed = .zero; storageCheckTick = 0 }
        do { activeJournal = try RecordingRecovery.create(recordingID: id, projectID: projectID, mode: activeMode.isRolling ? "rolling" : "full") }
        catch { statusMessage = "Could not prepare crash recovery: \(error.localizedDescription)"; return }
        let url = RecordingRecovery.mediaURL(for: id)
        output.maxRecordedDuration = activeMode.bufferSeconds.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
        output.startRecording(to: url, recordingDelegate: self); isRecording = true
        if timerTask == nil {
            timerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    if !isPaused, !isChangingPause { elapsed = .seconds(accumulatedDuration + currentOffset) }
                    storageCheckTick += 1
                    if storageCheckTick.isMultiple(of: 10) {
                        let hasCapacity = await checkRecordingCapacity()
                        guard !Task.isCancelled else { return }
                        if !hasCapacity {
                            statusMessage = "Storage is almost full. Saving the recording now."
                            stop(reason: "low-storage")
                            return
                        }
                    }
                }
            }
        }
    }

    func togglePause() {
        guard #available(iOS 18.0, *), isRecording, !isFinishing, !isChangingPause, output.isRecording else { return }
        isChangingPause = true
        if isPaused { output.resumeRecording() }
        else { output.pauseRecording() }
    }

    @available(iOS 18.0, *)
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didPauseRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor [weak self] in self?.updatePauseState(true, fileURL: fileURL) }
    }

    @available(iOS 18.0, *)
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didResumeRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor [weak self] in self?.updatePauseState(false, fileURL: fileURL) }
    }

    private func updatePauseState(_ paused: Bool, fileURL: URL) {
        guard isRecording, fileURL.deletingPathExtension().lastPathComponent == activeID?.uuidString else { return }
        isPaused = paused; isChangingPause = false
        elapsed = .seconds(accumulatedDuration + currentOffset)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func stop(reason: String) {
        guard isRecording else { return }
        // Record the terminal intent even if MovieFileOutput has already ended a
        // rolling segment and its delegate callback is still in flight.
        stopReason = reason
        isFinishing = true
        if output.isRecording { output.stopRecording() }
    }
    func setZoom(_ factor: CGFloat, publishesValue: Bool = true, smoothly: Bool = false) {
        guard cameraDevice != nil else { return }
        let value = max(minimumZoomFactor, min(factor, maximumZoomFactor))
        if publishesValue { zoomFactor = value }
        pendingZoomFactor = value
        pendingZoomShouldRamp = smoothly
        scheduleZoomUpdate()
    }

    var requestedZoomFactor: CGFloat { pendingZoomFactor ?? zoomFactor }
    func toggleTorch() { setTorch(!isTorchOn) }
    private func setTorch(_ enabled: Bool) {
        guard let cameraDevice, cameraDevice.hasTorch else { isTorchOn = false; return }
        isTorchOn = enabled
        captureQueue.async { [weak self] in
            do {
                try cameraDevice.lockForConfiguration()
                defer { cameraDevice.unlockForConfiguration() }
                if enabled {
                    try cameraDevice.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    cameraDevice.torchMode = .off
                }
            } catch {
                Task { @MainActor in
                    self?.isTorchOn = false
                    self?.statusMessage = "Could not change the torch."
                }
            }
        }
    }
    private func scheduleZoomUpdate() {
        guard zoomUpdateTask == nil else { return }
        let interval = 1.0 / 30.0
        let delay = max(0, interval - (Date.timeIntervalSinceReferenceDate - lastZoomUpdateAt))
        zoomUpdateTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, let cameraDevice = self.cameraDevice,
                  let value = self.pendingZoomFactor else { return }
            self.pendingZoomFactor = nil
            let shouldRamp = self.pendingZoomShouldRamp
            self.pendingZoomShouldRamp = false
            self.lastZoomUpdateAt = Date.timeIntervalSinceReferenceDate
            self.zoomFactor = value
            let displayMultiplier = self.displayZoomMultiplier
            self.captureQueue.async { [weak self] in
                do {
                    try cameraDevice.lockForConfiguration()
                    let hardwareFactor = value / displayMultiplier
                    let target = max(
                        cameraDevice.minAvailableVideoZoomFactor,
                        min(hardwareFactor, cameraDevice.maxAvailableVideoZoomFactor)
                    )
                    if shouldRamp {
                        cameraDevice.ramp(toVideoZoomFactor: target, withRate: 8)
                    } else {
                        cameraDevice.cancelVideoZoomRamp()
                        cameraDevice.videoZoomFactor = target
                    }
                    cameraDevice.unlockForConfiguration()
                } catch {
                    Task { @MainActor in self?.statusMessage = "Could not change zoom." }
                }
            }
            self.zoomUpdateTask = nil
            if self.pendingZoomFactor != nil { self.scheduleZoomUpdate() }
        }
    }
    func focus(at point: CGPoint) {
        guard let cameraDevice else { return }
        captureQueue.async { [weak self] in
            do {
                try cameraDevice.lockForConfiguration()
                defer { cameraDevice.unlockForConfiguration() }
                if cameraDevice.isFocusPointOfInterestSupported {
                    cameraDevice.focusPointOfInterest = point
                    if cameraDevice.isFocusModeSupported(.autoFocus) {
                        cameraDevice.focusMode = .autoFocus
                    } else if cameraDevice.isFocusModeSupported(.continuousAutoFocus) {
                        cameraDevice.focusMode = .continuousAutoFocus
                    }
                }
                if cameraDevice.isExposurePointOfInterestSupported {
                    cameraDevice.exposurePointOfInterest = point
                    if cameraDevice.isExposureModeSupported(.continuousAutoExposure) { cameraDevice.exposureMode = .continuousAutoExposure }
                }
            } catch {
                Task { @MainActor in self?.statusMessage = "Could not focus the camera." }
            }
        }
    }
    func takeCompletedSegments() -> [CompletedSegment] { let values = completedSegments; completedSegments.removeAll(); return values }

    func promoteRollingBuffer(until endOffset: Double) -> [UUID] {
        guard activeMode.isRolling, let journal = activeJournal else { return [] }
        if !rollingWasPromoted {
            rollingWasPromoted = true
            try? RecordingRecovery.markPromoted(journal)
            if let previous = rollingPrevious, let previousJournal = try? journalFor(previous.id) {
                try? RecordingRecovery.markPromoted(previousJournal)
            }
        }
        // Preserve the latest deadline across overlapping events.
        output.maxRecordedDuration = CMTime(seconds: max(currentOffset + 0.1, endOffset), preferredTimescale: 600)
        return rollingPrevious.map { [$0.id] } ?? []
    }

    func endRollingEventCapture(until endOffset: Double?) {
        guard activeMode.isRolling, rollingWasPromoted, canMarkEvent else { return }
        if let endOffset, endOffset > currentOffset {
            output.maxRecordedDuration = CMTime(seconds: endOffset, preferredTimescale: 600)
        } else {
            // Save this promoted segment and resume buffering in the delegate.
            // This is not a request to stop the recording session.
            output.stopRecording()
        }
    }

    private nonisolated static var hasRecordingCapacity: Bool {
        guard let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= 500 * 1_024 * 1_024
    }

    private func checkRecordingCapacity() async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { continuation.resume(returning: Self.hasRecordingCapacity) }
        }
    }

    private func configureRotation() {
        guard let cameraDevice, let previewLayer else { return }
        if rotationCoordinator?.device === cameraDevice, rotationCoordinator?.previewLayer === previewLayer { return }
        rotationObservations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: cameraDevice, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                Task { @MainActor in
                    guard let self, self.rotationCoordinator === coordinator else { return }
                    self.applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
                }
            }
        ]
        // Read the capture angle once when starting a file. Reconfiguring the movie
        // output for every device angle change adds work to the rotation path.
    }

    private func configurePressureMonitoring() {
        guard let cameraDevice else { return }
        pressureObservation?.invalidate()
        pressureObservation = cameraDevice.observe(\.systemPressureState, options: [.new]) { [weak self] camera, change in
            guard let level = change.newValue?.level else { return }
            let framesPerSecond: Int32
            switch level {
            case .serious, .critical, .shutdown:
                framesPerSecond = 24
            default:
                framesPerSecond = 30
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureQueue.async {
                    Self.applyFrameRate(framesPerSecond, to: camera)
                    Task { @MainActor [weak self] in
                        self?.framesPerSecond = Int(framesPerSecond)
                        if framesPerSecond == 24 { self?.statusMessage = "Camera is warm. Recording at 24 fps." }
                    }
                }
            }
        }
    }

    private nonisolated static func applyFrameRate(_ framesPerSecond: Int32, to camera: AVCaptureDevice) {
        let rate = Double(framesPerSecond)
        guard camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= rate && $0.maxFrameRate >= rate
        }) else { return }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            let duration = CMTime(value: 1, timescale: framesPerSecond)
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
        } catch {
            return
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle),
              abs(connection.videoRotationAngle - angle) > 0.01 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        connection.videoRotationAngle = angle
        previewLayer?.superlayer?.setNeedsLayout()
        CATransaction.commit()
    }

    private func applyCaptureRotation() {
        guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
              let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func journalFor(_ id: UUID) throws -> CaptureJournal { try JSONDecoder().decode(CaptureJournal.self, from: Data(contentsOf: RecordingRecovery.journalURL(for: id))) }

    @objc private func interrupted() {
        sessionIsInterrupted = true
        if isRecording { interruptedRecordingPending = true; stop(reason: "interruption") }
    }
    @objc private func interruptionEnded() {
        sessionIsInterrupted = false
        if interruptedRecordingPending, !isRecording {
            interruptedRecordingPending = false
            showsInterruption = true
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let mediaDuration = output.recordedDuration.seconds
        Task { @MainActor [weak self] in
            guard let self, let id = self.activeID else { return }
            self.isRecording = false
            self.isFinishing = false
            self.isPaused = false; self.isChangingPause = false
            let fallbackDuration = self.startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
            let duration = mediaDuration.isFinite && mediaDuration > 0 ? mediaDuration : fallbackDuration
            if let error { self.statusMessage = error.localizedDescription }
            let segment = CompletedSegment(id: id, temporaryURL: outputFileURL, duration: duration, reason: self.stopReason, startedAt: self.startedAt ?? .now, timezoneIdentifier: self.startedTimezoneIdentifier)
            if self.activeMode.isRolling {
                self.accumulatedDuration += duration
                if self.rollingWasPromoted {
                    if let previous = self.rollingPrevious { self.completedSegments.append(previous) }
                    self.completedSegments.append(segment)
                    self.rollingPrevious = nil
                    self.rollingWasPromoted = false
                    if self.stopReason == "buffer-rotation" {
                        self.startFile(id: UUID())
                    } else {
                        self.timerTask?.cancel(); self.timerTask = nil
                    }
                } else if self.stopReason == "user" || self.stopReason == "interruption" || self.stopReason == "background" || self.stopReason == "low-storage" {
                    RecordingRecovery.discard(self.activeJournal ?? CaptureJournal(recordingID: id, projectID: self.activeProjectID ?? UUID(), startedAt: .now, timezoneIdentifier: TimeZone.current.identifier, mode: "rolling", promoted: false, mediaPath: outputFileURL.path()))
                    if let previous = self.rollingPrevious, let journal = try? self.journalFor(previous.id) { RecordingRecovery.discard(journal) }
                    self.rollingPrevious = nil
                    self.timerTask?.cancel(); self.timerTask = nil
                } else {
                    if let previous = self.rollingPrevious, let journal = try? self.journalFor(previous.id) { RecordingRecovery.discard(journal) }
                    self.rollingPrevious = segment
                    self.startFile(id: UUID())
                }
            } else {
                self.completedSegments.append(segment); self.timerTask?.cancel(); self.timerTask = nil
            }
            if self.stopReason == "interruption", !self.sessionIsInterrupted {
                self.interruptedRecordingPending = false
                self.showsInterruption = true
            } else if self.stopReason == "background" {
                self.showsInterruption = true
            }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let recorder: CameraRecorder
    let showsGrid: Bool
    func makeCoordinator() -> Coordinator { Coordinator(recorder: recorder) }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(); view.layerView.session = recorder.session
        recorder.attachPreviewLayer(view.layerView)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:))))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.showsGrid = showsGrid
    }

    @MainActor final class Coordinator: NSObject {
        let recorder: CameraRecorder
        private var startingZoom: CGFloat = 1
        init(recorder: CameraRecorder) { self.recorder = recorder }
        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { startingZoom = recorder.requestedZoomFactor }
            if gesture.state == .changed {
                recorder.setZoom(startingZoom * gesture.scale, publishesValue: false)
            } else if gesture.state == .ended || gesture.state == .cancelled {
                recorder.setZoom(startingZoom * gesture.scale, smoothly: false)
            }
        }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewView else { return }
            let location = gesture.location(in: view)
            recorder.focus(at: view.layerView.captureDevicePointConverted(fromLayerPoint: location))
            view.showFocus(at: location)
        }
    }
}

private final class PreviewView: UIView {
    private let focusRing = UIView()
    private let gridLayer = CAShapeLayer()
    var showsGrid = false { didSet { if showsGrid != oldValue { setNeedsLayout() } } }
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        layerView.videoGravity = .resizeAspect
        gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        gridLayer.lineWidth = 0.7
        gridLayer.fillColor = nil
        layer.addSublayer(gridLayer)
        focusRing.bounds.size = CGSize(width: 72, height: 72)
        focusRing.layer.borderWidth = 1.5
        focusRing.layer.borderColor = UIColor(Theme.signal).cgColor
        focusRing.isUserInteractionEnabled = false
        focusRing.accessibilityIdentifier = "camera-focus-indicator"
        focusRing.layer.cornerRadius = 8
        focusRing.alpha = 0
        addSubview(focusRing)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridLayer.isHidden = !showsGrid
        if showsGrid {
            let rect = layerView.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)).intersection(bounds)
            let path = UIBezierPath()
            if !rect.isNull, !rect.isEmpty {
                for index in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(index) / 3
                    let y = rect.minY + rect.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            gridLayer.path = path.cgPath
        }
        CATransaction.commit()
    }
    func showFocus(at point: CGPoint) {
        focusRing.layer.removeAllAnimations()
        focusRing.center = point
        focusRing.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        focusRing.alpha = 1
        UIView.animate(withDuration: 0.18, animations: { self.focusRing.transform = .identity }) { _ in
            UIView.animate(withDuration: 0.25, delay: 0.55, options: .curveEaseOut) { self.focusRing.alpha = 0 }
        }
    }
}
