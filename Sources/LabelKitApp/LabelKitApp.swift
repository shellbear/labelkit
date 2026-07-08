import AppKit
import LabelKit
import SwiftUI

/// Classic AppKit shell hosting SwiftUI content. SwiftUI's WindowGroup never
/// creates its window while the app is inactive — and macOS 14+ cooperative
/// activation refuses terminal-spawned processes, so a bare/CLI launch showed
/// nothing until a Dock click. An imperatively created NSWindow exists and
/// orders front regardless of activation.
@MainActor
func runLabelKitApp() -> Never {
    let app = NSApplication.shared
    let controller = AppController()
    appControllerStrongRef = controller  // NSApplication.delegate is weak
    app.delegate = controller
    app.run()
    exit(0)
}

@MainActor private var appControllerStrongRef: AppController?

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var appState: AppState!
    private let windowUndoManager = UndoManager()
    private var window: NSWindow!
    private var openRecentMenu: NSMenu!
    /// Icon/"Open With" drops that arrive before the app finished launching —
    /// drained once `appState` exists (see applicationDidFinishLaunching).
    private var pendingImportURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState(launch: LaunchContext.current)
        buildMenu()
        buildWindow()

        // Later launches of the CLI/app hand their dataset to this instance.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleOpenRequest(_:)),
            name: SingleInstance.openRequestNotification, object: nil)

        // Visible immediately, active or not.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        for delay in [0.0, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.tryActivate() }
        }

        // Drain any icon/"Open With" drop that landed before appState existed.
        if !pendingImportURLs.isEmpty {
            let urls = pendingImportURLs
            pendingImportURLs = []
            appState.importImages(urls)
        }
    }

    /// Files dropped on the Dock icon or opened via "Open With" (the bundle
    /// declares public.image / public.folder in Info.plist). At cold launch
    /// this can fire before appState exists, so buffer until it does.
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard appState != nil else {
            pendingImportURLs.append(contentsOf: urls)
            return
        }
        window.makeKeyAndOrderFront(nil)
        Self.tryActivate()
        appState.importImages(urls)
    }

    @objc private func handleOpenRequest(_ note: Notification) {
        // Surface the window before any unsaved-changes prompt.
        window.makeKeyAndOrderFront(nil)
        Self.tryActivate()
        guard let request = SingleInstance.decodeOpenRequest(note) else { return }
        appState.requestOpenFromCLI(request.location, imageGlob: request.imageGlob)
    }

    private static func tryActivate() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != NSRunningApplication.current.processIdentifier {
            NSRunningApplication.current.activate(from: frontmost, options: [.activateAllWindows])
        } else {
            NSApp.activate()
        }
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 800, height: 520)
        window.title = "LabelKit"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("LabelKitMainWindow")
        // A hosted NavigationSplitView only gets the modern unified-titlebar
        // chrome (tall bar, translucent full-height sidebar material) when
        // the window carries a toolbar — even an empty one.
        let toolbar = NSToolbar(identifier: "labelkit.main")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentView = NSHostingView(
            rootView: RootView().environment(appState)
        )
        if window.frame.width < 900 { window.center() }
    }

    /// Feeds ⌘Z/⇧⌘Z (Edit menu, responder chain) AND SwiftUI's
    /// `@Environment(\.undoManager)` inside the hosting view.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        windowUndoManager
    }

    // MARK: - Quit / close flow

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appState.confirmDiscardIfDirty() ? .terminateNow : .terminateCancel
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About LabelKit",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit LabelKit",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem("Open Dataset…", "o", #selector(openDataset)))
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self  // rebuilt on every open via menuNeedsUpdate
        openRecentMenu.autoenablesItems = false
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem("Save", "s", #selector(saveDataset)))
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(menuItem("Zoom to Fit", "0", #selector(zoomToFit)))
        viewMenu.addItem(.separator())
        viewMenu.addItem(menuItem("Next Image", String(UnicodeScalar(NSDownArrowFunctionKey)!), #selector(nextImage)))
        viewMenu.addItem(menuItem("Previous Image", String(UnicodeScalar(NSUpArrowFunctionKey)!), #selector(previousImage)))
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(_ title: String, _ key: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openRecentMenu else { return }
        menu.removeAllItems()
        let recents = appState.recentLocations
        for location in recents {
            let item = menuItem(location.displayName, "", #selector(openRecent(_:)))
            item.representedObject = location
            // Same-named folders are common in datasets; the tooltip disambiguates.
            item.toolTip = location.annotationsURL.path
            let icon = NSWorkspace.shared.icon(forFile: location.imagesDirectory.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !recents.isEmpty { menu.addItem(.separator()) }
        let clear = menuItem("Clear Menu", "", #selector(clearRecents))
        clear.isEnabled = !recents.isEmpty
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? DatasetLocation else { return }
        appState.requestOpen(location)
    }

    @objc private func clearRecents() { appState.clearRecents() }

    @objc private func openDataset() { appState.presentOpenPanel() }
    @objc private func saveDataset() { appState.save() }
    @objc private func zoomToFit() { appState.fitTrigger += 1 }
    @objc private func nextImage() { appState.selectNeighbor(offset: 1) }
    @objc private func previousImage() { appState.selectNeighbor(offset: -1) }
}
