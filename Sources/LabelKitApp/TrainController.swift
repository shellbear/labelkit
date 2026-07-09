import AppKit
import LabelKit
import Observation
import UniformTypeIdentifiers

/// Owns the Train sheet's state and drives `CreateMLObjectDetectorTrainer`,
/// streaming progress to the sheet and — on success — adopting the model into
/// Generate and revealing it in Finder. Mirrors `GenerationController`: a
/// `@MainActor @Observable` driver whose `isRunning` greys the toolbar/menu.
@MainActor
@Observable
final class TrainController {
    /// The knobs bound to the sheet's controls.
    var options = TrainingOptions()
    /// Sheet visibility — the toolbar button and Detect ▸ Train Model… flip it.
    var isSheetPresented = false

    /// True while a run is in flight — greys the launch controls and shows the
    /// progress bar. A run can't overlap another.
    private(set) var isRunning = false
    /// Overall completion, `0…1`, for the sheet's progress bar.
    private(set) var progress = 0.0
    /// Short phase label (e.g. "Iteration 12 of 100"); empty early on.
    private(set) var phase = ""
    /// Set when a run finishes — drives the success view.
    private(set) var lastResult: TrainingResult?
    /// Set when a run fails — drives the error view.
    private(set) var lastError: String?

    private let appState: AppState
    private let generationController: GenerationController
    private var task: Task<Void, Never>?

    init(appState: AppState, generationController: GenerationController) {
        self.appState = appState
        self.generationController = generationController
    }

    // MARK: - Sheet context

    var datasetName: String { appState.store?.location.displayName ?? "" }
    var imageCount: Int { appState.store?.entries.count ?? 0 }
    var canTrain: Bool { appState.store != nil }

    /// Toolbar / menu action — open the sheet on a clean slate.
    func presentSheet() {
        guard canTrain, !isRunning else { return }
        lastResult = nil
        lastError = nil
        progress = 0
        phase = ""
        isSheetPresented = true
    }

    // MARK: - Run

    /// Save pending edits (training reads annotations.json from disk), ask where
    /// to write the model, then stream a training run.
    func train() {
        guard !isRunning, let store = appState.store else { return }

        if store.isDirty {
            do {
                try store.save()
            } catch {
                present(error: error, title: "Couldn’t save before training")
                return
            }
        }

        guard let outputURL = chooseOutputURL(for: store.location) else { return }

        let location = store.location
        let options = self.options
        lastResult = nil
        lastError = nil
        progress = 0
        phase = ""
        isRunning = true

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRunning = false
                self.task = nil
            }
            let stream = CreateMLObjectDetectorTrainer().train(
                location: location, outputURL: outputURL, options: options)
            do {
                for try await event in stream {
                    switch event {
                    case let .progress(fraction, phase):
                        self.progress = fraction
                        self.phase = phase
                    case let .finished(result):
                        self.progress = 1
                        self.lastResult = result
                        self.adopt(result)
                    }
                }
            } catch is CancellationError {
                // User cancelled — leave the sheet on its config state.
            } catch {
                self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// Cancel a running run — cancels the task, whose termination cancels the
    /// underlying `MLJob` (via the stream's `onTermination`).
    func cancel() {
        task?.cancel()
    }

    func revealModel() {
        guard let url = lastResult?.modelURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Completion

    /// Close the annotate → train → generate loop: make the model the active
    /// detector (⌘G runs it) and reveal the file in Finder.
    private func adopt(_ result: TrainingResult) {
        generationController.adoptTrainedModel(at: result.modelURL)
        NSWorkspace.shared.activateFileViewerSelecting([result.modelURL])
    }

    private func chooseOutputURL(for location: DatasetLocation) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Trained Model"
        panel.message = "Choose where to write the Core ML model"
        panel.nameFieldStringValue = "\(location.displayName).mlmodel"
        // Default beside the dataset folder, never inside it — the dataset dir is
        // git-tracked and is also what Create ML scans while training.
        panel.directoryURL = location.imagesDirectory.deletingLastPathComponent()
        if let mlmodel = UTType(filenameExtension: "mlmodel") {
            panel.allowedContentTypes = [mlmodel]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    private func present(error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
