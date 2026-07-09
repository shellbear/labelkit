import LabelKit
import SwiftUI

/// The primary toolbar control: a split button that generates boxes on the
/// selected images (its default action, matching ⌘G), with a menu for the
/// other scopes. Greyed while a run is in flight so runs can't overlap.
struct GenerateControlView: View {
    let controller: GenerationController
    let appState: AppState

    var body: some View {
        Menu {
            let selCount = controller.targetCount(for: .selectedImages)
            let newCount = controller.targetCount(for: .newImages)
            let allCount = controller.targetCount(for: .wholeDataset)
            Button(selCount > 0 ? "Selected Images (\(selCount))" : "Current Image") {
                controller.generateSelected()
            }
            Button("New Images (\(newCount))") { controller.generate(scope: .newImages) }
                .disabled(newCount == 0)
            Divider()
            Button("All Images (\(allCount))…") { controller.generate(scope: .wholeDataset) }
                .disabled(allCount == 0)
            Divider()
            modelMenu
        } label: {
            Label("Generate", systemImage: "wand.and.stars")
        } primaryAction: {
            controller.generateSelected()
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(appState.store == nil || controller.isRunning)
        .help("Generate boxes with \(controller.currentDetectorName) (⌘G)")
    }

    /// Detector picker as a submenu, so the model can be switched right where
    /// generation is triggered (the same choice the Options popover and Detect ▸
    /// Model menu drive). The inline Picker gives free checkmarks on the current
    /// choice; "Choose Model…" adds a custom Core ML model.
    private var modelMenu: some View {
        Menu {
            Picker("Model", selection: Binding(
                get: { controller.choice },
                set: { controller.select($0) })) {
                ForEach(VisionBuiltinDetector.Kind.allCases, id: \.self) { kind in
                    Text(VisionBuiltinDetector(kind).name).tag(DetectorChoice.builtin(kind))
                }
                ForEach(controller.recentModelURLs, id: \.self) { url in
                    Text(url.deletingPathExtension().lastPathComponent)
                        .tag(DetectorChoice.customModel(url))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Choose Model…") { controller.chooseCustomModel() }
        } label: {
            Label("Model: \(controller.currentDetectorName)", systemImage: "cpu")
        }
    }
}

/// The gear/sliders toolbar item: a popover to pick the detector and tune the
/// confidence threshold (and, for label-less detectors, the target label).
struct GenerationOptionsView: View {
    @Bindable var controller: GenerationController
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .help("Detector & options")
        .disabled(controller.isRunning)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            form.padding(16).frame(width: 300)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Model") {
                Picker("Model", selection: Binding(
                    get: { controller.choice },
                    set: { controller.select($0) })) {
                    ForEach(VisionBuiltinDetector.Kind.allCases, id: \.self) { kind in
                        Text(VisionBuiltinDetector(kind).name).tag(DetectorChoice.builtin(kind))
                    }
                    if !controller.recentModelURLs.isEmpty {
                        Divider()
                        ForEach(controller.recentModelURLs, id: \.self) { url in
                            Text(url.deletingPathExtension().lastPathComponent)
                                .tag(DetectorChoice.customModel(url))
                        }
                    }
                }
                .labelsHidden()
                Button("Choose Model…") { controller.chooseCustomModel() }
                    .controlSize(.small)
            }

            section("Confidence") {
                HStack {
                    Slider(value: $controller.confidence, in: 0...1)
                    Text("\(Int((controller.confidence * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }

            if !controller.currentProvidesLabels {
                section("Label") {
                    TextField(controller.currentDefaultLabel, text: $controller.targetLabel)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}
