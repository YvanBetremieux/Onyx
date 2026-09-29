import SwiftUI
import RecorderCore

struct ViewerRootView: View {
    @ObservedObject var store: ViewerStore
    /// Optionnel : le viewer doit s'afficher même sans AppState (cas
    /// théorique), simplement sans bannière d'alerte.
    let app: AppState?

    var body: some View {
        VStack(spacing: 0) {
            if let app { ClaudeAuthBanner(app: app) }
            HSplitView {
                MeetingsSidebar(store: store)
                MainPanel(
                    store: store,
                    currentDuration: store.currentDurationSeconds,
                    // Resolved by the store (index row, else synthesized from
                    // meta.json) so a meeting with no index row — i.e. the one
                    // currently being recorded — still gets a header instead of the
                    // "nothing selected" empty state.
                    currentSourceListing: store.currentListing
                )
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(.thickMaterial)
        // No window-level keyboard shortcuts: the viewer is click-only. Every
        // action that used to have a key equivalent (search, tabs, transcript
        // panel, regenerate) is reachable from the UI.
    }
}
