import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "app.appearance"
    case system, light, dark
    var id: Self { self }
    var title: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    var symbol: String { switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" } }
}

struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    func body(content: Content) -> some View { content.preferredColorScheme(appearance.colorScheme) }
}

struct AppearancePicker: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    var body: some View {
        Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { option in
                Label(option.title, systemImage: option.symbol).tag(option)
            }
        }
        .accessibilityIdentifier("app-appearance-picker")
    }
}
