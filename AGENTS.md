# labelkit

<!-- Project instructions for AI coding agents. This is the canonical file;
     CLAUDE.md only imports it, so every client reads the same text. -->

A native macOS bounding-box annotator for **Apple Create ML object-detection
datasets**, launched from the terminal: `labelkit <dataset>`. It treats the
dataset's `annotations.json` as the source of truth — edit boxes, hit ⌘S, and
the file is rewritten in place, byte-stable and git-diff friendly.

Pure SwiftPM: there is no `.xcodeproj`. `Package.swift` drives everything
(macOS 14+, Swift 5.9 tools).

## Build & test

```sh
swift run labelkit <path>            # dev run (GUI editor)
swift run labelkit detect <img> --detector rectangles   # headless detect subcommand
swift run labelkit train <dataset>   # headless train subcommand (Create ML → .mlmodel)
swift run labelkit stats <dataset>   # headless: what is labelled, what is not (JSON)
swift run labelkit validate <dataset>  # headless: dataset problems, exit 1 on errors
swift run labelkit annotate <dataset> --image a.jpg --box 'cat:40,30,200,160'  # headless: write boxes
swift run labelkit render <dataset> --out /tmp/check   # headless: draw the boxes to look at them
swift run labelkit skill             # print the guide for AI agents (SKILL.md)
swift build -c release               # release binary at .build/release/labelkit
swift test                           # headless library tests
./scripts/package-app.sh             # assemble labelkit.app next to the binary
./scripts/package-app.sh --universal # arm64+x86_64 fat build (used by release CI)
./scripts/make-icon.sh               # recompile the app icon after editing its source
```

The app icon's source of truth is `Resources/AppIcon.icon`, an Icon Composer
document (SVG layers + `icon.json`). Its compiled forms — `Resources/Assets.car`,
`Resources/AppIcon.icns` and the README's `docs/icon.png` — are **committed**:
`package-app.sh` only copies them, so packaging and the release CI never need an
Xcode that understands `.icon` files. After changing the icon, run
`make-icon.sh` (Xcode 26+) and commit the regenerated files with it.

The `Makefile` wraps these (`make build/test/app/universal/install`);
`make install` puts the CLI + app bundle into the Homebrew prefix's `bin`.

For scale/perf testing, generate a realistic dataset instead of hand-rolling
one: `swift scripts/make-sample-dataset.swift 10000 /tmp/labelkit-sample` draws
a few dozen distinct camera-resolution JPEGs (real decode cost) and fans out to
N via symlinks (tiny on disk). See the `swift-perf-profiling` skill in
`.claude/skills/` for the headless xctrace capture/analyze workflow. (Those
symlinked images are fine for the editor and `detect`, but Create ML *training*
reads real files only — dereference first, e.g. `cp -L`, before `labelkit train`.)

CI (`.github/workflows/ci.yml`) builds and runs the test suite on macOS 15
and 26. GitHub retired the macOS 14 runner image on 2026-11-02, so the macOS 14
minimum deployment target is guarded only at compile time, by the SDK's
availability checks against `Package.swift`'s `.macOS(.v14)`. It then
smoke-runs `.build/release/labelkit --version`, `labelkit detect --help`, and
`labelkit train --help` — those invocations must exit cleanly without ever
touching AppKit (no window flash) or kicking off Create ML — and drives the
scripted subcommands (`stats`, `annotate`, `validate`, `render`, `skill`) end to
end on a throwaway dataset, checking their exit codes and that a repeated
`annotate` leaves the file byte-identical.

## Architecture: two targets, hard boundary

- **`Sources/LabelKit`** — the library: format IO, dataset store, geometry,
  imaging. **No AppKit or SwiftUI imports allowed here.** Everything must run
  headless; all tests (`Tests/LabelKitTests`) target this module only.
- **`Sources/LabelKitApp`** — thin executable shell: ArgumentParser CLI,
  AppKit app controller, SwiftUI views. The directory is named `LabelKitApp`
  rather than `labelkit` because APFS is case-insensitive and would collide
  with the `labelkit` product name.

New logic belongs in `LabelKit` with tests unless it genuinely needs UI.

### The scripted surface (agents and scripts depend on it)

`stats`, `validate`, `annotate`, `render` and `skill` are the headless verbs
AI agents and shell scripts drive. Their logic is in
`Sources/LabelKit/Headless` (`DatasetDocument`, `BoxImportParser`,
`AnnotationMerge`, `DatasetSummary`, `DatasetValidator`, `DuplicateImages`,
`AgentGuide`); each command file in `LabelKitApp` only parses arguments and
prints. Treat the following as a public interface:

- **stdout is the result and nothing else** (JSON by default); notes go to
  stderr via `Headless.note`. **Exit 0** success, **1** the command ran and
  found or hit a problem, **64** usage error. Never touch AppKit.
- Every JSON report carries `schemaVersion`. Adding a field is fine; renaming,
  removing or changing the meaning of one means bumping it.
- `validate` issue `code`s and the `annotate` input shapes are part of the
  contract — extend, don't repurpose.
- Writes go through `DatasetDocument.save()` → `CreateMLWriter`, so the format
  contract below holds for scripted edits. `annotate --mode add` must stay
  idempotent down to the bytes (there is a test, and a CI check).
- **`AgentGuide.skill` is the guide agents read**, served by `labelkit skill`
  and committed as `skills/labelkit/SKILL.md`. A test fails if the two differ:
  after changing a command's behaviour or flags, update the guide and run
  `swift run labelkit skill > skills/labelkit/SKILL.md`. `docs/agents.md` is the
  human-facing version (per-client setup); keep it in step too.

These commands are expected to stay fast on large datasets (measured on 10,000
images / 26,000 boxes: `stats` ≈ 0.2 s, `annotate` ≈ 0.1 s, `validate` ≈ 0.6 s).
The costs that matter are Foundation bridging — keep filenames and labels as
native Swift strings (`String.native`), read `JSONSerialization` output as
`NSDictionary` rather than casting to `[String: Any]` — and per-file IO, which
goes through `concurrentMap`. Measure before and after if you touch the loader,
scanner or writer.

### Launch rules (don't "modernize" these)

- There is no `@main`: ArgumentParser and SwiftUI both claim it, so
  `main.swift` calls `LabelKitCommand.main()`. `LabelKitCommand` is a pure
  dispatcher; its `open` subcommand is the default, and only `OpenCommand.run()`
  hands off to the app (after arguments validate). Headless paths — `--version`,
  `--help`, argument errors, and the entire `detect` subcommand — must never
  initialize AppKit. CI smoke-tests both `--version` and `detect` to enforce it.
- The app is a classic AppKit shell with an **imperatively created
  `NSWindow`** hosting SwiftUI (`LabelKitApp.swift`). SwiftUI's `WindowGroup`
  never creates its window while the app is inactive, and macOS 14+
  cooperative activation refuses terminal-spawned processes — a bare CLI
  launch showed nothing until a Dock click. Do not refactor back to the
  SwiftUI `App`/`WindowGroup` lifecycle.
- The window carries an empty `NSToolbar` on purpose: a hosted
  `NavigationSplitView` only gets the unified-titlebar chrome when the window
  has a toolbar. The toolbar **items** are declared in SwiftUI with `.toolbar`
  on the split view (`RootView`), *not* via an AppKit `NSToolbarDelegate`: the
  hosted `NavigationSplitView` owns that toolbar (it injects the sidebar
  toggle), so delegate-provided items are silently ignored. Don't reintroduce a
  toolbar delegate — add controls to the `.toolbar` block instead.
- Later CLI invocations hand their dataset to the running instance via
  `DistributedNotificationCenter` (see `SingleInstance.swift`) instead of
  spawning a second app.

## Format contract (do not break)

labelkit's whole value is being a well-behaved editor of Create ML JSON.
Invariants, enforced by tests in `Tests/LabelKitTests`:

- **Filenames are never rewritten** — whatever `"image"` says is saved back.
- **Zero-annotation entries round-trip** — negatives are training signal, not
  garbage. Deleting the last box keeps the entry.
- **Unknown keys survive verbatim** on entries and annotations
  (`imageWidth`, custom metadata, …).
- **Canonical byte-stable output**: stable key order, 2-decimal coordinates,
  2-space indent, trailing newline. The same input always saves to the same
  bytes.
- Entries whose image file is missing on disk are flagged in the UI but saved
  back untouched — datasets never silently shrink.

If a change can alter saved bytes, extend the writer tests to prove stability
before and after.

## Versioning & release

`Sources/LabelKit/Version.swift` is the single source of truth for the
version. `scripts/package-app.sh` extracts it with a grep for a quoted
numeric literal, so keep the exact shape
`public let labelkitVersion = "X.Y.Z"`.

`CHANGELOG.md` (Keep a Changelog format) is the single source of release
notes: user-facing changes go under `## [Unreleased]` as they land.

Releasing = bump that file, rename `[Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
(add a fresh empty `[Unreleased]` and update the compare links at the bottom),
commit, then run `make release` (`scripts/release.sh`). It checks the tree and
the changelog, creates and pushes the `vX.Y.Z` tag, waits for
`.github/workflows/release.yml` to build the universal + per-arch artifacts and
publish the GitHub release (the changelog section becomes the notes;
`scripts/release-notes.sh` extracts it and fails the release if the section is
missing), then runs `scripts/update-tap.sh` to point the Homebrew tap
(`shellbear/tap/labelkit`, thin slices via `on_arm`/`on_intel`) at the new
version and checksums.

**A release is not done until the tap is updated.** CI cannot push to the tap
repo, so that step runs locally with your own git/gh credentials. If the tag
was pushed some other way, run `./scripts/update-tap.sh` once the Release
workflow is green (`--dry-run` shows the formula diff first).
