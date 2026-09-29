import AppKit
import SwiftUI

/// Owns the single viewer window. `show()` creates it lazily on first call,
/// then reuses the same NSWindow forever — closing it just hides it
/// (`orderOut`) so the store state stays warm.
@MainActor
public final class ViewerWindowController {
    private var window: NSWindow?
    private let store: ViewerStore
    /// Held here (not a singleton) because it needs to reach `store`, and
    /// because `NSWindow.delegate` is a weak reference.
    private let closeDelegate: HideOnCloseDelegate
    /// Fired after every show/hide/miniaturize so AppState can recompute the
    /// Dock icon (the app is LSUIElement; the Dock icon only exists while a
    /// window is open — see `AppState.refreshDockIcon()`).
    public var onVisibilityChanged: (() -> Void)?
    /// Affecté par `AppState.init` juste après la construction (impossible à
    /// passer au constructeur : `self` n'est pas encore initialisé à ce
    /// moment-là). `weak` parce qu'AppState détient ce contrôleur.
    public weak var app: AppState?

    /// True while the window participates in the Dock's idea of "the app is
    /// open": visible on screen or sitting in the Dock as a miniature.
    public var isWindowPresent: Bool {
        guard let w = window else { return false }
        return w.isVisible || w.isMiniaturized
    }

    public init(store: ViewerStore) {
        self.store = store
        // Hiding the window hides the transport too, so playback must stop —
        // otherwise audio keeps running with no visible way to pause it. Kept as
        // `pause` (via `viewerDidHide`) so reopening resumes where it was.
        self.closeDelegate = HideOnCloseDelegate(onHide: {
            store.viewerDidHide()
            store.flushState()
        })
        // Separate callback (assigned after init: the closure above cannot
        // capture `self` before all stored properties are set).
        self.closeDelegate.onVisibilityChanged = { [weak self] in
            self?.onVisibilityChanged?()
        }
    }

    public func show() {
        defer { onVisibilityChanged?() }
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = ViewerRootView(store: store, app: app)
        let host = NSHostingController(rootView: content)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Onyx"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentViewController = host
        // Order matters: `setFrameAutosaveName` immediately restores the saved
        // frame, so centring afterwards would fight it — and centring *before*
        // it is dead work whenever a frame was saved. Centre only on the very
        // first run, when there is nothing to restore.
        let autosaveName = "onyx.viewer"
        let hasSavedFrame = UserDefaults.standard
            .string(forKey: "NSWindow Frame \(autosaveName)") != nil
        w.setFrameAutosaveName(autosaveName)
        if !hasSavedFrame { w.center() }
        // Intercept close → just hide. Because `windowShouldClose` returns
        // false the window is never actually closed, so `window` never becomes
        // a dangling reference and `show()` always hands back a live instance.
        // Closing is also the last moment the user expects their layout to
        // stick, so flush the debounced viewer state on the way out.
        w.delegate = closeDelegate
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the viewer on `slug`'s live notes.
    ///
    /// `slug` must be the slug of the meeting **currently being recorded** — see
    /// `ViewerStore.focusLiveNotes(slug:)`. Passing `nil` (nothing is recording)
    /// only shows the window: switching to the `.live` tab without retargeting
    /// the selection pointed the editor at an unrelated meeting's
    /// `notes/live.md`, and typing then destroyed it.
    @discardableResult
    public func focusLiveNotes(slug: String?) -> Bool {
        show()
        // Must go through the store, not a bare `activeNoteLevel` assignment:
        // assigning the level alone switches the tab without loading
        // `notes/live.md`, so the user would stare at the previous tab's text.
        return store.focusLiveNotes(slug: slug)
    }
}

private final class HideOnCloseDelegate: NSObject, NSWindowDelegate {
    private let onHide: () -> Void
    /// Set post-init by the controller; fired on every visibility transition
    /// so the Dock icon tracks the window (see AppState.refreshDockIcon()).
    var onVisibilityChanged: (() -> Void)?
    init(onHide: @escaping () -> Void) {
        self.onHide = onHide
        super.init()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onHide()
        sender.orderOut(nil)
        onVisibilityChanged?()
        return false
    }
    /// Minimising does **not** stop playback: unlike closing, the window is one
    /// Dock click away, so the user is listening on purpose rather than losing
    /// a transport they cannot reach. Only the Dock icon state is refreshed.
    func windowDidMiniaturize(_ notification: Notification) {
        onVisibilityChanged?()
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        onVisibilityChanged?()
    }
}
