import SwiftUI

// Design-system pieces that depend on the main app's models; the companion camera app
// shares DesignSystem.swift but not these.

/// Connection status chip shared between onboarding and account.
struct ConnectionBadge: View {
    let state: AppState.ConnectionState

    var body: some View {
        StatusPill(text: title, tint: tint, symbol: symbol)
            .accessibilityLabel(title)
    }

    private var title: String {
        switch state {
        case .checking: "Checking server"
        case .online: "Connected"
        case .offline: "Offline"
        }
    }
    private var symbol: String {
        switch state {
        case .checking: "arrow.triangle.2.circlepath"
        case .online: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        }
    }
    private var tint: Color {
        switch state {
        case .checking: .secondary
        case .online: .green
        case .offline: .orange
        }
    }
}

/// An empty color preserves the event type's default, including older synced events.
enum EventColor: String, CaseIterable, Identifiable {
    case automatic = "", red = "FF6B6B", orange = "FFAA55", yellow = "F5D76E"
    case green = "B6F36A", blue = "6AB7FF", purple = "B89AFF", pink = "FF8CCD"
    var id: String { rawValue }
    var title: String { self == .automatic ? "Auto" : String(describing: self).capitalized }

    static func tint(hex: String, kind: String) -> Color {
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return EventKind.tint(for: kind) }
        return Color(red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

extension MatchEvent {
    var tint: Color { EventColor.tint(hex: colorHex, kind: kind) }
}
