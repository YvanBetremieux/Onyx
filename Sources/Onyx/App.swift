import SwiftUI
import AppKit
import RecorderCore

@main
struct OnyxApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updater = UpdaterController(startAutomatically: true)
    @State private var hotkey = GlobalHotkey()

    init() {
        if !UserDefaults.standard.bool(forKey: "onboardingDone") {
            DispatchQueue.main.async { Self.showOnboarding() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(app: appState)
                .onAppear {
                    appState.resumePendingJobs()
                    appState.bootAutotrigger()
                    hotkey.register { Task { @MainActor in appState.toggleRecording() } }
                }
        } label: {
            MenuBarIcon(state: appState.uiState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindow(settings: appState.settings, storage: appState.storage,
                           indexer: appState.indexer)
        }
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
