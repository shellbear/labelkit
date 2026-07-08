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
    /// Newest first, capped — drives File ▸ Open Recent and the welcome list.
    private(set) var recentLocations: [DatasetLocation]

    private var imageGlob: String?
    private let recentProjects: RecentProjects

    init(launch: LaunchContext, defaults: UserDefaults = labelkitDefaults()) {
        imageGlob = launch.imageGlob
        recentProjects = RecentProjects(defaults: defaults)
        recentLocations = recentProjects.locations
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
            recentProjects.record(opened.location)
            recentLocations = recentProjects.locations
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
        let index = selectedFilename.flatMap { store.index(of: $0) } ?? 0
        let next = min(max(index + offset, 0), store.entries.count - 1)
        selectedFilename = store.entries[next].filename
    }

    // MARK: - Open / switch flows

    /// User-initiated switch (Open Recent, welcome list). Selecting the
    /// project that is already open is a no-op; a dirty store prompts first.
    func requestOpen(_ location: DatasetLocation) {
        if let current = store?.location,
           current.imagesDirectory == location.imagesDirectory,
           current.annotationsURL == location.annotationsURL {
            return
        }
        guard confirmDiscardIfDirty() else { return }
        open(location: location)
    }

    /// A CLI invocation forwarded from another process — adopts that
    /// invocation's glob (nil = unfiltered), matching fresh-launch semantics.
    func requestOpenFromCLI(_ location: DatasetLocation, imageGlob newGlob: String?) {
        guard confirmDiscardIfDirty() else { return }
        imageGlob = newGlob
        open(location: location)
    }

    func clearRecents() {
        recentProjects.clear()
        recentLocations = []
    }

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
