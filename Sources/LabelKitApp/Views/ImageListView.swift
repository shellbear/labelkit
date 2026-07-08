import AppKit
import LabelKit
import SwiftUI

/// AppKit `NSTableView`-backed sidebar.
///
/// SwiftUI `List` re-diffs all 10k rows on every selection change — a profiler
/// trace put that at ~270 ms of main-thread hang per arrow step, and removing
/// every SwiftUI-side trigger (selection binding, root re-render, per-row
/// selection read) did not stop it: the diff is inherent to `List` at scale.
/// `NSTableView` selects and scrolls in O(1) and only touches the affected
/// rows, so a held-arrow scrub costs nothing on the main thread here.
struct ImageListView: View {
    let store: DatasetStore
    @Environment(AppState.self) private var appState

    var body: some View {
        // Reading `selectedFilename` here (cheap now — no List) re-runs this
        // body on navigation and passes the new value into the representable,
        // whose updateNSView just selects + scrolls the row. Reading
        // `entriesRevision` likewise re-runs it after an import so the table
        // reloads its new rows.
        SidebarTable(
            store: store,
            selected: appState.selectedFilename,
            revision: store.entriesRevision,
            onSelect: { appState.selectedFilename = $0 }
        )
    }
}

private struct SidebarTable: NSViewRepresentable {
    let store: DatasetStore
    let selected: String?
    let revision: Int
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(store: store, onSelect: onSelect) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .sourceList
        table.headerView = nil
        table.rowHeight = 48
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .init("image"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        table.reloadData()
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(store: store, revision: revision, onSelect: onSelect)
        context.coordinator.syncSelection(to: selected)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var store: DatasetStore
        private var onSelect: (String) -> Void
        weak var table: NSTableView?
        private var storeID: ObjectIdentifier
        private var revision: Int
        private var programmatic = false

        init(store: DatasetStore, onSelect: @escaping (String) -> Void) {
            self.store = store
            self.onSelect = onSelect
            self.storeID = ObjectIdentifier(store)
            self.revision = store.entriesRevision
        }

        func update(store: DatasetStore, revision: Int, onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
            let id = ObjectIdentifier(store)
            if id != storeID {  // dataset switched → rebuild rows
                self.store = store
                self.storeID = id
                self.revision = revision
                table?.reloadData()
            } else if revision != self.revision {  // rows imported → reload new tail
                self.revision = revision
                table?.reloadData()
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { store.entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("imageCell")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? ImageCellView
                ?? ImageCellView(identifier: id)
            let entry = store.entries[row]
            cell.configure(entry: entry, url: store.imageURL(for: entry))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !programmatic, let table, table.selectedRow >= 0,
                  table.selectedRow < store.entries.count else { return }
            onSelect(store.entries[table.selectedRow].filename)
        }

        /// Reflect an external selection (arrow keys on the canvas) — O(1).
        func syncSelection(to filename: String?) {
            guard let table, let filename, let index = store.index(of: filename) else { return }
            guard table.selectedRow != index else { return }
            programmatic = true
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            programmatic = false
        }
    }
}

/// Lightweight AppKit cell: rounded fill-cropped thumbnail, filename, and a
/// box-count / missing badge. Thumbnails load async and cancel on reuse.
private final class ImageCellView: NSTableCellView {
    private let thumb = ThumbnailLayerView()
    private let title = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private var loadTask: Task<Void, Never>?
    private var filename: String?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.lineBreakMode = .byTruncatingMiddle
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.cell?.truncatesLastVisibleLine = true
        [thumb, title, badge].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 36),
            thumb.heightAnchor.constraint(equalToConstant: 36),
            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(entry: ImageEntry, url: URL) {
        filename = entry.filename
        title.stringValue = entry.filename
        badge.set(entry: entry)
        loadTask?.cancel()
        thumb.cgImage = nil
        guard !entry.imageFileMissing else { return }
        let name = entry.filename
        loadTask = Task { [weak self] in
            let image = await ThumbnailProvider.shared.thumbnail(for: url, maxPixel: 36 * Display.scale)
            guard let self, self.filename == name, let image else { return }
            self.thumb.cgImage = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        thumb.cgImage = nil
    }
}

/// Fill-cropped, rounded thumbnail via a plain backing layer (no NSImage).
private final class ThumbnailLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    var cgImage: CGImage? { didSet { layer?.contents = cgImage } }
}

/// Box-count pill, "0" negative marker, or missing-file warning.
private final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(entry: ImageEntry) {
        layer?.cornerRadius = 8
        if entry.imageFileMissing {
            label.stringValue = "!"
            label.textColor = .systemYellow
            layer?.backgroundColor = NSColor.clear.cgColor
        } else if !entry.boxes.isEmpty {
            label.stringValue = "\(entry.boxes.count)"
            label.textColor = .secondaryLabelColor
            // Subtle capsule, matching SwiftUI's `.quaternary` fill — use the
            // label color at its own (low) alpha, not a forced-darker 0.35.
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        } else if entry.hasEntryInFile {
            label.stringValue = "0"
            label.textColor = .tertiaryLabelColor
            layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            label.stringValue = ""
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
