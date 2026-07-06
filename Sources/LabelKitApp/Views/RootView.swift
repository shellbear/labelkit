import LabelKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Group {
            if let store = appState.store {
                NavigationSplitView {
                    ImageListView(store: store, selection: $appState.selectedFilename)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                } detail: {
                    if let entry = appState.selectedEntry {
                        CanvasView(store: store, entry: entry)
                            .id(entry.filename)
                    } else {
                        ContentUnavailableView(
                            "No Image Selected",
                            systemImage: "photo.on.rectangle.angled")
                    }
                }
                .navigationTitle(store.location.displayName)
                .navigationSubtitle(subtitle(for: store))
            } else {
                emptyState
            }
        }
        .alert("Could Not Open Dataset",
               isPresented: .init(
                   get: { appState.loadError != nil },
                   set: { if !$0 { appState.loadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.loadError ?? "")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("labelkit", systemImage: "rectangle.dashed.badge.record")
        } description: {
            Text("Open a folder of images, or a Create ML annotations.json file.")
        } actions: {
            Button("Open Dataset…") { appState.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func subtitle(for store: DatasetStore) -> String {
        let boxCount = store.entries.reduce(0) { $0 + $1.boxes.count }
        let dirty = store.isDirty ? " — Edited" : ""
        return "\(store.entries.count) images · \(boxCount) boxes\(dirty)"
    }
}
