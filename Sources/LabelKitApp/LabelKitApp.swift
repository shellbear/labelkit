import AppKit
import SwiftUI

// NOT @main — started explicitly from LabelKitCommand.run() so ArgumentParser
// owns the process entry (see main.swift).
struct LabelKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState(launch: LaunchContext.current)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .onAppear { appDelegate.appState = appState }
        }
        .commands { AppCommands(appState: appState) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A bare SPM binary launches as an accessory process: no Dock icon,
        // no menu bar — and SwiftUI then skips creating the WindowGroup
        // window entirely (it only appears on a Dock-click reopen). The
        // policy must be promoted BEFORE launch completes.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The SwiftUI window is created after this callback; retry until it
        // exists so ordering + key status actually land.
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.activateFront() }
        }
    }

    /// macOS 14+ activation is cooperative: a terminal-spawned process is
    /// refused focus unless the frontmost app (the terminal) formally yields
    /// via activate(from:). `.activateAllWindows` is essential — without it
    /// the app activates but its window stays behind (Dock-click symptom).
    private static func activateFront() {
        let current = NSRunningApplication.current
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != current.processIdentifier {
            current.activate(from: frontmost, options: [.activateAllWindows])
        } else {
            NSApp.activate()
        }
        if ProcessInfo.processInfo.environment["LABELKIT_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                "activate: windows=\(NSApp.windows.count) visible=\(NSApp.windows.map(\.isVisible)) active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)\n".utf8))
        }
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        return appState.confirmDiscardIfDirty() ? .terminateNow : .terminateCancel
    }
}

struct AppCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Dataset…") { appState.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { appState.save() }
                .keyboardShortcut("s")
                .disabled(appState.store?.isDirty != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom to Fit") { appState.fitTrigger += 1 }
                .keyboardShortcut("0")
            Divider()
            Button("Next Image") { appState.selectNeighbor(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Previous Image") { appState.selectNeighbor(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
        }
    }
}
