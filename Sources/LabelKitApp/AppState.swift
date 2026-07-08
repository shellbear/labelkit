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

    // Arrow-key velocity, so a discrete step decodes immediately while a held
    // key (rapid successive steps) shows a soft placeholder and debounces the
    // expensive decode. Not observed — read imperatively when a canvas opens.
    @ObservationIgnored private var lastNeighborNavAt: CFAbsoluteTime = 0
    @ObservationIgnored private var lastStepWasRapid = false
    private static let rapidGap: CFAbsoluteTime = 0.15

    // Detail-image prefetch. The canvas reports the physical pixel size it
    // renders at so neighbours are decoded at the resolution they'll be shown.
    @ObservationIgnored var detailDisplayPixels: CGFloat = 2200
    @ObservationIgnored private var prefetchTasks: [Task<Void, Never>] = []

    /// True only while an arrow key is actually being held (the previous step
    /// landed < `rapidGap` ago and recently). A single press reads false.
    var isRapidNavigation: Bool {
        lastStepWasRapid && CFAbsoluteTimeGetCurrent() - lastNeighborNavAt < 0.25
    }

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
        let now = CFAbsoluteTimeGetCurrent()
        lastStepWasRapid = now - lastNeighborNavAt < Self.rapidGap
        lastNeighborNavAt = now
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks = []
        let index = selectedFilename.flatMap { store.index(of: $0) } ?? 0
        let next = min(max(index + offset, 0), store.entries.count - 1)
        selectedFilename = store.entries[next].filename
        // Prefetch ahead only when stepping deliberately: during a fast scrub
        // the decode is debounced and the CPU is reserved for cheap thumbnails.
        if !lastStepWasRapid {
            prefetchAhead(store: store, from: next, direction: offset >= 0 ? 1 : -1)
        }
    }

    private func prefetchAhead(store: DatasetStore, from index: Int, direction: Int) {
        let pixels = detailDisplayPixels
        for step in 1...2 {
            let j = index + direction * step
            guard store.entries.indices.contains(j) else { break }
            let entry = store.entries[j]
            guard !entry.imageFileMissing else { continue }
            let url = store.imageURL(for: entry)
            prefetchTasks.append(Task {
                await DetailImageService.shared.prefetch(
                    url: url, maxPixel: pixels, nominalMax: pixels)
            })
        }
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
