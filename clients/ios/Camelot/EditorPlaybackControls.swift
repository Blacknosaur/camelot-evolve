import SwiftUI
import UIKit

/// Shared timeline actions keep analysis and the main editor visually identical.
struct EditorTimelineZoomControls: View {
    let canZoomOut: Bool
    let canZoomIn: Bool
    let zoomOut: () -> Void
    let fit: () -> Void
    let zoomIn: () -> Void
    var fitLabel = "Fit timeline"
    var identifierPrefix = "editor-timeline"

    var body: some View {
        HStack(spacing: 0) {
            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44) }
                .disabled(!canZoomOut).accessibilityLabel("Zoom out timeline").accessibilityIdentifier("\(identifierPrefix)-zoom-out")
            Button(action: fit) { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right").frame(width: 44, height: 44) }
                .accessibilityLabel(fitLabel).accessibilityIdentifier("\(identifierPrefix)-fit")
            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44) }
                .disabled(!canZoomIn).accessibilityLabel("Zoom in timeline").accessibilityIdentifier("\(identifierPrefix)-zoom-in")
        }.font(.system(size: 14, weight: .medium)).buttonStyle(.plain)
    }
}

struct EditorPlaybackControls: View {
    let playback: EditorPlayback
    let feedback: EditorTimelineFeedback
    @Binding var zoom: CGFloat
    var undo: (() -> Void)? = nil
    var redo: (() -> Void)? = nil
    var showsHistory = true
    var addEvent: (() -> Void)? = nil
    var showsEvents = false
    var showsZoom = true
    var fit: (() -> Void)? = nil
    var fitLabel = "Fit clip"
    var body: some View {
        HStack(spacing: 2) {
            if showsHistory {
                Button { undo?() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 44).contentShape(.rect) }
                    .disabled(undo == nil).accessibilityLabel("Undo edit")
                Button { redo?() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 44).contentShape(.rect) }
                    .disabled(redo == nil).accessibilityLabel("Redo edit")
            }
            if let addEvent {
                Button(action: addEvent) {
                    Image(systemName: "flag").frame(width: 36, height: 44).contentShape(.rect)
                        .foregroundStyle(showsEvents ? Theme.signal : .white)
                }.accessibilityLabel(showsEvents ? "Hide event buttons" : "Add event")
                    .accessibilityIdentifier("editor-add-events")
            }
            Spacer(minLength: 0)
            if showsZoom {
                EditorTimelineZoomControls(canZoomOut: zoom > 1, canZoomIn: zoom < maxZoom,
                    zoomOut: { zoom = max(1, zoom / 2); feedback.visibleSeconds = nil },
                    fit: {
                        if let fit { fit() }
                        else { zoom = 1; feedback.visibleSeconds = nil; playback.commitSeek(playback.duration / 2) }
                    }, zoomIn: { zoom = min(maxZoom, zoom * 2); feedback.visibleSeconds = nil },
                    fitLabel: fit == nil ? "Fit entire video" : fitLabel)
            }
        }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 44)
    }
    private var maxZoom: CGFloat { max(1, CGFloat(playback.duration / 2)) }
}

struct EditorSequenceClip: Equatable {
    let segment: EditorSequenceSegment
    let url: URL
    let number: Int
}


struct EditorSequenceEvent: Identifiable {
    let event: MatchEvent
    let clipNumbers: ClosedRange<Int>
    let snapshot: TimelineEventSnapshot
    var id: TimelineEventID { snapshot.id }
    var kind: String { event.kind }
    var note: String { event.note }
    var offsetSeconds: Double { min(snapshot.upperBound, max(snapshot.lowerBound, snapshot.offset)) }
    var clipLabel: String {
        clipNumbers.lowerBound == clipNumbers.upperBound
            ? "Clip \(clipNumbers.lowerBound)"
            : "Clips \(clipNumbers.lowerBound)–\(clipNumbers.upperBound)"
    }

    static func joiningContinuousWindows(_ events: [Self]) -> [Self] {
        var result: [Self] = []
        var lastIndex: [UUID: Int] = [:]
        for occurrence in events {
            let eventID = occurrence.id.eventID
            if let index = lastIndex[eventID],
               let snapshot = result[index].snapshot.joiningContinuousWindow(occurrence.snapshot) {
                result[index] = Self(event: occurrence.event,
                    clipNumbers: result[index].clipNumbers.lowerBound...occurrence.clipNumbers.upperBound,
                    snapshot: snapshot)
            } else {
                lastIndex[eventID] = result.count
                result.append(occurrence)
            }
        }
        return result
    }
}

/// Lightweight transport at the preview edge; playback retains a full 44pt target.
struct EditorPreviewControls: View {
    let playback: EditorPlayback
    let isPreparing: Bool
    let isEnabled: Bool
    let play: () -> Void
    var currentTime: Double? = nil
    var totalTime: Double? = nil
    var timeIdentifier = "timeline-current-time"
    var playIdentifier = "editor-play-pause"
    var previousFrame: (() -> Void)? = nil
    var nextFrame: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let previousFrame {
                Button("Previous frame", systemImage: "backward.frame.fill", action: previousFrame)
                    .labelStyle(.iconOnly).buttonStyle(AnalysisTransportStyle()).disabled(!isEnabled)
                    .accessibilityIdentifier("analysis-previous-frame")
            }
            Button(action: play) {
                ZStack {
                    if isPreparing {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .medium))
                    }
                }.frame(width: 24, height: 44).contentShape(.rect)
            }.buttonStyle(EditorActionStyle())
                .disabled(!isEnabled)
                .accessibilityLabel(isPreparing ? "Preparing preview" : playback.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier(playIdentifier)
            if let nextFrame {
                Button("Next frame", systemImage: "forward.frame.fill", action: nextFrame)
                    .labelStyle(.iconOnly).buttonStyle(AnalysisTransportStyle()).disabled(!isEnabled)
                    .accessibilityIdentifier("analysis-next-frame")
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(timelineTimecode(currentTime ?? playback.currentSeconds, includesTenths: true))
                    .foregroundStyle(.white).accessibilityIdentifier(timeIdentifier)
                Text("/").foregroundStyle(.white.opacity(0.4))
                Text(timelineTimecode(totalTime ?? playback.duration, includesTenths: true))
                    .foregroundStyle(.white.opacity(0.7))
            }.font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.85)
                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
                .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-preview-controls")
    }
}
