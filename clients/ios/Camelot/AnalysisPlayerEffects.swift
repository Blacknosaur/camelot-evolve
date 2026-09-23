import Foundation
import CoreGraphics

/// One player control panel; the resulting layers keep independent timing and
/// editable geometry while sharing the same source track.
struct AnalysisPlayerEffects {
    var ring = true
    var spotlight = false
    var label = false
    var trajectory = false
    var loupe = false
    var loupeStyle = AnnotationLoupeStyle()
    var trajectoryStyle = PlayerTrajectoryStyle()
    var text = "Player"
    var showsSpeed = false
    var textStyle = AnnotationTextStyle(alignment: .center)
    var ringStyle: AnnotationEffect = .radar
    var spotlightStyle: AnnotationEffect = .neon
    var color = AnnotationColor(red: 0.86, green: 1, blue: 0.15)

    init(layers: [AnalysisAnnotation] = [], name: String = "Player") {
        text = name
        guard !layers.isEmpty else { return }
        ring = layers.contains { $0.tool == .player }
        spotlight = layers.contains { $0.tool == .spotlight }
        label = layers.contains { $0.tool == .text }
        trajectory = layers.contains { $0.tool == .trajectory }
        loupe = layers.contains { $0.tool == .loupe }
        loupeStyle = layers.first { $0.tool == .loupe }?.loupeStyle ?? loupeStyle
        trajectoryStyle = layers.first { $0.tool == .trajectory }?.trajectoryStyle ?? trajectoryStyle
        ringStyle = layers.first { $0.tool == .player }?.effect ?? .radar
        spotlightStyle = layers.first { $0.tool == .spotlight }?.effect ?? .neon
        text = layers.first { $0.tool == .text }?.text ?? name
        showsSpeed = layers.first { $0.tool == .text }?.showsSpeed == true
        textStyle = layers.first { $0.tool == .text }?.resolvedTextStyle ?? textStyle
        color = layers.first?.color ?? color
    }

    var tools: [AnalysisDrawingTool] {
        (trajectory ? [.trajectory] : []) + (ring ? [.player] : []) + (spotlight ? [.spotlight] : []) + (loupe ? [.loupe] : []) + (label ? [.text] : [])
    }

    func style(_ mark: inout AnalysisAnnotation) {
        mark.color = color
        switch mark.tool {
        case .player: mark.effect = ringStyle
        case .spotlight: mark.effect = spotlightStyle
        case .text: mark.text = text; mark.textStyle = textStyle; mark.showsSpeed = showsSpeed
        case .trajectory: mark.trajectoryStyle = trajectoryStyle; mark.effect = .clean
        case .loupe: mark.loupeStyle = loupeStyle
        default: break
        }
    }
}

extension CompositionClip {
    mutating func applyPlayerEffects(_ options: AnalysisPlayerEffects, replacing ids: Set<UUID>,
                                     box: CGRect, motion: PlayerMotion?, at time: Double) -> UUID? {
        let existing = annotations.filter { ids.contains($0.id) }
        let groupID = existing.compactMap(\.playerEffectGroupID).first ?? UUID()
        annotations.removeAll { ids.contains($0.id) && $0.isLocked != true && !options.tools.contains($0.tool) }
        var selected: UUID?
        for tool in options.tools {
            let matches = existing.filter { $0.tool == tool }
            if !matches.isEmpty {
                for match in matches {
                    guard let index = annotations.firstIndex(where: { $0.id == match.id }) else { continue }
                    if annotations[index].isLocked != true {
                        options.style(&annotations[index])
                        annotations[index].playerEffectGroupID = groupID
                        annotations[index].playerEffectBox = box
                    }
                    selected = match.id
                }
            } else {
                let points = tool == .text ? [CGPoint(x: box.midX, y: box.minY - 0.02)] : tool == .loupe ? [CGPoint(x: box.midX, y: box.midY)] : [box.origin, CGPoint(x: box.maxX, y: box.maxY)]
                // Effects cover the whole clip. A six-second window from the
                // playhead meant every effect had to be extended by hand before
                // it was useful; trimming one that is too long is the easier
                // edit, and an effect is hidden anyway wherever its player is
                // not tracked.
                var mark = AnalysisAnnotation(tool: tool, points: points, start: startSeconds, end: annotationEnd)
                options.style(&mark)
                mark.playerEffectGroupID = groupID; mark.playerEffectBox = box
                mark.playerMotion = motion?.bound(at: time, smoothing: tool == .text ? 0.95 : nil)
                if tool == .trajectory { mark.trajectoryCameraMotion = trackingLibrary?.camera(at: time) }
                annotations.append(mark); selected = mark.id
            }
        }
        return selected
    }
}
