import SwiftUI

struct OnboardingView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case create = "Create account", signIn = "Sign in"
        var id: Self { self }
    }

    private enum Field: Hashable { case name, organization, email, password }

    let appState: AppState
    @State private var mode = Mode.create
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var organization = ""
    @State private var showsPassword = false
    @FocusState private var focus: Field?

    var body: some View {
        AdaptiveLayout { layout in
            ScrollView {
                if layout.isLandscape && layout.size.width >= 640 {
                    HStack(alignment: .center, spacing: Theme.Space.xxl) {
                        hero(compact: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        form
                            .frame(maxWidth: Theme.readableWidth)
                    }
                    .padding(Theme.Space.xxl)
                    .frame(minHeight: layout.size.height)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        hero(compact: layout.isShort)
                        form
                    }
                    .padding(Theme.Space.xl)
                    .readableWidth()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
        }
        .onSubmit(advanceFocus)
    }

    // MARK: Hero

    private func hero(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "video.badge.waveform.fill")
                    .font(.system(size: compact ? 26 : 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: compact ? 48 : 64, height: compact ? 48 : 64)
                    .background(Theme.brand.gradient, in: .rect(cornerRadius: Theme.Radius.medium))
                Text("Camelot").font(.title2.bold())
            }
            if !compact {
                Text("Record the match.\nCapture what matters.")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Projects, videos and tagged events stay on this device and sync when you are back online.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: Theme.Space.lg) {
            Picker("Account action", selection: $mode.animation(.snappy)) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(spacing: Theme.Space.md) {
                if mode == .create {
                    FormField(symbol: "person") {
                        TextField("Your name", text: $name)
                            .textContentType(.name)
                            .focused($focus, equals: .name)
                            .submitLabel(.next)
                    }
                    FormField(symbol: "shield") {
                        TextField("Club or organization", text: $organization)
                            .textContentType(.organizationName)
                            .focused($focus, equals: .organization)
                            .submitLabel(.next)
                    }
                }
                FormField(symbol: "envelope") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                }
                FormField(symbol: "lock", hint: passwordHint) {
                    Group {
                        if showsPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textContentType(mode == .create ? .newPassword : .password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                } trailing: {
                    Button { showsPassword.toggle() } label: {
                        Image(systemName: showsPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                            .frame(width: Theme.tapTarget, height: Theme.tapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                }
            }

            if let error = appState.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.md)
                    .background(.red.opacity(0.1), in: .rect(cornerRadius: Theme.Radius.small))
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Button(action: submit) {
                HStack(spacing: Theme.Space.sm) {
                    if appState.isWorking { ProgressView().tint(.white) }
                    Text(mode.rawValue)
                }
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("onboarding-submit")
            .disabled(!canSubmit || appState.isWorking)

            Button("Continue offline") { appState.continueOffline(name: name) }
                .buttonStyle(.secondary)
                .disabled(appState.isWorking)

            VStack(spacing: Theme.Space.sm) {
                ConnectionBadge(state: appState.connectionState)
                if appState.connectionState == .offline {
                    if let issue = appState.connectionIssue {
                        Text(issue).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button("Retry connection", systemImage: "arrow.clockwise") {
                        Task { await appState.checkConnection() }
                    }
                    .font(.footnote.bold())
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Theme.Space.xl)
        .card()
    }

    private var passwordHint: String? {
        guard mode == .create, !password.isEmpty, password.count < 8 else { return nil }
        return "Use at least 8 characters."
    }

    private var canSubmit: Bool {
        !email.isEmpty && password.count >= 8 && (mode == .signIn || (!name.isEmpty && !organization.isEmpty))
    }

    private func advanceFocus() {
        switch focus {
        case .name: focus = .organization
        case .organization: focus = .email
        case .email: focus = .password
        case .password: if canSubmit { submit() }
        case nil: break
        }
    }

    private func submit() {
        focus = nil
        Task {
            if mode == .create {
                await appState.createAccount(name: name, email: email, password: password, organization: organization)
            } else {
                await appState.signIn(email: email, password: password)
            }
        }
    }
}

/// Text field with a leading symbol, optional trailing accessory and inline hint.
private struct FormField<Content: View, Trailing: View>: View {
    let symbol: String
    var hint: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let trailing: () -> Trailing

    init(symbol: String, hint: String? = nil, @ViewBuilder content: @escaping () -> Content, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.symbol = symbol
        self.hint = hint
        self.content = content
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                content()
                trailing()
            }
            .padding(.leading, Theme.Space.md)
            .padding(.trailing, Theme.Space.xs)
            .frame(minHeight: 50)
            .background(.fill.tertiary, in: .rect(cornerRadius: Theme.Radius.small))
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).padding(.leading, Theme.Space.xs)
            }
        }
    }
}

struct ConnectionLabel: View {
    let state: AppState.ConnectionState
    var body: some View { ConnectionBadge(state: state) }
}
