import SwiftUI

/// Matches the editor's compact chrome without shrinking touch targets.
struct AnalysisSheetHeader: View {
    let title: String
    var cancel: (() -> Void)? = nil
    var cancelID = ""
    var actionTitle = "Done"
    var actionID = ""
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let cancel {
                Button("Cancel", systemImage: "xmark", action: cancel).labelStyle(.iconOnly)
                    .accessibilityIdentifier(cancelID)
            }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action).foregroundStyle(Theme.signal).disabled(disabled)
                .accessibilityIdentifier(actionID)
        }.buttonStyle(AnalysisControlStyle()).padding(.horizontal, 10)
            .background(Theme.inkPanel)
    }
}
