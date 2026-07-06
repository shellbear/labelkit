import AppKit
import LabelKit
import Observation
import SwiftUI

@Observable
@MainActor
final class AppState {
    var store: DatasetStore?
    var selectedFilename: String?
    /// Incremented to ask the canvas to reset to fit-to-window (⌘0).
    var fitTrigger = 0
    var loadError: String?

    private let imageGlob: String?

    init(launch: LaunchContext) {
        imageGlob = launch.imageGlob
        if let location = launch.location {
            open(location: location)
        }
    }

    func open(location: DatasetLocation) {
        do {
            let opened = try DatasetStore(location: location, imageGlob: imageGlob)
            store = opened
            selectedFilename = opened.entries.first?.filename
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    var selectedEntry: ImageEntry? {
        guard let selectedFilename else { return nil }
        return store?.entry(for: selectedFilename)
    }

    // MARK: - Navigation

    func selectNeighbor(offset: Int) {
        guard let store, !store.entries.isEmpty else { return }
        let index = store.entries.firstIndex { $0.filename == selectedFilename } ?? 0
        let next = min(max(index + offset, 0), store.entries.count - 1)
        selectedFilename = store.entries[next].filename
    }

    // MARK: - Open / switch flows

    func presentOpenPanel() {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .folder]
        panel.message = "Choose a dataset folder (or an annotations .json file)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let location = try DatasetLocator.resolve(path: url.path) {
                open(location: location)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func save() {
        guard let store else { return }
        do {
            try store.save()
        } catch {
            presentError("Could not save annotations", error)
        }
    }

    /// Returns true when it is safe to proceed (saved, discarded, or clean).
    func confirmDiscardIfDirty() -> Bool {
        guard let store, store.isDirty else { return true }
        switch UnsavedChangesAlert.run(datasetName: store.location.displayName) {
        case .save:
            do {
                try store.save()
                return true
            } catch {
                presentError("Could not save annotations", error)
                return false
            }
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    private func presentError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}

/// Save ⏎ / Cancel ⎋ / Discard — shared by quit and switch-dataset paths.
enum UnsavedChangesAlert {
    enum Choice { case save, discard, cancel }

    @MainActor
    static func run(datasetName: String) -> Choice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(datasetName)”?"
        alert.informativeText = "Your box edits will be lost otherwise."
        alert.addButton(withTitle: "Save")     // ⏎
        alert.addButton(withTitle: "Cancel")   // ⎋
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .cancel
        default: return .discard
        }
    }
}
