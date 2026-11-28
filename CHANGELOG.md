# Changelog

All notable changes to labelkit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The release workflow publishes the section for the pushed tag as the GitHub
release notes, so every release needs a `## [X.Y.Z] - YYYY-MM-DD` heading here.

## [Unreleased]

### Added

- **`labelkit import`.** Bring a YOLO, COCO or Hugging Face image dataset into
  a Create ML dataset: images are copied in and boxes merged into
  `annotations.json`. The format is detected, existing files are never
  overwritten (a clashing name is renamed and its boxes follow), importing the
  same source twice changes nothing, and a source with unusable boxes imports
  nothing unless `--lenient` is given. `--names` supplies class names for a
  source that only has numeric ids.
- **`labelkit export`.** Write a dataset out as YOLO (`images/`, `labels/`,
  `data.yaml`), COCO (`_annotations.coco.json`) or a Hugging Face image dataset
  (`metadata.jsonl` plus a dataset card), ready for `hf upload`.
- **[docs/datasets.md](docs/datasets.md).** Recipes for publishing on Hugging
  Face, keeping images in an R2/S3 bucket with only `annotations.json` in git,
  and using a large model as a teacher to label data for a small Create ML
  model.

## [0.3.0] - 2026-11-28

### Added

- **Use labelkit from an AI agent.** `labelkit skill --install` teaches Claude
  Code, Codex, opencode, Cursor, Gemini CLI, GitHub Copilot, Amp, Goose and
  other clients how to label with labelkit, by installing an Agent Skill where
  each of them looks for one (`--project` for a single repository,
  `--snippet` for a few lines of `AGENTS.md` instead). The guide is built into
  the binary, so it always matches the installed version. See
  [docs/agents.md](docs/agents.md).
- **`labelkit annotate`.** Write boxes into a dataset from the terminal: inline
  (`--image a.jpg --box 'cat:40,30,200,160'`), or from JSON / NDJSON on a file
  or stdin. It reads what vision models and other tools actually produce —
  Gemini `box_2d`, corner lists, 0–1 and 0–1000 coordinates, YOLO-style
  centres, COCO files, `labelkit detect` output — with `--units`, `--origin`,
  `--anchor`, `--order` and `--image-size` to name a convention rather than
  convert it. Adding is idempotent (a repeat run leaves the file byte-identical),
  `--mode replace` corrects an image, `--negatives` records object-free images,
  and a run with any unusable input writes nothing.
- **`labelkit stats`.** A JSON summary of a dataset: labelled, negative,
  unlabelled and missing images, boxes per label, and the image with the most
  boxes.
- **`labelkit validate`.** Checks a dataset and exits 1 on errors: missing
  images, boxes outside their image, empty or unknown labels, duplicate
  entries; and warns about overflowing boxes, duplicate boxes, and the same
  photo saved under two names.
- **`labelkit render`.** Draws a dataset's boxes onto downscaled pictures to
  check labels by eye, numbered to match `validate`. `--grid N` adds a ruler in
  original-image pixels and `--unlabeled` renders the images still to do.
- **`labelkit <dataset> --select <image>`.** Opens the editor on a given image;
  if the editor is already open it reloads the dataset and jumps there.

### Changed

- **Large datasets open and save faster.** Reading an annotations file,
  listing the image folder and writing the file back were reworked; on a
  10,000-image dataset saving is about five times faster and loading about
  twice as fast. Saved files are byte-for-byte what they were before.

## [0.2.1] - 2026-11-28

### Added

- **App icon.** labelkit now has its own icon in the Dock, Finder and the app
  switcher: a bounding box with round corner handles on an orange-to-red
  gradient. It is a layered Liquid Glass icon on macOS 26 and later (with dark,
  clear and tinted appearances) and a classic icon on macOS 14 and 15.

## [0.2.0] - 2026-11-25

### Added

- **Model-assisted labelling.** Generate boxes from a custom Core ML model or
  a built-in Vision detector (rectangles, faces, people, animals, saliency)
  from the Detect menu or the toolbar: ⌘G on the sidebar selection, plus New
  Images and All Images. Results merge additively — existing boxes are kept and
  re-running never duplicates — and each image's boxes are one undo step.
- **`labelkit detect`.** A headless subcommand that runs a Core ML model or a
  Vision detector over an image or directory and emits boxes as JSON, NDJSON,
  or text, with an optional annotated PNG via `--render`.
- **`labelkit train`.** Train a Create ML object detector to an `.mlmodel`
  from the terminal (`--max-iterations`, `--validation-split`, transfer
  learning or full network), with progress on stderr and a JSON report on
  stdout.
- **Train in the app.** A Train toolbar button and sheet showing the phase,
  elapsed time, a time-left estimate, live loss, and validation mAP. A
  finished model becomes the active detector and is revealed in Finder.
- **Drag-and-drop import.** Drop images or folders on the window or the Dock
  icon to copy them into the dataset. With nothing open, a drop opens the
  images' parent folder as the dataset.
- **Recent projects.** Up to five recents in File ▸ Open Recent and on the
  welcome screen, each removable individually.
- **Single-instance opens.** A later `labelkit <dataset>` hands the dataset to
  the running app instead of launching a second one, prompting to save first
  if the current project has unsaved changes.
- **`--wait` / `-w`.** Keeps the CLI in the foreground for the window's
  lifetime, like `code --wait`, so scripts can drive the app.
- **Multi-select sidebar** (⌘A, ⌘-click, ⇧-click).
- **`make install`.** Puts the CLI and `labelkit.app` into the Homebrew
  prefix.
- Version-less download aliases on each release
  (`releases/latest/download/labelkit-<arch>.tar.gz`).

### Changed

- **Navigation stays smooth on 10,000-image datasets.** The sidebar is now an
  AppKit table, upcoming images are prefetched, and a blurred thumbnail stands
  in while a full image decodes.
- Detail images are decoded with bounded concurrency and cached, so going back
  to a recent image is instant and peak memory is lower.
- The Generate and Train toolbar items appear only once a dataset is open.

### Fixed

- Launching `labelkit` from `PATH` blocked the terminal instead of detaching,
  because the app bundle was looked up relative to the working directory.

## [0.1.1] - 2026-07-07

### Added

- Per-architecture release archives (`arm64`, `x86_64`) alongside the
  universal build.

## [0.1.0] - 2026-07-06

### Added

- Initial release: a native macOS bounding-box annotator for Apple Create ML
  object-detection datasets, launched from the terminal with
  `labelkit <dataset>`.
- Byte-stable saves of `annotations.json`: filenames, unknown keys, and
  zero-annotation entries round-trip unchanged.
- Per-box hide/show, unused-label deletion, and a box list in the inspector.
- Keyboard navigation with a sidebar that follows the selection.
- Universal builds, GitHub releases on tag push, and a Homebrew formula
  (`shellbear/tap/labelkit`).

[Unreleased]: https://github.com/shellbear/labelkit/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/shellbear/labelkit/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/shellbear/labelkit/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/shellbear/labelkit/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/shellbear/labelkit/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/shellbear/labelkit/releases/tag/v0.1.0
