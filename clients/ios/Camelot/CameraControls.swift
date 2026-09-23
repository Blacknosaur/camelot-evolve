import AVFoundation
import SwiftUI

/// Round translucent icon buttons for the header; lime when the option is active.
struct CameraChromeButtonStyle: ButtonStyle {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 8).frame(minWidth: 34, minHeight: 34)
            .foregroundStyle(isActive ? Color.black : Color.white)
            .background(isActive ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.black.opacity(configuration.isPressed ? 0.6 : 0.35)), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(isActive ? 0 : 0.1), lineWidth: 0.5))
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Red pulsing dot and monospaced elapsed time while recording; amber while paused.
struct CameraTimerCapsule: View {
    let elapsed: Duration
    var isPaused = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(isPaused ? Color.orange : Color.red).frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(pulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            Text(elapsed.formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5))
        .onAppear { pulse = !isPaused }
        .onChange(of: isPaused) { paused in pulse = !paused }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "Recording paused" : "Recording duration")
        .accessibilityValue(elapsed.formatted(.time(pattern: .minuteSecond)))
        .accessibilityIdentifier("camera-recording-time")
    }
}

/// Compact overlays leave the full camera frame visible in either orientation.
struct CameraCaptureDock: View {
    let isRecording: Bool
    let isFinishing: Bool
    let canRecord: Bool
    let mode: CaptureMode
    let tagCounts: [EventKind: Int]
    let lastTag: EventKind?
    let savedCount: Int
    let lastSavedDuration: Double?
    let bufferProgress: Double
    let isLandscape: Bool
    let record: () -> Void
    let mark: (EventKind) -> Void
    var isPaused = false
    var isChangingPause = false
    var supportsPause = false
    var pause: () -> Void = {}

    var body: some View {
        Group {
            if isLandscape {
                HStack(spacing: 12) {
                    captureStatus.frame(width: 88, alignment: .leading)
                    eventStrip.frame(maxWidth: 520)
                    Spacer(minLength: 0)
                    recordButton
                }
            } else {
                VStack(spacing: 6) {
                    eventStrip
                    HStack(spacing: 12) {
                        captureStatus.frame(maxWidth: .infinity, alignment: .leading)
                        recordButton
                        savedStatus.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .foregroundStyle(.white)
        .background { LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera-capture-controls")
    }

    private var eventStrip: some View {
        EventTagStrip(counts: tagCounts, lastTag: lastTag, isEnabled: isRecording && !isFinishing && !isPaused && !isChangingPause,
            accessibilityPrefix: "camera", mark: mark)
    }

    private var captureStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isFinishing ? "Saving…" : isPaused ? "Paused" : isRecording ? "Recording" : mode.shortTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(isRecording ? "\(tagCounts.values.reduce(0, +)) events" : "Ready")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
    }

    private var savedStatus: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label("\(savedCount) saved", systemImage: savedCount == 0 ? "internaldrive" : "checkmark.circle")
                .font(.system(size: 12, weight: .medium, design: .rounded)).lineLimit(1)
            if let lastSavedDuration {
                Text(timecode(lastSavedDuration)).font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
            }
        }.accessibilityElement(children: .combine).accessibilityIdentifier("camera-saved-status")
    }

    private var recordButton: some View {
        HStack(spacing: 10) {
            if isRecording, supportsPause {
                Button(action: pause) {
                    Group {
                        if isChangingPause { ProgressView().tint(.white) }
                        else { Image(systemName: isPaused ? "play.fill" : "pause.fill") }
                    }.frame(width: 24, height: 44)
                }
                .buttonStyle(EditorActionStyle(prominent: isPaused))
                .disabled(isFinishing || isChangingPause)
                .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
                .accessibilityIdentifier("camera-pause")
            }
            CameraRecordButton(isRecording: isRecording, isFinishing: isFinishing, progress: bufferProgress, isEnabled: canRecord, action: record)
        }.frame(height: 64)

    }
}

/// White ring with a red core that morphs into a rounded square while recording. The target
/// shrinks once recording starts so the event row keeps its room.
struct CameraRecordButton: View {
    let isRecording: Bool
    let isFinishing: Bool
    let progress: Double
    let isEnabled: Bool
    let action: () -> Void
    private var outer: CGFloat { isRecording ? 44 : 64 }
    private var inner: CGFloat { isRecording ? 18 : 52 }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(isFinishing ? 0.35 : 0.95), lineWidth: 3)
                    .frame(width: outer - 4, height: outer - 4)
                if isRecording, progress > 0, !isFinishing {
                    Circle().trim(from: 0, to: min(1, max(0, progress)))
                        .stroke(Theme.signal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: outer - 4, height: outer - 4)
                }
                if isFinishing {
                    ProgressView().tint(.white)
                } else {
                    RoundedRectangle(cornerRadius: isRecording ? 5 : inner / 2, style: .continuous)
                        .fill(Color(red: 1, green: 0.23, blue: 0.19))
                        .frame(width: inner, height: inner)
                }
            }
            .frame(width: outer, height: outer)
            .contentShape(Circle())
            .animation(.spring(duration: 0.3, bounce: 0.25), value: isRecording)
        }
        .buttonStyle(RecordPressStyle()).disabled(!isEnabled || isFinishing)
        .opacity(isEnabled || isFinishing ? 1 : 0.45)
        .accessibilityLabel(isFinishing ? "Saving recording" : isRecording ? "Stop recording" : "Start recording")
        .accessibilityIdentifier("camera-record")
    }

    private struct RecordPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

enum CaptureMode: Hashable, CaseIterable, Identifiable {
    case full, rolling5, rolling10
    var id: Self { self }
    var isRolling: Bool { self != .full }
    var bufferSeconds: Double? { switch self { case .full: nil; case .rolling5: 5; case .rolling10: 10 } }
    var shortTitle: String { switch self { case .full: "Full video"; case .rolling5: "Replay 5s"; case .rolling10: "Replay 10s" } }
    var title: String { switch self { case .full: "Full video"; case .rolling5: "Keep 5 seconds before events"; case .rolling10: "Keep 10 seconds before events" } }
}

enum CaptureQuality: String, CaseIterable, Identifiable, Sendable {
    case efficient = "720p", hd = "1080p", ultraHD = "4k"
    var id: Self { self }
    var title: String { switch self { case .efficient: "720p · smaller files"; case .hd: "1080p HD"; case .ultraHD: "4K Ultra HD" } }
    var shortTitle: String { switch self { case .efficient: "720p"; case .hd: "HD"; case .ultraHD: "4K" } }
    var preset: AVCaptureSession.Preset { switch self { case .efficient: .hd1280x720; case .hd: .hd1920x1080; case .ultraHD: .hd4K3840x2160 } }
    static func actual(for preset: AVCaptureSession.Preset) -> Self? { allCases.first { $0.preset == preset } }
}
