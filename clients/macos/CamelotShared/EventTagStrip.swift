import SwiftUI

struct EventTagStrip: View {
    var counts: [EventKind: Int] = [:]
    var lastTag: EventKind?
    var isEnabled = true
    let accessibilityPrefix: String
    let mark: (EventKind) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(EventKind.allCases) { kind in
                Button { mark(kind) } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Image(systemName: lastTag == kind ? "checkmark" : kind.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(lastTag == kind ? Color.black : kind.tint)
                            if let count = counts[kind], count > 0 {
                                Text("\(count)").font(.system(size: 9, design: .monospaced)).lineLimit(1)
                            }
                        }
                        Text(kind.rawValue).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }.frame(maxWidth: .infinity).frame(height: 46)
                }
                .buttonStyle(EditorActionStyle(prominent: lastTag == kind))
                .disabled(!isEnabled)
                .accessibilityLabel("Tag \(kind.rawValue.lowercased())")
                .accessibilityValue("\(counts[kind] ?? 0) marked")
                .accessibilityIdentifier("\(accessibilityPrefix)-tag-\(kind.rawValue.lowercased())")
            }
        }
        .background(.black.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}
