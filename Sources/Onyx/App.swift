import SwiftUI
import AppKit
import RecorderCore

@main
struct OnyxApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updater = UpdaterController(startAutomatically: true)

    init() {
        // Trigger onboarding if either Chantier 1 (onboardingDone) or Chantier 2
        // (onboardingV2Done) hasn't been completed. The window itself decides
        // which step to start at; the flow is a single state machine that
        // fast-forwards through already-completed steps.
        let v1 = UserDefaults.standard.bool(forKey: "onboardingDone")
        let v2 = UserDefaults.standard.bool(forKey: "onboardingV2Done")
        if !(v1 && v2) {
            DispatchQueue.main.async { Self.showOnboarding() }
        }
    }

    var body: some Scene {
        // No keyboard shortcuts anywhere in Onyx (no Carbon global hotkey, no
        // menu/viewer key equivalents): every action is click-only, on purpose —
        // ⌘⇧R was stealing the browser's reload.
        MenuBarExtra {
            MenuBarView(app: appState)
        } label: {
            MenuBarIcon(state: appState.uiState)
        }
        .menuBarExtraStyle(.menu)

        // No `Settings` scene: its system opener (the private
        // `showSettingsWindow:` selector) stopped working on recent macOS, so
        // the window is owned and shown by AppState.showSettings() instead.
    }

    private static func showOnboarding() {
        let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 320),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.center(); win.title = "Onyx — Setup"
        win.contentView = NSHostingView(rootView: OnboardingWindow { win.close() })
        win.makeKeyAndOrderFront(nil)
    }
}
