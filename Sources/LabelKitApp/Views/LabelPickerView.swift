import LabelKit
import SwiftUI

/// Inspector panel: label list (color + digit shortcut), new-label field.
/// Clicking a label sets the selected box's label, or the default label for
/// the next drawn box when nothing is selected.
struct LabelPickerView: View {
    let store: DatasetStore
    let entry: ImageEntry
    let viewModel: CanvasViewModel

    @State private var newLabel = ""
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List {
            Section("Labels") {
                ForEach(Array(store.labels.ordered.enumerated()), id: \.element) { index, label in
                    Button {
                        select(label)
                    } label: {
                        HStack {
                            Circle()
                                .fill(LabelColors.color(for: label, in: store.labels))
                                .frame(width: 10, height: 10)
                            Text(label)
                            Spacer()
                            if label == viewModel.drawLabel {
                                Image(systemName: "pencil.tip")
                                    .foregroundStyle(.secondary)
                                    .help("Applied to newly drawn boxes")
                            }
                            if index < 9 {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    TextField("New label", text: $newLabel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addLabel)
                    Button("Add", action: addLabel)
                        .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let selectedID = viewModel.selectedBoxID,
               let box = entry.boxes.first(where: { $0.id == selectedID }) {
                Section("Selected Box") {
                    LabeledContent("Label", value: box.label)
                    LabeledContent("X", value: CreateMLWriter.coordString(box.rect.midX))
                    LabeledContent("Y", value: CreateMLWriter.coordString(box.rect.midY))
                    LabeledContent("W", value: CreateMLWriter.coordString(box.rect.width))
                    LabeledContent("H", value: CreateMLWriter.coordString(box.rect.height))
                }
            }
        }
    }

    private func select(_ label: String) {
        viewModel.drawLabel = label
        if let selectedID = viewModel.selectedBoxID {
            store.setBoxLabel(id: selectedID, in: entry, to: label, undoManager: undoManager)
        }
    }

    private func addLabel() {
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addLabel(trimmed)
        viewModel.drawLabel = trimmed
        newLabel = ""
    }
}
