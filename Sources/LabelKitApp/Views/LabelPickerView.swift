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
        let usage = store.labelUsage()
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
                            if usage[label, default: 0] == 0 {
                                Button {
                                    deleteLabel(label)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete unused label")
                            } else if index < 9 {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(usage[label, default: 0] > 0
                          ? "\(usage[label, default: 0]) box(es) use this label — delete them first to remove it"
                          : "Unused label")
                }

                HStack {
                    TextField("New label", text: $newLabel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addLabel)
                    Button("Add", action: addLabel)
                        .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Boxes (\(entry.boxes.count))") {
                if entry.boxes.isEmpty {
                    Text(entry.hasEntryInFile
                         ? "No boxes — negative example"
                         : "No boxes yet — drag on the image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(entry.boxes) { box in
                    boxRow(box)
                }
            }
        }
        // ⌫ works here too when the inspector list has focus.
        .onDeleteCommand {
            viewModel.deleteSelected(undoManager: undoManager)
        }
    }

    @ViewBuilder
    private func boxRow(_ box: BoundingBox) -> some View {
        let isSelected = box.id == viewModel.selectedBoxID
        Button {
            viewModel.selectedBoxID = box.id
        } label: {
            HStack {
                Circle()
                    .fill(LabelColors.color(for: box.label, in: store.labels))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(box.label)
                    Text("\(CreateMLWriter.coordString(box.rect.width))×\(CreateMLWriter.coordString(box.rect.height)) @ \(CreateMLWriter.coordString(box.rect.midX)), \(CreateMLWriter.coordString(box.rect.midY))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.toggleBoxHidden(id: box.id, in: entry)
                } label: {
                    Image(systemName: box.isHidden ? "eye.slash" : "eye")
                        .foregroundStyle(box.isHidden ? .secondary : .primary)
                }
                .buttonStyle(.borderless)
                .help(box.isHidden
                      ? "Show box (session only — hidden boxes still save)"
                      : "Hide box on the canvas (H on selected)")
                Button {
                    store.removeBox(id: box.id, from: entry, undoManager: undoManager)
                    if isSelected { viewModel.selectedBoxID = nil }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete box (undo with ⌘Z)")
            }
            .opacity(box.isHidden ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : nil)
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

    private func deleteLabel(_ label: String) {
        guard store.removeLabelIfUnused(label) else { return }
        if viewModel.drawLabel == label {
            viewModel.drawLabel = store.labels.ordered.first ?? "object"
        }
    }
}
