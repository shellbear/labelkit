import AppKit
import LabelKit
import Observation
import UniformTypeIdentifiers

/// Which images a generation run targets.
enum GenerationScope: Equatable {
    /// The sidebar's multi-selection (⌘A, ⌘/⇧-click).
    case selectedImages
    /// The one canvas image.
    case currentImage
    /// Never-annotated images: no boxes and no file entry yet (fresh imports,
    /// untouched on-disk images). Deliberate negatives (an entry with zero
    /// boxes) are left alone — a "no objects here" label isn't a gap to fill.
    case newImages
    /// Every image with a readable file on disk.
    case wholeDataset
}

/// Which detector a run uses. Hashable so it can tag a SwiftUI `Picker` and so
/// the built detector can be cached until the choice changes.
enum DetectorChoice: Hashable, Sendable {
    case builtin(VisionBuiltinDetector.Kind)
    case customModel(URL)
}

/// Owns model/detector selection and drives `GenerationEngine`, applying each
/// image's boxes to the store the moment it finishes (one undo step for the
/// whole run) and publishing progress for the toolbar.
@MainActor
@Observable
final class GenerationController {
    /// True while a batch run is in flight — greys the toolbar/menu so runs
    /// can't overlap.
    private(set) var isRunning = false
    /// Bumped each time a run applies boxes to an image — lets the sidebar
    /// refresh just the affected badges live without a full table reload.
    private(set) var appliedRevision = 0
    /// The active detector. Change it via `select` / `chooseCustomModel` so the
    /// compiled-detector cache is invalidated alongside it.
    private(set) var choice: DetectorChoice
    /// 0…1. Detections below this score are dropped.
    var confidence: Double = 0.5
    /// Target label for label-less detectors; empty falls back to the
    /// detector's own default (e.g. "face", "rectangle").
    var targetLabel: String = ""

    private let appState: AppState
    private let undoManager: UndoManager
    private var recentModels: RecentModels
    private var cachedDetector: BoxDetector?

    init(appState: AppState, undoManager: UndoManager,
         defaults: UserDefaults = labelkitDefaults()) {
        self.appState = appState
        self.undoManager = undoManager
        let recentModels = RecentModels(defaults: defaults)
        self.recentModels = recentModels
        // Resume the last custom model if one is remembered, else a safe built-in.
        self.choice = recentModels.urls.first.map(DetectorChoice.customModel) ?? .builtin(.rectangles)
    }

    var recentModelURLs: [URL] { recentModels.urls }

    // MARK: - Selection

    func select(_ newChoice: DetectorChoice) {
        guard newChoice != choice else { return }
        cachedDetector = nil          // force a rebuild for the new detector
        choice = newChoice
    }

    /// Prompt for a custom Core ML model and select it. Verifies it loads
    /// before committing, so a bad pick surfaces immediately, not mid-run.
    func chooseCustomModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // .mlpackage / .mlmodelc are packages
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["mlmodel", "mlpackage", "mlmodelc"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.message = "Choose a Core ML object-detection model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let detector = try CoreMLBoxDetector(modelURL: url)
            choice = .customModel(url)
            cachedDetector = detector       // reuse the instance we just verified
            recentModels.record(url)
        } catch {
            present(error: error, title: "Couldn’t load model")
        }
    }

    /// Adopt a just-trained model as the active detector and remember it, so ⌘G
    /// runs it immediately and it appears in the Model menu / options picker.
    /// Bypasses `select`'s no-op guard on purpose: the file on disk just changed
    /// (a retrain), so any cached detector for this path is stale.
    func adoptTrainedModel(at url: URL) {
        recentModels.record(url)
        cachedDetector = nil
        choice = .customModel(url)
    }

    /// Human label for the current choice (toolbar / menu checkmarks).
    var currentDetectorName: String {
        switch choice {
        case .builtin(let kind): return VisionBuiltinDetector(kind).name
        case .customModel(let url): return url.deletingPathExtension().lastPathComponent
        }
    }

    /// Whether the current detector emits its own labels — decided without
    /// loading the model, so the options popover can show/hide the label field.
    var currentProvidesLabels: Bool {
        switch choice {
        case .builtin(let kind): return VisionBuiltinDetector(kind).providesLabels
        case .customModel: return true
        }
    }

    /// The label a label-less current detector would fall back to (the field's
    /// placeholder).
    var currentDefaultLabel: String {
        switch choice {
        case .builtin(let kind): return VisionBuiltinDetector(kind).defaultLabel
        case .customModel: return "object"
        }
    }

    // MARK: - Run

    /// ⌘G / toolbar primary action. Runs on the sidebar selection, falling back
    /// to the canvas image when nothing is selected. Confirms before touching
    /// more than one image.
    func generateSelected() {
        guard let store = appState.store else { return }
        var entries = resolve(.selectedImages, in: store).filter { !$0.imageFileMissing }
        if entries.isEmpty, let current = appState.selectedEntry, !current.imageFileMissing {
            entries = [current]
        }
        guard !entries.isEmpty else { NSSound.beep(); return }
        if entries.count > 1,
           !confirm("Generate boxes on \(entries.count) selected images?",
                    info: "Existing boxes are kept. You can cancel anytime.") {
            return
        }
        run(entries: entries)
    }

    /// Menu scopes (New Images, All Images). All Images confirms past a
    /// threshold since it can be a very long run.
    func generate(scope: GenerationScope) {
        guard let store = appState.store else { return }
        let entries = resolve(scope, in: store).filter { !$0.imageFileMissing }
        if scope == .wholeDataset, entries.count > Self.confirmThreshold,
           !confirm("Generate boxes for \(entries.count) images?",
                    info: "The model runs on every image. Existing boxes are kept, and you can cancel anytime.") {
            return
        }
        run(entries: entries)
    }

    private static let confirmThreshold = 100

    private func run(entries: [ImageEntry]) {
        guard !isRunning, let store = appState.store, !entries.isEmpty else {
            if entries.isEmpty { NSSound.beep() }
            return
        }
        let jobs = entries.map { entry in
            GenerationJob(filename: entry.filename,
                          imageURL: store.imageURL(for: entry),
                          existingBoxes: entry.boxes)
        }
        let choice = self.choice
        var settings = GenerationEngine.Settings()
        settings.minConfidence = Float(confidence)

        isRunning = true
        undoManager.beginUndoGrouping()
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.undoManager.endUndoGrouping()
                self.isRunning = false
            }
            let detector: BoxDetector
            do {
                detector = try await self.resolvedDetector(for: choice)
            } catch {
                self.present(error: error, title: "Couldn’t load model")
                return
            }
            settings.fallbackLabel = self.effectiveLabel(for: detector)

            for await result in GenerationEngine.stream(jobs: jobs, detector: detector, settings: settings) {
                if let entry = store.entry(for: result.filename) {
                    store.addBoxes(result.newBoxes, to: entry, undoManager: self.undoManager)
                    self.appliedRevision += 1
                }
            }
        }
    }

    // MARK: - Helpers

    private func resolve(_ scope: GenerationScope, in store: DatasetStore) -> [ImageEntry] {
        switch scope {
        case .selectedImages:
            // List order (not Set order) keeps progress and undo deterministic.
            return store.entries.filter { appState.selectedFilenames.contains($0.filename) }
        case .currentImage:
            return appState.selectedEntry.map { [$0] } ?? []
        case .newImages:
            return store.entries.filter { $0.boxes.isEmpty && !$0.hasEntryInFile && !$0.imageFileMissing }
        case .wholeDataset:
            return store.entries
        }
    }

    /// Count of images a scope would target — for menu titles / confirmations.
    func targetCount(for scope: GenerationScope) -> Int {
        guard let store = appState.store else { return 0 }
        return resolve(scope, in: store).filter { !$0.imageFileMissing }.count
    }

    private func effectiveLabel(for detector: BoxDetector) -> String {
        let trimmed = targetLabel.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? detector.defaultLabel : trimmed
    }

    /// The detector for `choice`, cached across runs. Custom models compile off
    /// the main thread on first use so a large model never stalls the UI.
    private func resolvedDetector(for choice: DetectorChoice) async throws -> BoxDetector {
        if let cachedDetector { return cachedDetector }
        let detector = try await Task.detached(priority: .userInitiated) {
            try Self.makeDetector(choice)
        }.value
        cachedDetector = detector
        return detector
    }

    private nonisolated static func makeDetector(_ choice: DetectorChoice) throws -> BoxDetector {
        switch choice {
        case .builtin(let kind): return VisionBuiltinDetector(kind)
        case .customModel(let url): return try CoreMLBoxDetector(modelURL: url)
        }
    }

    private func confirm(_ message: String, info: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "Generate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func present(error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
