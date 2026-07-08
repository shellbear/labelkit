# labelkit

A native macOS bounding-box annotator for **Apple Create ML object-detection
datasets** — launched from the terminal, no project files, no accounts, no
format conversion.

```
labelkit path/to/dataset
```

Your images appear with their existing boxes. Edit, hit ⌘S, and your
`annotations.json` is updated in place — byte-stable, git-diff friendly.

## Why

Create ML consumes a simple, documented JSON format — but nothing edits it
natively. Web annotators need drag-drop rituals and format conversion on
every session; the one native tool that round-trips the format is paid. If
your dataset lives in git next to your training scripts, you want a tool
that treats the JSON as the source of truth and leaves everything else alone.

labelkit's contract:

- **Filenames are never touched.** Whatever `"image"` says is what gets saved.
- **Negatives survive.** Entries with zero annotations are training signal,
  not garbage — they round-trip. Deleting a box down to zero keeps the entry.
- **Unknown keys survive.** Extra fields on entries or annotations
  (`imageWidth`, custom metadata, …) are preserved verbatim.
- **Canonical output.** Stable key order, 2-decimal coordinates, 2-space
  indent, trailing newline — the same input always saves to the same bytes,
  so your `git diff` shows only real changes.
- **Scales.** Tens of thousands of images open instantly; thumbnails decode
  lazily with a hard memory budget (a 10k-image dataset idles around ~20 MB).

## Install

```bash
brew install shellbear/tap/labelkit
```

Prebuilt universal binaries (arm64 + x86_64) also hang off every
[GitHub release](https://github.com/shellbear/labelkit/releases). Or from
source (macOS 14+, Xcode 15+):

```bash
git clone https://github.com/shellbear/labelkit && cd labelkit
make install    # builds and installs into your Homebrew prefix (or /usr/local)
```

`make install PREFIX=~/.local` installs elsewhere; `make app` just builds —
the CLI and `labelkit.app` land in `.build/release/`, side by side (the CLI
launches through the sibling bundle, so keep them together).

## Usage

```bash
labelkit <folder>              # folder with images; annotations.json auto-detected,
                               # created on first save if absent
labelkit <labels.json>         # a Create ML JSON; images resolved next to it
labelkit                       # open panel
labelkit <folder> --annotations other.json   # explicit annotations path
labelkit <folder> --images '*.jpg'           # filter images by glob
```

## Detecting from the CLI

`labelkit detect` runs an object detector over an image (or a whole directory)
and prints the boxes to stdout. It never opens the editor or touches the GUI —
same rule as `--version` — so it's safe to pipe, redirect, and script.

Pick exactly one detector: a custom Core ML model, or a built-in Apple Vision
detector (`rectangles`, `faces`, `humans`, `animals`, `saliency`).

```bash
labelkit detect photo.jpg --model cards.mlpackage             # custom Core ML model
labelkit detect photo.jpg --detector rectangles               # built-in Vision detector
labelkit detect ./images  --detector faces --format ndjson    # a directory, one JSON line per image
labelkit detect photo.jpg --model cards.mlpackage --render out.png   # also write an annotated PNG
```

Output is JSON by default (`--format json|ndjson|text`). Boxes are reported
twice — in image pixels and normalized `[0,1]`, **both top-left origin** — so
no consumer has to re-derive the coordinate convention:

```json
{
  "schemaVersion": 1,
  "detector": "Rectangles",
  "source": "vision",
  "image": "photo.jpg",
  "width": 2048,
  "height": 1536,
  "detections": [
    {
      "label": "card",
      "confidence": 0.9712,
      "box": { "x": 326.39, "y": 490.28, "width": 247.78, "height": 427.68 },
      "normalized": { "x": 0.15937, "y": 0.31919, "width": 0.121, "height": 0.27844 }
    }
  ]
}
```

Common options:

| Option | Meaning |
|---|---|
| `--model PATH` | custom Core ML model (`.mlmodel` / `.mlpackage` / `.mlmodelc`) |
| `--detector NAME` | built-in Vision detector (see list above) |
| `--format json\|ndjson\|text` | output shape (default `json`) |
| `--render PATH` | also write an annotated PNG — a file for one image, a directory for many |
| `--min-confidence 0–1` | drop detections scoring below this (default `0.5`) |
| `--label NAME` | label for localize-only detectors (`rectangles`, `faces`, …) |
| `--glob '*.jpg'` | which files a directory run picks up |
| `--max-pixel N` | longest edge to decode to before detection (default `1536`) |

Machine-readable output goes to stdout; progress and warnings go to stderr.

## Editing

| Action | How |
|---|---|
| Draw a box | drag on empty area |
| Select / move | click / drag a box |
| Resize | drag any of the 8 handles (drag past the opposite edge to flip) |
| Delete box | ⌫ |
| Change label | click a label in the inspector, or press 1–9 |
| New label | inspector text field |
| Undo / redo | ⌘Z / ⇧⌘Z (one drag = one undo step) |
| Previous / next image | ← / → (also ⌘↑ / ⌘↓) |
| Zoom | pinch, or ⌥ + scroll (anchored under the cursor) |
| Pan | two-finger scroll |
| Fit to window | ⌘0 |
| Save | ⌘S (you'll be prompted on quit if anything is unsaved) |

## Format

Apple Create ML object detection JSON — one file for the whole dataset,
coordinates are box **centers** in pixels, top-left origin. Official
references: Apple's [Building an object detector data
source](https://developer.apple.com/documentation/createml/building-an-object-detector-data-source)
(Create ML / `MLObjectDetector`) and the [Turi Create object detection
guide](https://apple.github.io/turicreate/docs/userguide/object_detection/),
which spells out the center-anchored coordinate semantics.

> Note on key names: Apple's `MLObjectDetector.DataSource` reference shows an
> `imagefilename`/`annotation` spelling, while the Create ML **app** and the
> wider ecosystem (Roboflow, RectLabel, …) use `image`/`annotations`.
> labelkit reads and writes the `image`/`annotations` variant — the one the
> Create ML framework accepts in practice and the ecosystem interchanges.

```json
[
  {
    "image": "photo-001.jpg",
    "annotations": [
      {
        "label": "card",
        "coordinates": { "x": 450.28, "y": 1075.12, "width": 247.78, "height": 427.68 }
      }
    ]
  },
  { "image": "background-only.jpg", "annotations": [] }
]
```

Notes:

- Entries whose image file is missing on disk are flagged in the sidebar and
  saved back untouched — datasets never silently shrink.
- EXIF orientation is applied everywhere, so coordinates always refer to the
  image as displayed (which is what Create ML expects).

## Roadmap

- YOLO / COCO import & export (the format layer is already pluggable)

## License

MIT
