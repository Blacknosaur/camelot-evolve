import SwiftUI

struct EditorEventBrowser: View {
    let events: [EditorSequenceEvent]
    let duration: Double
    let feedback: EditorTimelineFeedback
    @Binding var selectedID: TimelineEventID?
    @Binding var search: String
    @Binding var kind: String?
    let select: (EditorSequenceEvent) -> Void
    let edit: (EditorSequenceEvent) -> Void
    let delete: (EditorSequenceEvent) -> Void

    private var filtered: [EditorSequenceEvent] {
        events.filter {
            (kind == nil || $0.kind == kind) && (search.isEmpty || $0.kind.localizedStandardContains(search)
                || $0.note.localizedStandardContains(search) || timecode($0.offsetSeconds).localizedStandardContains(search))
        }
    }

    var body: some View {
        let visible = filtered
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search events", text: $search)
                    .font(.system(size: 14)).accessibilityIdentifier("event-search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 44) }
                        .accessibilityLabel("Clear event search")
                }
                Menu {
                    Button("All types") { kind = nil }
                    ForEach(EventKind.allCases) { type in
                        Button { kind = type.rawValue } label: {
                            Label("\(type.rawValue) (\(events.filter { $0.kind == type.rawValue }.count))", systemImage: kind == type.rawValue ? "checkmark" : type.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let kind { Text(kind).lineLimit(1) }
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(kind == nil ? .white.opacity(0.6) : Theme.signal)
                    .frame(minWidth: 32, minHeight: 44).contentShape(.rect)
                }.menuStyle(.borderlessButton).accessibilityLabel("Filter events").accessibilityValue(kind ?? "All types")
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .background(.white.opacity(0.05), in: .rect(cornerRadius: 10))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { event in
                            eventRow(event).id(event.id)
                        }
                    }
                }
                .overlay {
                    if visible.isEmpty {
                        Text(events.isEmpty ? "Find a moment in the video, then add an event." : "No matching events.")
                            .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
                .onAppear {
                    if let selectedID { proxy.scrollTo(selectedID, anchor: .top) }
                }
                .onChange(of: selectedID) {
                    if let selectedID, visible.contains(where: { $0.id == selectedID }) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selectedID, anchor: .top) }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 4)
        .background(Theme.inkPanel)
    }

    private func eventRow(_ event: EditorSequenceEvent) -> some View {
        let selected = selectedID == event.id
        return VStack(spacing: 0) {
            Button { select(event) } label: {
                HStack(spacing: 10) {
                    Image(systemName: EventKind.symbol(for: event.kind))
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(event.event.tint)
                        .frame(width: 30, height: 30)
                        .background(event.event.tint.opacity(0.1), in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(event.kind).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(timelineTimecode(event.offsetSeconds, includesTenths: true))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(selected ? 0.9 : 0.6)).fixedSize()
                        }
                        HStack(spacing: 8) {
                            EditorRangeLabel(feedback: feedback, eventID: event.id, start: event.snapshot.start, end: event.snapshot.end)
                                .lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                            Text(event.clipLabel).fixedSize()
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                        if !event.note.isEmpty {
                            Text(event.note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 10).frame(minHeight: 58).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(event.kind) at \(timecode(event.offsetSeconds))\(event.note.isEmpty ? "" : ", \(event.note)")")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(selected ? "Tap again to deselect" : "Select event")
            if selected {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button { edit(event) } label: { Label("Edit", systemImage: "slider.horizontal.3").frame(minHeight: 44).contentShape(.rect) }
                        .accessibilityLabel("Edit selected event")
                    Button { delete(event) } label: { Image(systemName: "trash").frame(width: 24, height: 44).contentShape(.rect) }
                        .accessibilityLabel("Delete selected event")
                }.buttonStyle(EditorActionStyle()).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(.white.opacity(selected ? 0.065 : 0), in: .rect(cornerRadius: 10))
        .overlay(alignment: .leading) {
            Capsule().fill(event.event.tint).frame(width: 2, height: 22).opacity(selected ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(selected ? 0 : 0.06)).frame(height: 0.5).padding(.leading, 50)
        }
    }
}
