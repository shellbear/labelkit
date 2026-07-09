import LabelKit
import SwiftUI

/// The training sheet — the first `.sheet` in the app, presented from `RootView`
/// and bound to `TrainController.isSheetPresented`. Walks through configure →
/// run (progress/cancel) → result (metrics + reveal).
struct TrainSheet: View {
    @Environment(TrainController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false

    var body: some View {
        @Bindable var controller = controller
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content(controller)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer(controller)
        }
        .frame(width: 460)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Train Model").font(.headline)
                Text("\(controller.datasetName) · \(controller.imageCount) image\(controller.imageCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ controller: TrainController) -> some View {
        if controller.isRunning {
            runningView(controller)
        } else if let result = controller.lastResult {
            resultView(result)
        } else if let error = controller.lastError {
            errorView(error)
        } else {
            configView(controller)
        }
    }

    private func configView(_ controller: TrainController) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Algorithm").font(.subheadline.weight(.semibold))
                Picker("Algorithm", selection: $controller.options.algorithm) {
                    Text("Transfer Learning").tag(TrainingAlgorithm.transferLearning)
                    Text("Full Network").tag(TrainingAlgorithm.fullNetwork)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(algorithmBlurb(controller.options.algorithm))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Iterations")
                        Spacer()
                        TextField("Auto", text: iterationsBinding(controller))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Validation split")
                            Spacer()
                            Text(validationLabel(controller.options.validationSplitFraction))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: validationBinding(controller), in: 0...0.5)
                    }
                }
                .padding(.top, 8)
            }
            .font(.subheadline)
        }
    }

    private func runningView(_ controller: TrainController) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Training…").font(.subheadline.weight(.semibold))
            ProgressView(value: controller.progress)
            Text(controller.phase.isEmpty ? "Preparing data…" : controller.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func resultView(_ result: TrainingResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 6) {
                Text("Training complete").font(.subheadline.weight(.semibold))
                if let map = result.metrics.validationMeanAveragePrecision {
                    metricRow("Validation mAP", map)
                } else if let map = result.metrics.trainingMeanAveragePrecision {
                    metricRow("Training mAP", map)
                }
                Text(result.modelURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Selected as the active model — ⌘G runs it now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Training failed").font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ controller: TrainController) -> some View {
        HStack {
            Spacer()
            if controller.isRunning {
                Button("Cancel") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else if controller.lastResult != nil {
                Button("Show in Finder") { controller.revealModel() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else if controller.lastError != nil {
                Button("Close") { dismiss() }
                Button("Try Again") { controller.train() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Train") { controller.train() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canTrain)
            }
        }
        .padding(20)
    }

    // MARK: - Helpers

    private func metricRow(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(String(format: "%.1f%%", value * 100)).monospacedDigit().fontWeight(.medium)
        }
        .font(.caption)
    }

    private func algorithmBlurb(_ algorithm: TrainingAlgorithm) -> String {
        switch algorithm {
        case .transferLearning:
            return "Small, fast model built on a system feature extractor. Best for most datasets."
        case .fullNetwork:
            return "Trains a full network from scratch. Larger and slower, but can win on big datasets."
        }
    }

    private func validationLabel(_ fraction: Double?) -> String {
        guard let fraction, fraction > 0 else { return "Off" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private func iterationsBinding(_ controller: TrainController) -> Binding<String> {
        Binding(
            get: { controller.options.maxIterations.map(String.init) ?? "" },
            set: { controller.options.maxIterations = Int($0) })
    }

    private func validationBinding(_ controller: TrainController) -> Binding<Double> {
        Binding(
            get: { controller.options.validationSplitFraction ?? 0 },
            set: { controller.options.validationSplitFraction = $0 > 0.001 ? $0 : nil })
    }
}
