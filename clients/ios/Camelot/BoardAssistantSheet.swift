import SwiftUI

/// "Describe the setup": the coach writes what they want, the on-device assistant builds it on a
/// draft, and the board receives it as one undoable change.
struct BoardAssistantSheet: View {
    let document: BoardDocument
    /// Frame new elements are recorded in on animated boards.
    let frame: Int?
    let apply: (_ document: BoardDocument, _ summary: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var request = ""
    @State private var startsFresh: Bool
    @State private var running = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(document: BoardDocument, frame: Int?, apply: @escaping (BoardDocument, String) -> Void) {
        self.document = document; self.frame = frame; self.apply = apply
        _startsFresh = State(initialValue: document.elements.isEmpty)
    }

    static let examples = [
        "4-3-3 against a 4-4-2",
        "5v2 rondo in a 12 m square",
        "Corner from the right with a near-post run",
        "Goal kick: build up from the back",
        "Pressing zone on the left wing",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if let reason = BoardAssistant.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier("board-assistant-unavailable")
                    }
                    TextField("Describe the setup, e.g. a 4-4-2 pressing high", text: $request, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($focused)
                        .padding(12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                        .accessibilityIdentifier("board-assistant-request")
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text("Try").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Self.examples, id: \.self) { example in
                            Button { request = example } label: {
                                Text(example).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).frame(minHeight: 40)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !document.elements.isEmpty {
                        Picker("Board", selection: $startsFresh) {
                            Text("Add to the board").tag(false)
                            Text("Start fresh").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("board-assistant-mode")
                    }
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("board-assistant-error")
                    }
                    Text("Runs on this iPhone with Apple Intelligence. Nothing is sent anywhere. Undo removes the result in one step.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(Theme.Space.lg)
            }
            .background(Theme.inkPanel)
            .navigationTitle("Board assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { task?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if running {
                        ProgressView().accessibilityIdentifier("board-assistant-progress")
                    } else {
                        Button("Create") { create() }.bold()
                            .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || BoardAssistant.unavailableReason != nil)
                            .accessibilityIdentifier("board-assistant-create")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .tint(Theme.signal)
        .onAppear { focused = true }
    }

    private func create() {
        focused = false
        failure = nil
        running = true
        var start = document
        if startsFresh { start.elements = []; start.keyframes = [] }
        let draft = BoardAssistantDraft(document: start, recordingFrame: startsFresh ? nil : frame)
        let text = request
        task = Task {
            defer { running = false }
            do {
                let summary = try await BoardAssistant.run(text, draft: draft)
                try Task.checkCancellation()
                guard !draft.changes.isEmpty else {
                    failure = "The assistant didn't place anything. Try describing the players or area more concretely."
                    return
                }
                apply(draft.document, summary.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
