import LabelKit
import SwiftUI

/// The Train toolbar button — opens the training sheet. Greyed with no dataset
/// open or while a run is already in flight. Mirrors `GenerateControlView`.
struct TrainControlView: View {
    let controller: TrainController
    let appState: AppState

    var body: some View {
        Button {
            controller.presentSheet()
        } label: {
            Label("Train", systemImage: "brain.head.profile")
        }
        .fixedSize()
        .disabled(appState.store == nil || controller.isRunning)
        .help("Train a Core ML model from this dataset")
    }
}
