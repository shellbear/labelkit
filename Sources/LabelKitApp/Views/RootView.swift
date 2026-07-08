import AppKit
import LabelKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    /// Highlights the whole window while an image/folder drag hovers it.
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var appState = appState
        Group {
            if let store = appState.store {
                NavigationSplitView {
                    ImageListView(store: store)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                } detail: {
                    // The selected-image read lives in DetailPane, NOT here:
                    // if RootView.body read `selectedEntry` it would re-run on
                    // every arrow step and re-create the whole split view —
                    // including the sidebar List, which then re-diffs all 10k
                    // rows (~270 ms hang/step in a profiler trace). Isolating it
                    // means only the detail pane re-renders on navigation.
                    DetailPane(store: store)
                }
                .onAppear { syncWindowChrome(store) }
                .onChange(of: store.isDirty) { syncWindowChrome(store) }
            } else {
                emptyState
            }
        }
        // Drag images (or a folder) anywhere in the window to import them into
        // the open dataset — or, with nothing open, to open their folder.
        .dropDestination(for: URL.self) { urls, _ in
            appState.importImages(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.tint, lineWidth: 4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
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

    /// Detail pane, split out so that reading the selection re-renders only
    /// this subtree on navigation — never the sidebar.
    private struct DetailPane: View {
        let store: DatasetStore
        @Environment(AppState.self) private var appState

        var body: some View {
            if let entry = appState.selectedEntry {
                // Keyed on the dataset, NOT the image: navigating between images
                // updates the canvas in place (cheap), while switching datasets
                // recreates it so the view model and loader re-capture the store.
                CanvasView(store: store, entry: entry)
                    .id(store.location.annotationsURL)
            } else {
                ContentUnavailableView(
                    "No Image Selected",
                    systemImage: "photo.on.rectangle.angled")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("labelkit", systemImage: "rectangle.dashed.badge.record")
            } description: {
                Text("Open a folder of images, or a Create ML annotations.json file.")
            } actions: {
                Button("Open Dataset…") { appState.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            if !appState.recentLocations.isEmpty {
                recentsList
                    .padding(.bottom, 28)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
            ForEach(appState.recentLocations, id: \.self) { location in
                RecentProjectRow(
                    location: location,
                    action: { appState.requestOpen(location) },
                    onRemove: { appState.removeRecent(location) })
            }
        }
        .frame(width: 380)
    }

    private struct RecentProjectRow: View {
        let location: DatasetLocation
        let action: () -> Void
        let onRemove: () -> Void
        @State private var hovering = false

        var body: some View {
            // The row itself opens the dataset (tap gesture, not a Button) so
            // the trailing ✕ can be a real sibling Button — nested Buttons don't
            // route clicks reliably on macOS. The child Button consumes its own
            // clicks, so the row's tap fires everywhere except over the ✕.
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(location.displayName)
                    Text((location.imagesDirectory.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                // Kept in layout (opacity, not if) so the text never reflows as
                // it fades in on hover — revealed like Safari's Start Page items.
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from Recent")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(
                hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
        }
    }

    private func syncWindowChrome(_ store: DatasetStore) {
        guard let window = NSApp.windows.first else { return }
        let boxCount = store.entries.reduce(0) { $0 + $1.boxes.count }
        window.title = store.location.displayName
        window.subtitle = "\(store.entries.count) images · \(boxCount) boxes"
        window.isDocumentEdited = store.isDirty
    }
}
