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
    /// Headline for the current phase, e.g. "Preparing images…", "Training…".
    private(set) var statusTitle = ""
    /// Within-phase detail, e.g. "37 of 92 images" or "Iteration 6 of 10".
    private(set) var statusDetail = ""
    /// Smoothed, rounded time-remaining phrase; empty until it's trustworthy.
    private(set) var etaText = ""
    /// Latest training loss, e.g. "loss 0.382"; empty until reported.
    private(set) var lossText = ""

    /// Exponential moving average of the raw ETA, to damp the jump at the
    /// feature-extraction → training phase boundary.
    private var etaEMA: Double?
    /// When the current run started. The sheet renders a live
    /// `Text(_:style: .timer)` from this, so the elapsed clock ticks every second
    /// on its own — a manual ticker gets starved by Create ML's CPU load and only
    /// updates when a progress callback frees the main actor (~every few seconds).
    private(set) var runStart: Date?
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
        resetProgress()
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
        resetProgress()
        isRunning = true
        runStart = Date()

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
                    case let .progress(snapshot):
                        self.apply(snapshot)
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

    // MARK: - Progress display

    private func resetProgress() {
        progress = 0
        statusTitle = ""
        statusDetail = ""
        etaText = ""
        lossText = ""
        etaEMA = nil
        runStart = nil
    }

    private func apply(_ snapshot: TrainingProgress) {
        progress = snapshot.fraction
        switch snapshot.phase {
        case .preparing:
            statusTitle = "Preparing images…"
            statusDetail = snapshot.totalItemCount.map { "\(snapshot.itemCount) of \($0) images" } ?? ""
        case .training:
            statusTitle = "Training…"
            statusDetail = snapshot.totalItemCount.map { "Iteration \(snapshot.itemCount) of \($0)" }
                ?? "Iteration \(snapshot.itemCount)"
        case .evaluating:
            statusTitle = "Evaluating…"
            statusDetail = ""
        case .other:
            // Object detection reports its initial decode/feature-extraction pass
            // as the initialized phase rather than `.extractingFeatures`, so treat
            // "other" during a run as preparation.
            statusTitle = "Preparing…"
            statusDetail = ""
        }
        // The elapsed clock is a live SwiftUI timer bound to `runStart`, not set
        // here — these events arrive only every few iterations and would stutter.
        etaText = estimateETA(fraction: snapshot.fraction, elapsed: snapshot.elapsedTime)
        lossText = snapshot.loss.map { String(format: "loss %.3f", $0) } ?? ""
    }

    /// A rough "about … left" from overall fraction, EMA-smoothed and coarsely
    /// rounded, shown only once there's enough signal to not be noise. Cross-phase
    /// ETA is inherently approximate (feature extraction and training run at
    /// different rates), so it's always phrased as an estimate.
    private func estimateETA(fraction: Double, elapsed: TimeInterval) -> String {
        guard fraction > 0.05, fraction < 0.999, elapsed > 3 else { return "" }
        let raw = elapsed * (1 - fraction) / fraction
        let smoothed = etaEMA.map { $0 * 0.7 + raw * 0.3 } ?? raw
        etaEMA = smoothed
        if smoothed < 10 { return "a few seconds left" }
        if smoothed < 60 { return "about \(Int((smoothed / 5).rounded()) * 5)s left" }
        return "about \(Int((smoothed / 60).rounded())) min left"
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
