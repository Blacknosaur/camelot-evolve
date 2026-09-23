import SwiftData
import SwiftUI

/// Turns a session's second-camera video and the main video into one wide recording.
struct MultiCamStitchView: View {
    let camera: Recording
    let recordings: [Recording]
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var finished: MultiCamStitcher.Result?

    /// The host's own video from the same session.
    private var primary: Recording? {
        recordings.first { $0.multiCamSessionID == camera.multiCamSessionID && $0.multiCamRecordingRole == .primary && FileManager.default.fileExists(atPath: $0.fileURL.path()) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                if let primary {
                    LabeledContent("Main camera", value: primary.name.isEmpty ? friendlyDate(primary.recordedAt) : primary.name)
                    LabeledContent("Second camera", value: camera.multiCamDeviceName.isEmpty ? "Camera" : camera.multiCamDeviceName)
                    LabeledContent("Starts", value: String(format: "%+.2f s", camera.multiCamOffsetSeconds))
                    Text("Camelot looks for the overlap between the two views and joins them into one wide frame you can zoom around in the editor. If the views do not overlap, they are placed side by side. Keep the app open; a full match takes a while.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let finished {
                        Label(finished.registered ? "Wide view saved to the project." : "The views did not overlap; saved side by side.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.brand)
                    } else if task != nil {
                        ProgressView(value: progress) { Text(progress == 0 ? "Matching the two views…" : "Rendering \(Int(progress * 100))%") }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Spacer()
                    if finished != nil {
                        Button("Done") { dismiss() }.buttonStyle(.primary)
                    } else if task != nil {
                        Button("Cancel") { task?.cancel() }.buttonStyle(.secondary)
                    } else {
                        Button("Create wide view") { start(primary: primary) }.buttonStyle(.primary).accessibilityIdentifier("multicam-stitch-start")
                    }
                } else {
                    ContentUnavailableView("Main video missing", systemImage: "rectangle.split.2x1",
                        description: Text("The main phone's video from this session is not on this phone."))
                }
            }
            .padding(Theme.Space.lg).readableWidth()
            .navigationTitle("Wide view")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { task?.cancel(); dismiss() }.disabled(task != nil) } }
            .interactiveDismissDisabled(task != nil)
        }
    }

    private func start(primary: Recording) {
        error = nil; progress = 0
        let stitcher = MultiCamStitcher(primaryURL: primary.fileURL, cameraURL: camera.fileURL, cameraOffset: camera.multiCamOffsetSeconds)
        let outputID = UUID()
        let output = FileManager.default.temporaryDirectory.appending(path: "\(outputID.uuidString).mov")
        let sessionID = camera.multiCamSessionID ?? UUID(), deviceName = camera.multiCamDeviceName, projectID = project.id
        task = Task {
            defer { task = nil }
            do {
                let result = try await stitcher.run(to: output) { fraction in Task { @MainActor in progress = fraction } }
                try MultiCamLibrary.save(id: outputID, fileURL: result.url, duration: result.duration, startedAt: primary.recordedAt, projectID: projectID, role: .stitched,
                    sessionID: sessionID, deviceName: deviceName, offsetSeconds: 0, name: "Wide view", modelContext: modelContext)
                finished = result
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                self.error = error.localizedDescription
            }
        }
    }
}
