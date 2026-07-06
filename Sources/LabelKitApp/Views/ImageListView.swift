import LabelKit
import SwiftUI

/// Virtualized sidebar. `List` is NSTableView-backed on macOS — rows are
/// recycled, so 10k+ images stay cheap. Rows read only their own
/// @Observable entry: box edits elsewhere never re-render the list.
struct ImageListView: View {
    let store: DatasetStore
    @Binding var selection: String?

    var body: some View {
        List(store.entries, selection: $selection) { entry in
            ImageRowView(entry: entry, imageURL: store.imageURL(for: entry))
        }
        .listStyle(.sidebar)
    }
}

struct ImageRowView: View {
    let entry: ImageEntry
    let imageURL: URL

    @State private var thumbnail: CGImage?
    @Environment(\.displayScale) private var displayScale

    private static let thumbnailPoints: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
                .frame(width: Self.thumbnailPoints, height: Self.thumbnailPoints)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(entry.filename)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if entry.imageFileMissing {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .help("Image file missing on disk — entry kept in annotations")
            } else if !entry.boxes.isEmpty {
                Text("\(entry.boxes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            } else if entry.hasEntryInFile {
                // Explicit negative example.
                Text("0")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 44)
        // .task(id:) cancels when the row scrolls off screen — this, plus the
        // provider's own cancellation check, is the 10k-scroll safety valve.
        .task(id: entry.filename) {
            guard thumbnail == nil, !entry.imageFileMissing else { return }
            thumbnail = await ThumbnailProvider.shared.thumbnail(
                for: imageURL, maxPixel: Self.thumbnailPoints * displayScale)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: displayScale)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}
