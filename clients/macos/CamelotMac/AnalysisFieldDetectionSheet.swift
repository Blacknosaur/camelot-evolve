@preconcurrency import AVFoundation
import SwiftUI

struct AnalysisFieldDetectionRequest: Identifiable {
    let id = UUID()
    let sourceTime: Double
    let annotationTime: Double
}

struct AnalysisFieldDetectionSheet: View {
    let url: URL
    let seconds: Double
    let apply: ([FieldLineDetection.Segment]) -> Void
    let manual: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var segments: [FieldLineDetection.Segment] = []
    @State private var excluded: Set<Int> = []
    @State private var loading = true
    @State private var error: String?

    private var chosen: [FieldLineDetection.Segment] { segments.filter { !excluded.contains($0.id) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .overlay { preview }
                        .accessibilityIdentifier("analysis-field-detection-preview")
                }
                List {
                    Section {
                        if loading { ProgressView("Detecting markings on this frame…") }
                        else if let error { Text(error).foregroundStyle(.orange) }
                        else if segments.isEmpty { Text("No reliable straight markings found. Try a clearer frame or place the field manually.") }
                        else { Text("Review each segment. Turn off false matches; accepted lines can be reshaped on the timeline.") }
                    } footer: {
                        Text("Experimental · visible straight markings only. This is not pitch calibration and does not yet provide offside, metres or speed measurements.")
                    }
                    if !segments.isEmpty {
                        Section("Detected markings") {
                            ForEach(segments) { segment in
                                Toggle("Line \(segment.id + 1)", isOn: Binding(get: { !excluded.contains(segment.id) }, set: {
                                    if $0 { excluded.remove(segment.id) } else { excluded.insert(segment.id) }
                                })).accessibilityIdentifier("analysis-field-candidate-\(segment.id)")
                            }
                        }
                    }
                    Section {
                        Button("Manual field placement", systemImage: "sportscourt") { manual(); dismiss() }
                            .accessibilityIdentifier("analysis-field-manual")
                    } footer: { Text("Only part of the pitch visible? Align a penalty area or half pitch using numbered reference points.") }
                }
            }
            .navigationTitle("Detect field lines")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use \(chosen.count)") { apply(chosen); dismiss() }
                        .disabled(loading || chosen.isEmpty).accessibilityIdentifier("analysis-field-use")
                }
            }
        }.preferredColorScheme(.dark).tint(Theme.signal)
            .frame(minWidth: 680, minHeight: 640)
            .formStyle(.grouped)
            .task { await detect() }
    }

    private var preview: some View {
        Canvas { context, size in
            for segment in segments {
                let start = CGPoint(x: segment.start.x * size.width, y: segment.start.y * size.height)
                let end = CGPoint(x: segment.end.x * size.width, y: segment.end.y * size.height)
                var path = Path(); path.move(to: start); path.addLine(to: end)
                let enabled = !excluded.contains(segment.id)
                context.stroke(path, with: .color(.black.opacity(0.7)), lineWidth: 5)
                context.stroke(path, with: .color(enabled ? Theme.signal : .gray), style: .init(lineWidth: 2, dash: enabled ? [] : [4, 4]))
                let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)), with: .color(.black))
                context.draw(Text("\(segment.id + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(enabled ? Theme.signal : .gray), at: center)
            }
        }.allowsHitTesting(false)
    }

    private func detect() async {
        do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            try Task.checkCancellation()
            image = frame
            let worker = Task.detached(priority: .userInitiated) { try FieldLineDetection.detect(in: frame) }
            let detected = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            segments = detected; loading = false
        } catch is CancellationError { }
        catch { self.error = "Could not read this frame. Try another position or use manual placement."; loading = false }
    }
}
