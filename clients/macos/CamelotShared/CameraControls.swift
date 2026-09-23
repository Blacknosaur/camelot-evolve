import SwiftUI

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
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(.white)
        .background { LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera-capture-controls")
    }

    private var eventStrip: some View {
        EventTagStrip(counts: tagCounts, lastTag: lastTag, isEnabled: isRecording && !isFinishing && !isPaused && !isChangingPause,
            accessibilityPrefix: "camera", mark: mark)
    }

    private var captureStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isFinishing ? "Saving…" : isPaused ? "Paused" : isRecording ? "Recording" : mode.shortTitle)
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(isRecording ? "\(tagCounts.values.reduce(0, +)) events" : "Ready to record")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var savedStatus: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Label("\(savedCount) saved", systemImage: savedCount == 0 ? "internaldrive" : "checkmark.circle")
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
            if let lastSavedDuration {
                Text(timecode(lastSavedDuration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
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

struct CameraRecordButton: View {
    let isRecording: Bool
    let isFinishing: Bool
    let progress: Double
    let isEnabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(isFinishing ? 0.35 : 1), lineWidth: 3).frame(width: isRecording ? 36 : 60, height: isRecording ? 36 : 60)
                if isRecording, progress > 0, !isFinishing {
                    Circle().trim(from: 0, to: min(1, max(0, progress)))
                        .stroke(Theme.signal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: isRecording ? 36 : 60, height: isRecording ? 36 : 60)
                }
                if isFinishing { ProgressView().tint(.white) }
                else if isRecording { RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 16, height: 16) }
                else { Circle().fill(.red).frame(width: 48, height: 48) }
            }.frame(width: isRecording ? 44 : 64, height: isRecording ? 44 : 64)
        }
        .buttonStyle(.plain).disabled(!isEnabled || isFinishing)
        .opacity(isEnabled || isFinishing ? 1 : 0.45)
        .accessibilityLabel(isFinishing ? "Saving recording" : isRecording ? "Stop recording" : "Start recording")
        .accessibilityIdentifier("camera-record")
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
