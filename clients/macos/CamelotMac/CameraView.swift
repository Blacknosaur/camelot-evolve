@preconcurrency import AVFoundation
import AppKit
import Observation
import SwiftData
import SwiftUI

// MARK: - Capture

struct CameraCaptureView: View {
    let project: Project
    let appState: AppState
    var onClose: (() -> Void)? = nil
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
    @AppStorage("camera.selectedDevice") private var preferredCameraID = ""
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
        .interactiveDismissDisabled(recorder.isRecording || recorder.isFinishing)
        .task { await recorder.prepare(quality: selectedQuality, preferredDeviceID: preferredCameraID.isEmpty ? nil : preferredCameraID) }
        .task {
            while !Task.isCancelled {
                if !eventCapture.active.isEmpty, let id = recorder.activeSegmentID {
                    eventCapture.advance(recordingID: id, offset: recorder.currentOffset)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onDisappear {
            recorder.shutdown()
        }
        .onChange(of: recorder.selectedCameraID) { _, value in preferredCameraID = value ?? "" }
        .onChange(of: recorder.quality) { captureQualityRaw = recorder.quality.rawValue }
        .onChange(of: recorder.isRecording) { _, isRecording in
            appState.isCapturing = isRecording
        }
        .onChange(of: recorder.completedSegments.count) { saveCompletedSegments() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if recorder.isRecording { recorder.stop(reason: "background") }
            } else if phase == .active, !recorder.isReady {
                Task { await recorder.prepare(quality: selectedQuality, preferredDeviceID: preferredCameraID.isEmpty ? nil : preferredCameraID) }
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
            Button { if let onClose { onClose() } else { dismiss() } } label: { Image(systemName: "chevron.left").frame(width: 18) }
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
            cameraPicker
            qualityMenu
            if landscape {
                Button { showsGrid.toggle() } label: { Image(systemName: "grid").frame(width: 18) }
                    .buttonStyle(EditorActionStyle(prominent: showsGrid))
                    .accessibilityLabel("Framing grid").accessibilityValue(showsGrid ? "On" : "Off")
            }
            cameraOptions
        }
        .buttonStyle(EditorActionStyle()).foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 44)
        .background { LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom) }
    }

    /// The one macOS-specific addition: choose which connected camera to record from.
    private var cameraPicker: some View {
        Menu {
            if recorder.availableCameras.isEmpty {
                Text("No cameras found")
            } else {
                ForEach(recorder.availableCameras) { camera in
                    Button {
                        recorder.selectCamera(camera.id)
                    } label: {
                        if recorder.selectedCameraID == camera.id { Label(camera.name, systemImage: "checkmark") }
                        else { Text(camera.name) }
                    }
                }
            }
            Divider()
            Button("Refresh cameras", systemImage: "arrow.clockwise") { recorder.refreshCameras() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "camera")
                Text(recorder.selectedCameraName ?? "Camera").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
        }
        .disabled(recorder.isRecording || recorder.isConfiguring || recorder.isFinishing)
        .accessibilityLabel("Camera").accessibilityValue(recorder.selectedCameraName ?? "None")
        .accessibilityIdentifier("camera-device-picker")
    }

    private var cameraOptions: some View {
        Menu {
            Picker("Recording mode", selection: $captureMode) {
                ForEach(CaptureMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.disabled(!recorder.isReady || recorder.isRecording || recorder.isConfiguring || recorder.isFinishing)
            Toggle(isOn: $showsGrid) { Label("Framing grid", systemImage: "grid") }
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
                        Button("Open Settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { openURL(url) } }
                            .accessibilityIdentifier("camera-open-settings")
                    } else if !recorder.isConfiguring {
                        Button("Try again") { Task { await recorder.prepare(quality: selectedQuality, preferredDeviceID: preferredCameraID.isEmpty ? nil : preferredCameraID) } }
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
        let token = UUID()
        tagFeedbackToken = token
        withAnimation(.snappy(duration: 0.18)) { tagFeedback = kind }
        Task { @MainActor in
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

/// A camera the user can record from. macOS exposes several (built-in, external, Continuity).
struct CameraOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isExternal: Bool
}

@MainActor @Observable
final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let captureQueue = DispatchQueue(label: "com.camelot.capture", qos: .userInitiated)
    private var cameraDevice: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var devicesByID: [String: AVCaptureDevice] = [:]
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
    var supportsPause = false
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
    var availableCameras: [CameraOption] = []
    var selectedCameraID: String?
    var selectedCameraName: String? { availableCameras.first { $0.id == selectedCameraID }?.name }

    func refreshCameras() {
        let discovered = Self.discoverCameras()
        devicesByID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.uniqueID, $0) })
        availableCameras = discovered.map {
            CameraOption(id: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType != .builtInWideAngleCamera)
        }
    }

    func prepare(quality: CaptureQuality, preferredDeviceID: String? = nil) async {
        guard !isReady, !isConfiguring else { return }
        prepareGeneration += 1
        let generation = prepareGeneration
        isConfiguring = true; permissionDenied = false; statusMessage = nil
        refreshCameras()
        let videoAllowed = await AVCaptureDevice.requestAccess(for: .video)
        let audioAllowed = videoAllowed ? await AVCaptureDevice.requestAccess(for: .audio) : false
        guard generation == prepareGeneration else { return }
        guard !Task.isCancelled else { shutdown(); return }
        guard videoAllowed && audioAllowed else {
            permissionDenied = true; isConfiguring = false
            statusMessage = "Allow camera and microphone access to record videos."
            return
        }
        guard let camera = preferredDeviceID.flatMap({ devicesByID[$0] }) ?? devicesByID.values.first else {
            isConfiguring = false
            statusMessage = "No camera was found. Connect a camera and try again."
            return
        }
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                captureQueue.async { [session, output] in
                    do {
                        try Self.configure(session: session, output: output, camera: camera, quality: quality)
                        session.startRunning()
                        let supported = CaptureQuality.allCases.filter { session.canSetSessionPreset($0.preset) }
                        continuation.resume(returning: (camera, supported, CaptureQuality.actual(for: session.sessionPreset) ?? .hd))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            guard generation == prepareGeneration else { return }
            guard !Task.isCancelled else { shutdown(); return }
            cameraDevice = result.0; selectedCameraID = result.0.uniqueID; availableQualities = result.1; self.quality = result.2
            framesPerSecond = 30
            if result.2 != quality { statusMessage = "\(quality.shortTitle) is unavailable. Using \(result.2.title)." }
            refreshZoomCapabilities(for: result.0)
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

    /// Switch the active camera input. Only allowed while idle.
    func selectCamera(_ id: String) {
        guard isReady, !isRecording, !isConfiguring, !isFinishing, id != selectedCameraID,
              let device = devicesByID[id] ?? Self.discoverCameras().first(where: { $0.uniqueID == id }) else { return }
        isConfiguring = true
        let preset = quality.preset
        captureQueue.async { [weak self, session] in
            session.beginConfiguration()
            for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).filter({ $0.device.hasMediaType(.video) }) {
                session.removeInput(input)
            }
            var added = false
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input); added = true
            }
            if added, session.canSetSessionPreset(preset) { session.sessionPreset = preset }
            session.commitConfiguration()
            if added { Self.applyFrameRate(30, to: device) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if added {
                    self.cameraDevice = device
                    self.selectedCameraID = id
                    self.quality = CaptureQuality.actual(for: session.sessionPreset) ?? self.quality
                    self.refreshZoomCapabilities(for: device)
                    self.statusMessage = nil
                } else {
                    self.statusMessage = "Could not switch to \(device.localizedName)."
                }
                self.isConfiguring = false
            }
        }
    }

    nonisolated static func discoverCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        if #available(macOS 13.0, *) { types.append(.deskViewCamera) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    private nonisolated static func configure(session: AVCaptureSession, output: AVCaptureMovieFileOutput, camera: AVCaptureDevice, quality: CaptureQuality) throws {
        session.beginConfiguration()
        do {
            // Reuse an existing microphone input when the session is reconfigured.
            if !session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }),
               let microphone = AVCaptureDevice.default(for: .audio) {
                if let audioInput = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                }
            }
            if !session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.uniqueID == camera.uniqueID }) {
                for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).filter({ $0.device.hasMediaType(.video) }) {
                    session.removeInput(input)
                }
                let videoInput = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(videoInput) else { throw CocoaError(.featureUnsupported) }
                session.addInput(videoInput)
            }
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            camera.unlockForConfiguration()
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
                session.addOutput(output)
            }
            let supported = CaptureQuality.allCases.filter { session.canSetSessionPreset($0.preset) }
            guard let chosen = supported.contains(quality) ? quality : (supported.contains(.hd) ? .hd : supported.first) else { throw CocoaError(.featureUnsupported) }
            session.sessionPreset = chosen.preset
            output.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            session.commitConfiguration()
            applyFrameRate(30, to: camera)
        } catch {
            session.commitConfiguration()
            throw error
        }
    }

    private nonisolated static func zoomDisplayMultiplier(for camera: AVCaptureDevice) -> CGFloat {
        // Hardware zoom ramping is not exposed on macOS capture devices.
        1
    }

    func start(projectID: UUID, mode: CaptureMode) {
        guard isReady, !isConfiguring, !isFinishing, !output.isRecording else { return }
        guard Self.hasRecordingCapacity else {
            statusMessage = "Not enough storage to record safely. Free at least 500 MB and try again."
            return
        }
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
            }
        }
    }

    private func refreshZoomCapabilities(for camera: AVCaptureDevice) {
        // macOS capture devices do not expose hardware zoom factors.
        displayZoomMultiplier = 1
        minimumZoomFactor = 1
        maximumZoomFactor = 1
        zoomFactor = 1
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
    }

    func shutdown() {
        guard !isRecording, !isFinishing, !output.isRecording else { return }
        prepareGeneration += 1
        isConfiguring = false
        timerTask?.cancel(); timerTask = nil
        zoomUpdateTask?.cancel(); zoomUpdateTask = nil; pendingZoomFactor = nil
        NotificationCenter.default.removeObserver(self)
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
        // `AVCaptureMovieFileOutput` pause is unavailable on macOS.
    }

    func stop(reason: String) {
        guard isRecording else { return }
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
    func toggleTorch() { isTorchOn = false }
    private func scheduleZoomUpdate() {
        // macOS capture devices do not expose hardware zoom; keep the UI stable.
        pendingZoomFactor = nil
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
        output.maxRecordedDuration = CMTime(seconds: max(currentOffset + 0.1, endOffset), preferredTimescale: 600)
        return rollingPrevious.map { [$0.id] } ?? []
    }

    func endRollingEventCapture(until endOffset: Double?) {
        guard activeMode.isRolling, rollingWasPromoted, canMarkEvent else { return }
        if let endOffset, endOffset > currentOffset {
            output.maxRecordedDuration = CMTime(seconds: endOffset, preferredTimescale: 600)
        } else {
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

    nonisolated private static func applyFrameRate(_ framesPerSecond: Int32, to camera: AVCaptureDevice) {
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

private struct CameraPreview: NSViewRepresentable {
    let recorder: CameraRecorder
    let showsGrid: Bool
    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(session: recorder.session, attachLayer: recorder.attachPreviewLayer)
        view.onMagnify = { [weak recorder] scale, phase in
            guard let recorder else { return }
            if phase == .began { context.coordinator.startingZoom = recorder.requestedZoomFactor }
            if phase == .changed {
                recorder.setZoom(context.coordinator.startingZoom * scale, publishesValue: false)
            } else if phase == .ended || phase == .cancelled {
                recorder.setZoom(context.coordinator.startingZoom * scale, smoothly: false)
            }
        }
        view.onTap = { [weak recorder] point in
            recorder?.focus(at: point)
        }
        return view
    }
    func updateNSView(_ view: PreviewView, context: Context) {
        view.showsGrid = showsGrid
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var startingZoom: CGFloat = 1
    }
}

private final class PreviewView: NSView {
    private let focusRing = CALayer()
    private let gridLayer = CAShapeLayer()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    var onMagnify: ((CGFloat, NSEvent.Phase) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var showsGrid = false { didSet { if showsGrid != oldValue { needsLayout = true } } }

    func attach(session: AVCaptureSession, attachLayer: @escaping (AVCaptureVideoPreviewLayer) -> Void) {
        wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer()
        preview.videoGravity = .resizeAspect
        preview.session = session
        preview.frame = bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(preview)
        previewLayer = preview
        attachLayer(preview)

        gridLayer.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        gridLayer.lineWidth = 0.7
        gridLayer.fillColor = nil
        layer?.addSublayer(gridLayer)

        focusRing.bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        focusRing.borderWidth = 1.5
        focusRing.borderColor = NSColor(Theme.signal).cgColor
        focusRing.cornerRadius = 8
        focusRing.opacity = 0
        layer?.addSublayer(focusRing)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer?.frame = bounds
        gridLayer.isHidden = !showsGrid
        if showsGrid {
            let rect = (previewLayer?.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)) ?? bounds).intersection(bounds)
            let path = CGMutablePath()
            if !rect.isNull, !rect.isEmpty {
                for index in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(index) / 3
                    let y = rect.minY + rect.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            gridLayer.path = path
        }
        focusRing.frame = CGRect(x: focusRing.frame.midX - 36, y: focusRing.frame.midY - 36, width: 72, height: 72)
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let devicePoint = previewLayer?.captureDevicePointConverted(fromLayerPoint: location) {
            onTap?(devicePoint)
        }
        showFocus(at: location)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(1 + event.magnification, event.phase)
    }

    private func showFocus(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusRing.position = point
        focusRing.opacity = 1
        focusRing.transform = CATransform3DMakeScale(1.25, 1.25, 1)
        CATransaction.commit()
        let settle = CABasicAnimation(keyPath: "transform")
        settle.fromValue = CATransform3DMakeScale(1.25, 1.25, 1)
        settle.toValue = CATransform3DIdentity
        settle.duration = 0.18
        focusRing.add(settle, forKey: "settle")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.55
        fade.duration = 0.25
        focusRing.add(fade, forKey: "fade")
    }
}