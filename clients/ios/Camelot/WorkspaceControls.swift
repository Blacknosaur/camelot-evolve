import SwiftUI

// Controls shared by the task-first workspaces (Analyse and Boards): large
// labelled tiles, a way out of a selection, and a compact "more" menu label.

/// A large labelled tile: icon above a short word.
struct TaskTileButton: View {
    let title: String
    let symbol: String
    var active = false
    var identifier = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium)).frame(height: 24)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(active ? Theme.ink : .white)
            .background(active ? Theme.signal : .white.opacity(0.07), in: .rect(cornerRadius: Theme.Radius.small))
            .contentShape(.rect)
        }
        .buttonStyle(TilePressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// Shared pressed feedback for tiles and chips.
struct TilePressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Icon and title side by side in bars; icon only when space runs out.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { configuration.icon; configuration.title }
            configuration.icon
        }
    }
}

/// Leaves the current selection and returns to the task tiles.
struct DeselectButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.12), in: .circle)
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done selecting").accessibilityIdentifier("deselect")
    }
}

/// Round "more" button that opens a menu, matching the bar buttons.
struct MoreMenuLabel: View {
    var body: some View {
        Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
            .frame(width: 36, height: 34)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
            .frame(width: 44, height: 44).contentShape(.rect)
            .accessibilityLabel("More")
    }
}
