import SwiftUI

/// Runs an export off the main actor and hands the file to the share sheet.
@MainActor @Observable
final class BoardExportModel {
    var progress = 0.0
    var isRunning = false
    var result: URL?
    var error: String?
    private var task: Task<Void, Never>?

    func run(_ request: BoardExportRequest) {
        cancel()
        progress = 0; result = nil; error = nil; isRunning = true
        let directory = FileManager.default.temporaryDirectory.appending(path: "BoardExports", directoryHint: .isDirectory)
        let model = self
        task = Task.detached(priority: .userInitiated) {
            do {
                let url = try await TacticalBoardExporter.export(request, to: directory) { value in
                    Task { @MainActor in model.report(value) }
                }
                await model.finish(url: url, error: nil)
            } catch {
                await model.finish(url: nil, error: error is CancellationError ? nil : error.localizedDescription)
            }
        }
    }

    /// One hop per frame cannot keep its order, so progress only ever moves forward.
    func report(_ value: Double) {
        guard isRunning, value > progress else { return }
        progress = value
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func finish(url: URL?, error: String?) {
        guard !Task.isCancelled else { return }
        result = url
        self.error = error
        progress = url == nil ? progress : 1
        isRunning = false
    }
}

struct TacticalBoardExportSheet: View {
    let document: BoardDocument
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var format: BoardExportFormat = .png
    @State private var framing: BoardExportFraming = .landscape
    @State private var imageScale: CGFloat = 3
    @State private var model = BoardExportModel()
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(BoardExportFormat.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityLabel("Format")
                    .accessibilityIdentifier("board-export-format")
                }
                Section("Framing") {
                    Picker("Framing", selection: $framing) {
                        ForEach(BoardExportFraming.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if format.isImage {
                        Picker("Resolution", selection: $imageScale) {
                            Text("2x").tag(CGFloat(2))
                            Text("3x").tag(CGFloat(3))
                        }
                        .pickerStyle(.segmented)
                        Text(imageSummary).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(videoSummary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if model.isRunning {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            ProgressView(value: model.progress).tint(Theme.signal)
                                .accessibilityLabel("Export progress")
                                .accessibilityValue("\(Int(model.progress * 100))%")
                            HStack {
                                Text("Exporting \(Int(model.progress * 100))%").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                                Spacer()
                                Button("Cancel", role: .cancel) { model.cancel() }
                                    .font(.footnote.weight(.semibold))
                                    .accessibilityIdentifier("board-export-cancel")
                            }
                        }
                        .accessibilityIdentifier("board-export-progress")
                    } else if let url = model.result {
                        ShareLink(item: url) {
                            Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.signal)
                        .foregroundStyle(.black)
                        .accessibilityIdentifier("board-export-share")
                    } else {
                        Button {
                            model.run(BoardExportRequest(document: document, name: name, format: format, framing: framing, imageScale: imageScale))
                        } label: {
                            Label("Export", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.signal)
                        .foregroundStyle(.black)
                        .accessibilityIdentifier("board-export-run")
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Export board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { model.cancel(); dismiss() } }
            }
            .onChange(of: format) { model.cancel(); model.result = nil }
            .onChange(of: framing) { model.cancel(); model.result = nil }
            .onChange(of: imageScale) { model.cancel(); model.result = nil }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large], selection: $detent)
        .accessibilityIdentifier("board-export-sheet")
    }

    private var imageSummary: String {
        let size = framing.imageSize
        return "\(Int(size.width * imageScale)) × \(Int(size.height * imageScale)) pixels"
    }

    private var videoSummary: String {
        let size = format == .gif ? framing.gifSize : framing.videoSize
        let seconds = TacticalBoardExporter.videoDuration(document)
        let note = document.isAnimated ? "" : " · add frames with Animate for motion"
        return "\(Int(size.width)) × \(Int(size.height)) · \(seconds.formatted(.number.precision(.fractionLength(1)))) s\(note)"
    }
}
