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
        NSApp.activate(ignoringOtherApps: true)
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
