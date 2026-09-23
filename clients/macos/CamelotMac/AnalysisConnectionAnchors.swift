@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct AnalysisConnectionAnchor: Identifiable {
    let id: Int
    let name: String
    let point: CGPoint?
    let lastSeen: PlayerMotionSample?
    let isMissing: Bool
    var title: String { "\(id + 1) · \(name)" }
}

/// Every endpoint is visible and addressable without opening a nested menu.
struct AnalysisConnectionSelectionStrip: View {
    let anchors: [AnalysisConnectionAnchor]
    let selected: Int?
    let select: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(anchors) { anchor in
                    Button { select(anchor.id) } label: {
                        HStack(spacing: 6) {
                            Text("\(anchor.id + 1)").font(.caption.bold())
                                .frame(width: 24, height: 24).background(.white.opacity(0.08), in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(anchor.name).font(.caption.bold()).lineLimit(1)
                                Label(anchor.isMissing ? "Needs correction" : "Tracked", systemImage: anchor.isMissing ? "exclamationmark.circle" : "checkmark.circle")
                                    .font(.system(size: 9))
                            }
                        }.padding(.horizontal, 8).frame(height: 44)
                            .foregroundStyle(anchor.isMissing ? .orange : Theme.signal)
                            .background(.white.opacity(selected == anchor.id ? 0.12 : 0.04), in: .rect(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel("Correct \(anchor.title), \(anchor.isMissing ? "needs correction" : "tracked")")
                        .accessibilityIdentifier("analysis-correct-anchor-\(anchor.id)")
                }
            }.padding(.horizontal, 8)
        }.scrollIndicators(.hidden).background(Theme.inkPanel)
            .accessibilityIdentifier("analysis-connection-players")
    }
}

extension AnalysisAnnotation {
    func connectionAnchors(at time: Double, library: AnalysisTrackingLibrary?) -> [AnalysisConnectionAnchor] {
        (linkedPlayers ?? []).enumerated().map { index, motion in
            let name = library?.players.first(where: { $0.id == motion.trackID })?.name ?? "Player \(index + 1)"
            let seen = motion.samples.last { sample in
                sample.time <= time + 0.001 && (motion.lostAt.map { sample.time < $0 } ?? true) &&
                !(motion.gaps?.contains { $0.contains(sample.time) } ?? false)
            }
            let current = motion.box(at: time)
            let box = current ?? seen?.box
            var position: CGPoint?
            if let box, let reference = motion.reference, points.indices.contains(index) {
                position = CGPoint(x: box.midX + points[index].x - reference.midX, y: box.maxY + points[index].y - reference.maxY)
            }
            return .init(id: index, name: name, point: position, lastSeen: seen, isMissing: current == nil)
        }
    }
}

/// Editor-only identity markers. Missing positions are explicitly historical;
/// they never leak into rendered/exported connection geometry.
enum AnalysisConnectionAnchorOverlay {
    static func draw(_ anchors: [AnalysisConnectionAnchor], correcting: Int?, frame: CGRect, in context: CGContext) {
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previousContext }
        for anchor in anchors {
            guard let point = anchor.point else { continue }
            let center = CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
            let active = correcting == anchor.id
            let color = active || anchor.isMissing ? NSColor.systemOrange : NSColor(Theme.signal)
            let ring = CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26)
            context.saveGState()
            context.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor); context.fillEllipse(in: ring)
            context.setStrokeColor(color.cgColor); context.setLineWidth(active ? 3 : 2)
            if anchor.isMissing { context.setLineDash(phase: 0, lengths: [3, 2]) }
            context.strokeEllipse(in: ring)
            let text = "\(anchor.id + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: color]
            let size = NSAttributedString(string: text as String, attributes: attributes).size()
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
            if anchor.isMissing {
                let label = "LAST SEEN" as NSString
                let style: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 8), .foregroundColor: NSColor.systemOrange,
                                                          .backgroundColor: NSColor.black.withAlphaComponent(0.8)]
                let size = NSAttributedString(string: label as String, attributes: style).size()
                label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y + 15), withAttributes: style)
            }
            context.restoreGState()
        }
    }
}

struct AnalysisConnectionCorrectionCard: View {
    let anchor: AnalysisConnectionAnchor
    let url: URL
    let clipStart: Double
    let showLastSeen: (Double) -> Void
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit() }
                else { Image(systemName: "person.crop.rectangle").foregroundStyle(.secondary) }
            }.frame(width: 44, height: 58).background(.black, in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text("Reselect \(anchor.title)").font(.caption.bold()).foregroundStyle(.orange)
                if let seen = anchor.lastSeen {
                    Text("Reference: \(timelineTimecode(seen.time - clipStart, includesTenths: true)) · same player")
                        .font(.caption2).foregroundStyle(.secondary)
                } else { Text("Choose the same player for this numbered endpoint.").font(.caption2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let seen = anchor.lastSeen {
                Button("Show last confirmed frame", systemImage: "backward.end") { showLastSeen(seen.time) }
                    .labelStyle(.iconOnly).buttonStyle(AnalysisControlStyle()).accessibilityIdentifier("analysis-anchor-last-seen")
            }
        }.padding(.horizontal, 12).padding(.vertical, 4).background(Theme.inkPanel)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("analysis-connection-correction")
            .task(id: anchor.lastSeen?.time) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        thumbnail = nil
        guard let seen = anchor.lastSeen else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        guard let result = try? await generator.image(at: CMTime(seconds: seen.time, preferredTimescale: 600)), !Task.isCancelled else { return }
        let frame = result.image
        let box = seen.box.insetBy(dx: -seen.box.width * 0.3, dy: -seen.box.height * 0.12).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, let crop = frame.cropping(to: CGRect(x: box.minX * CGFloat(frame.width), y: box.minY * CGFloat(frame.height),
                                                              width: box.width * CGFloat(frame.width), height: box.height * CGFloat(frame.height))) else { return }
        thumbnail = crop
    }
}

struct ConnectionAnchorSurface: NSViewRepresentable {
    let anchors: [AnalysisConnectionAnchor]
    let correcting: Int?
    let frame: CGRect
    func makeNSView(context: Context) -> Surface { let view = Surface(); view.wantsLayer = true; return view }
    func updateNSView(_ view: Surface, context: Context) { view.content = self; view.needsDisplay = true }
    final class Surface: NSView {
        var content: ConnectionAnchorSurface?
        override var isFlipped: Bool { true }
        override func draw(_ rect: CGRect) {
            guard let content, let context = NSGraphicsContext.current?.cgContext else { return }
            AnalysisConnectionAnchorOverlay.draw(content.anchors, correcting: content.correcting, frame: content.frame, in: context)
        }
    }
}