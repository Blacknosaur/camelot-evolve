@preconcurrency import AVFoundation
import Observation
@preconcurrency import Speech

/// Short spoken descriptions turned into text, on the device when it supports that. Listening stops
/// by itself after a pause, so a coach can speak and then tap Create.
@MainActor
@Observable
final class SpeechDictation {
    private(set) var transcript = ""
    private(set) var isListening = false
    private(set) var message: String?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// Seconds of silence that end listening.
    static let pause: Duration = .seconds(2)

    func toggle(continuing text: String) async {
        if isListening { stop() } else { await start(continuing: text) }
    }

    func start(continuing text: String) async {
        message = nil
        guard await Self.authorized() else {
            message = "Allow Speech Recognition and the microphone for Camelot in Settings to describe by voice."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            message = "Speech recognition isn't available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            Self.feed(engine.inputNode, into: request)
            engine.prepare()
            try engine.start()
            self.engine = engine; self.request = request
            isListening = true
            let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = base
            task = Self.recognize(request, with: recognizer) { [weak self] text, finished in
                Task { @MainActor in
                    guard let self, self.isListening else { return }
                    if let text { self.transcript = base.isEmpty ? text : base + " " + text; self.waitForPause() }
                    if finished { self.stop() }
                }
            }
            waitForPause()
        } catch {
            message = "Couldn't start listening. Try again."
            stop()
        }
    }

    func stop() {
        silence?.cancel(); silence = nil
        guard isListening || engine != nil else { return }
        isListening = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil; request = nil; task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func waitForPause() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    // Audio and recognition callbacks run on their own threads, so they are built outside the main actor.

    nonisolated private static func feed(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func recognize(_ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
                                              update: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, result?.isFinal == true || error != nil)
        }
    }

    nonisolated private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
