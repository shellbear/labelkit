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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare SPM binary launches as an accessory process: no Dock icon,
        // no menu bar, no key window. Promote it to a regular app.
        NSApp.setActivationPolicy(.regular)
        activateFront()
        // The SwiftUI window may not exist yet on the first pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Self.activateFront() }
    }

    private func activateFront() { Self.activateFront() }

    /// macOS 14+ activation is cooperative: a terminal-spawned process is
    /// refused focus unless the frontmost app (the terminal) formally yields
    /// via activate(from:). Fall back to the classic call otherwise.
    private static func activateFront() {
        let current = NSRunningApplication.current
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != current.processIdentifier {
            current.activate(from: frontmost, options: [])
        } else {
            NSApp.activate()
        }
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
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
