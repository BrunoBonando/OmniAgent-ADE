import AppKit
import SwiftUI

/// The I/O half of the auth gate: whether it needs showing, and persisting
/// whichever way it resolves — the exact three-key read/write `App.tsx`'s
/// boot effect and `handleAuthGateResolved`/`resetAuthGate` perform, behind
/// `SettingsStore` so it is testable without a socket. `AuthGateState.swift`
/// owns the phase transitions; `AuthGateWindowController` below owns turning
/// this into a sheet on screen.
final class AuthGateCoordinator {
    let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// `true` unless `SettingsKey.authGateResolved` is exactly `"true"`.
    func needsPresenting(completion: @escaping (Bool) -> Void) {
        settings.get(SettingsKey.authGateResolved) { result in
            completion(!AuthGate.alreadyResolved(try? result.get()))
        }
    }

    /// Persists all three keys the gate cares about and completes once every
    /// write has landed (or failed — a write failing here still dismisses
    /// the gate rather than trapping the user behind a broken settings row;
    /// the same "fail open" posture `App.tsx`'s own boot check documents).
    func resolve(_ outcome: AuthGateOutcome, completion: @escaping () -> Void) {
        persist(
            resolved: "true",
            signedIn: outcome.signedIn ? "true" : "false",
            persona: outcome.persona ?? "",
            completion: completion
        )
    }

    /// "Log out" / "Sign in" from the Settings screen's Account section —
    /// clears the persisted outcome so the gate shows again next time
    /// `needsPresenting` is asked, without needing an app relaunch.
    func reset(completion: @escaping () -> Void) {
        persist(resolved: "false", signedIn: "false", persona: "", completion: completion)
    }

    /// The Settings screen's Account section summary line. Two nested
    /// single-key reads rather than `SettingsStore`'s batched `get([String])`
    /// on purpose: `DispatchGroup.notify` always hops a queue turn, even
    /// when every read already answered synchronously (as a test's fake
    /// client does), which would make this resolve one run-loop turn later
    /// than every other read in this file for no real benefit here — two
    /// keys is cheap enough to chain directly.
    func summary(completion: @escaping (String) -> Void) {
        settings.get(SettingsKey.authSignedIn) { [settings] signedInResult in
            let signedInRaw = try? signedInResult.get()
            settings.get(SettingsKey.authPersona) { personaResult in
                let personaRaw = try? personaResult.get()
                completion(AuthGate.describeAuthSummary(signedInRaw: signedInRaw, personaRaw: personaRaw))
            }
        }
    }

    /// Chained rather than fired in parallel behind a `DispatchGroup`, for
    /// the same reason `summary` chains its two reads: `DispatchGroup.notify`
    /// always hops a queue turn, even against a synchronous fake client,
    /// which would make `completion` land a run-loop turn later than every
    /// write actually finished. Three tiny writes in sequence costs nothing
    /// a user would notice.
    private func persist(resolved: String, signedIn: String, persona: String, completion: @escaping () -> Void) {
        settings.set(SettingsKey.authGateResolved, resolved) { [settings] _ in
            settings.set(SettingsKey.authSignedIn, signedIn) { _ in
                settings.set(SettingsKey.authPersona, persona) { _ in
                    completion()
                }
            }
        }
    }
}

/// Dispatches `AuthGateAction`s against the pure reducer and republishes the
/// result for SwiftUI, calling `onResolved` the moment the gate resolves —
/// the thinnest possible bridge between `AuthGateReducer` and `@Published`.
final class AuthGateViewModel: ObservableObject {
    @Published private(set) var state = AuthGateReducer.initial
    var onResolved: ((AuthGateOutcome) -> Void)?

    func send(_ action: AuthGateAction) {
        state = AuthGateReducer.reduce(state, action)
        if state.phase == .resolved, let outcome = state.outcome {
            onResolved?(outcome)
        }
    }
}

/// The gate's two screens — a SwiftUI port of `AuthGate.tsx`'s "login" and
/// "personalize" phases, styled to match the workspace window's own dark
/// palette rather than the system's default light chrome.
struct AuthGateContentView: View {
    @ObservedObject var model: AuthGateViewModel
    @State private var email = ""
    @State private var selectedPersona: String?

    var body: some View {
        Group {
            switch model.state.phase {
            case .login: loginScreen
            case .personalize: personalizeScreen
            case .resolved: Color.clear
            }
        }
        .frame(width: 420)
        .padding(28)
        .background(OmniAgentPalette.background)
        .foregroundStyle(OmniAgentPalette.textPrimary)
    }

    private var loginScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("> sign in (placeholder)_")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(OmniAgentPalette.accent)
            Text("Sign in to OmniAgent")
                .font(.title2.bold())
            Text(
                "This is a stand-in for real sign-in — any email works, nothing leaves this machine, "
                    + "and there's no account behind it yet."
            )
            .font(.subheadline)
            .foregroundStyle(OmniAgentPalette.textSecondary)

            TextField("you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canContinue { model.send(.signIn) } }

            HStack(spacing: 10) {
                Button("Continue") { model.send(.signIn) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
                Button("Continue without signing in") { model.send(.skipLogin) }
            }
        }
    }

    private var canContinue: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var personalizeScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("> getting to know you_")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(OmniAgentPalette.accent)
            Text("What best describes what you'll use OmniAgent for?")
                .font(.title2.bold())
            Text("Doesn't change anything today — just helps get the defaults right later.")
                .font(.subheadline)
                .foregroundStyle(OmniAgentPalette.textSecondary)

            VStack(spacing: 6) {
                ForEach(AuthGate.personaOptions) { option in
                    Button {
                        selectedPersona = option.id
                    } label: {
                        HStack {
                            Text(option.label)
                            Spacer()
                        }
                        .padding(8)
                        .background(
                            selectedPersona == option.id ? OmniAgentPalette.accent.opacity(0.22) : Color.clear
                        )
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Button("Continue") {
                    if let selectedPersona { model.send(.answerSelected(persona: selectedPersona)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPersona == nil)
                Button("Skip this question") { model.send(.skipPersonalize) }
            }
        }
    }
}

/// Shared SwiftUI palette values matching the AppKit workspace's own colors
/// (`WorkspaceWindowController`'s near-black background,
/// `PaneContainerView`'s focused-border blue) — one place so every SwiftUI
/// screen this task adds reads as the same app rather than the system
/// default light/dark theme.
enum OmniAgentPalette {
    static let background = Color(red: 8 / 255, green: 10 / 255, blue: 14 / 255)
    static let panel = Color(red: 14 / 255, green: 17 / 255, blue: 23 / 255)
    static let textPrimary = Color(red: 224 / 255, green: 229 / 255, blue: 237 / 255)
    static let textSecondary = Color(red: 140 / 255, green: 150 / 255, blue: 168 / 255)
    static let accent = Color(red: 65 / 255, green: 132 / 255, blue: 255 / 255)
}

/// Hosts `AuthGateContentView` in a sheet on the workspace window — the
/// native shape of the web's `overlay-backdrop`, which the AppKit side has
/// no equivalent of.
final class AuthGateWindowController {
    private let coordinator: AuthGateCoordinator
    private var sheetWindow: NSWindow?

    init(coordinator: AuthGateCoordinator) {
        self.coordinator = coordinator
    }

    /// Presents only if `SettingsKey.authGateResolved` is not `"true"` yet.
    /// `completion` always runs — immediately if nothing needed showing.
    func presentIfNeeded(over window: NSWindow?, completion: @escaping () -> Void) {
        coordinator.needsPresenting { [weak self] needed in
            guard needed else {
                completion()
                return
            }
            self?.present(over: window, completion: completion)
        }
    }

    /// Unconditionally shows the gate — the Settings screen's Account
    /// section "Sign in" row re-runs the same flow rather than a second one.
    func present(over window: NSWindow?, completion: (() -> Void)? = nil) {
        let model = AuthGateViewModel()
        model.onResolved = { [weak self] outcome in
            guard let self else { return }
            coordinator.resolve(outcome) { [weak self] in
                self?.dismiss()
                completion?()
            }
        }
        let hosting = NSHostingController(rootView: AuthGateContentView(model: model))
        let sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.isReleasedWhenClosed = false
        sheetWindow = sheet
        if let window {
            window.beginSheet(sheet)
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    private func dismiss() {
        guard let sheet = sheetWindow else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        sheetWindow = nil
    }
}
