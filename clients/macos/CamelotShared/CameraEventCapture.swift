import Observation
import SwiftUI

/// Pending windows use the movie's clock, so countdowns pause with captured footage.
@MainActor @Observable
final class CameraEventCapture {
    private(set) var active: [MatchEvent] = []
    private(set) var offset: Double = 0
    private var recordingID: UUID?
    var selectedID: UUID?

    var selected: MatchEvent? { active.first { $0.id == selectedID } ?? active.last }

    func add(_ event: MatchEvent) {
        recordingID = event.recordingID
        offset = event.offsetSeconds
        active.append(event)
        selectedID = event.id
    }

    func remaining(for event: MatchEvent) -> Double {
        max(0, event.offsetSeconds + event.postRollSeconds - offset)
    }

    func endOffset(for recordingID: UUID) -> Double? {
        active.filter { $0.recordingID == recordingID }.map { $0.offsetSeconds + $0.postRollSeconds }.max()
    }

    func advance(recordingID: UUID, offset: Double) {
        guard self.recordingID == recordingID, offset.isFinite else { return }
        self.offset = max(self.offset, offset)
        let expired = active.filter { remaining(for: $0) <= 0 }.map(\.id)
        if !expired.isEmpty { active.removeAll { expired.contains($0.id) } }
    }

    @discardableResult
    func endNow(eventID: UUID, recordingID: UUID, offset: Double) -> Bool {
        guard offset.isFinite, let event = active.first(where: { $0.id == eventID && $0.recordingID == recordingID }) else { return false }
        shorten(event, endingAt: offset)
        active.removeAll { $0.id == eventID }
        advance(recordingID: recordingID, offset: offset)
        return true
    }

    /// Stopping or interrupting a recording also closes unfinished event windows.
    func finishSegment(id: UUID, duration: Double) {
        for event in active where event.recordingID == id { shorten(event, endingAt: duration) }
        active.removeAll { $0.recordingID == id }
    }

    private func shorten(_ event: MatchEvent, endingAt offset: Double) {
        let duration = min(event.postRollSeconds, max(0, offset - event.offsetSeconds))
        guard duration != event.postRollSeconds else { return }
        event.postRollSeconds = duration
        event.needsSync = true
        event.mutationID = UUID()
    }
}

struct CameraEventCountdown: View {
    let capture: CameraEventCapture
    let canEnd: Bool
    let end: (UUID) -> Void
    var isPaused = false

    var body: some View {
        if let event = capture.selected {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.white.opacity(0.2), lineWidth: 2)
                    Circle().trim(from: 0, to: min(1, capture.remaining(for: event) / max(0.1, event.postRollSeconds)))
                        .stroke(Theme.signal, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    Image(systemName: EventKind.symbol(for: event.kind)).font(.system(size: 12))
                }.frame(width: 30, height: 30).accessibilityHidden(true)
                Menu {
                    ForEach(capture.active) { active in
                        Button { capture.selectedID = active.id } label: {
                            Text("\(active.kind) · \(Int(ceil(capture.remaining(for: active))))s left")
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(event.kind).font(.system(size: 13, weight: .semibold))
                            if capture.active.count > 1 { Image(systemName: "chevron.down").font(.system(size: 9)) }
                        }
                        Text(isPaused ? "Paused" : capture.active.count > 1 ? "\(capture.active.count) active events" : "Capturing after event")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).disabled(capture.active.count < 2)
                    .accessibilityLabel("Active event").accessibilityValue(event.kind)
                Spacer(minLength: 0)
                Text("\(Int(ceil(capture.remaining(for: event))))s")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText(countsDown: true))
                    .accessibilityLabel("Time remaining").accessibilityValue("\(Int(ceil(capture.remaining(for: event)))) seconds").accessibilityIdentifier("camera-event-countdown")
                Button("End now") { end(event.id) }
                    .buttonStyle(EditorActionStyle()).disabled(!canEnd)
                    .accessibilityLabel("End \(event.kind.lowercased()) now").accessibilityIdentifier("camera-event-end")
            }
            .padding(10).frame(maxWidth: 360)
            .foregroundStyle(.white).background(.black.opacity(0.8), in: .rect(cornerRadius: 14))
            .accessibilityElement(children: .contain)
        }
    }
}
