import SwiftUI

// MARK: - Tokens

/// Single source of truth for brand colour, spacing and radii.
/// Capture and editing surfaces are always dark; library surfaces follow the saved appearance.
enum Theme {
    /// High-visibility lime used for the primary action on dark capture/editing surfaces.
    static let signal = Color(red: 0.82, green: 1.0, blue: 0.25)
    /// Brand accent for light/system surfaces (lists, forms, buttons).
    static let brand = Color(red: 0.16, green: 0.45, blue: 0.98)
    static let highlight = Color(red: 0.62, green: 0.38, blue: 0.98)

    /// Dark surface stack used by the camera, editor and player.
    static let ink = Color(red: 0.045, green: 0.047, blue: 0.055)
    static let inkPanel = Color(red: 0.085, green: 0.086, blue: 0.1)
    static let inkTimeline = Color(red: 0.065, green: 0.066, blue: 0.077)
    static let inkStroke = Color.white.opacity(0.1)

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 20
        static let hero: CGFloat = 24
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Maximum readable width for forms and single-column content on wide screens.
    static let readableWidth: CGFloat = 520
    /// Minimum tap target (Apple HIG).
    static let tapTarget: CGFloat = 44
}

extension EventKind {
    var tint: Color {
        switch self {
        case .goal: .green
        case .shot: .blue
        case .save: .purple
        case .foul, .card: .orange
        case .note: .gray
        }
    }

    static func tint(for rawKind: String) -> Color {
        EventKind(rawValue: rawKind)?.tint ?? .orange
    }

    static func symbol(for rawKind: String) -> String {
        EventKind(rawValue: rawKind)?.symbol ?? "flag.fill"
    }
}

// MARK: - Adaptive layout

/// Describes the current window so screens can choose a portrait or landscape arrangement.
/// `isLandscape` is decided by the actual window shape, which works on iPhone and iPad alike
/// (size classes are always regular on iPad and would never flip).
struct LayoutMetrics: Equatable {
    let size: CGSize
    let horizontalSizeClass: UserInterfaceSizeClass?
    let verticalSizeClass: UserInterfaceSizeClass?

    var isLandscape: Bool { size.width > size.height }
    /// True for iPad and large phones in landscape: enough room for two columns.
    var isWide: Bool { size.width >= 700 }
    /// Compact height (iPhone landscape): vertical space is scarce.
    var isShort: Bool { verticalSizeClass == .compact || size.height < 500 }
    var isRegularWidth: Bool { horizontalSizeClass == .regular }

    /// Number of grid columns for card grids.
    var gridColumns: Int {
        if size.width >= 1100 { return 4 }
        if size.width >= 760 { return 3 }
        if size.width >= 520 { return 2 }
        return 1
    }
}

/// Measures the available space once and hands `LayoutMetrics` to its content.
struct AdaptiveLayout<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewBuilder let content: (LayoutMetrics) -> Content

    var body: some View {
        GeometryReader { proxy in
            content(LayoutMetrics(size: proxy.size, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Lays children out horizontally in landscape and vertically in portrait.
struct OrientationStack<Content: View>: View {
    let isLandscape: Bool
    var spacing: CGFloat = 0
    var alignment: Alignment = .center
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isLandscape {
            HStack(alignment: alignment.vertical, spacing: spacing, content: content)
        } else {
            VStack(alignment: alignment.horizontal, spacing: spacing, content: content)
        }
    }
}

// MARK: - Components

/// Small coloured status capsule ("Synced", "Uploading 42%").
struct StatusPill: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2.bold()) }
            Text(text).font(.caption2.bold())
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.14), in: .capsule)
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}

/// Icon + value pair used for counts (duration, events, clips).
struct MetaLabel: View {
    let symbol: String
    let text: String

    init(_ text: String, symbol: String) { self.text = text; self.symbol = symbol }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Round 44pt glass button for overlay controls on video surfaces.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    var isActive = false
    var tint: Color = .white
    var size: CGFloat = Theme.tapTarget
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(isActive ? .black : tint)
                .frame(width: size, height: size)
                .background(isActive ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.black.opacity(0.5)), in: .circle)
                .overlay(Circle().stroke(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Stat tile used in headers ("12 videos").
struct StatTile: View {
    let value: String
    let title: String
    let symbol: String
    var tint: Color = Theme.brand

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(tint)
            Text(value).font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.md)
        .background(.fill.tertiary, in: .rect(cornerRadius: Theme.Radius.medium))
    }
}

/// Filled, full-width primary action.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.brand
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(tint, in: .rect(cornerRadius: Theme.Radius.medium))
            .foregroundStyle(foreground)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Tinted, full-width secondary action.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.brand

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.medium))
            .foregroundStyle(tint)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Compact pill button for dark toolbars (editor, camera).
struct DarkPillButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(isProminent ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.white.opacity(0.1)), in: .capsule)
            .foregroundStyle(isProminent ? .black : .white)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// Card container for library surfaces.
struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.background, in: .rect(cornerRadius: Theme.Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).stroke(.separator.opacity(0.6)))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }

    /// Constrains single-column content to a readable width and centres it.
    func readableWidth(_ width: CGFloat = Theme.readableWidth) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}

/// Header line with a title and optional trailing accessory.
struct SectionTitle<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            accessory()
        }
        .padding(.horizontal, Theme.Space.xs)
    }
}

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

// MARK: - Formatting helpers

func compactDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainder = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
    return String(format: "%d:%02d", minutes, remainder)
}

func byteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Relative or absolute date for list rows ("Today, 14:30" / "12 Sep 2026").
func friendlyDate(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return "Today, \(date.formatted(date: .omitted, time: .shortened))"
    }
    if Calendar.current.isDateInYesterday(date) {
        return "Yesterday, \(date.formatted(date: .omitted, time: .shortened))"
    }
    if Calendar.current.isDateInTomorrow(date) {
        return "Tomorrow, \(date.formatted(date: .omitted, time: .shortened))"
    }
    return date.formatted(date: .abbreviated, time: .shortened)
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
