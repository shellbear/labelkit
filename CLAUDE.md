# labelkit

A native macOS bounding-box annotator for **Apple Create ML object-detection
datasets**, launched from the terminal: `labelkit <dataset>`. It treats the
dataset's `annotations.json` as the source of truth — edit boxes, hit ⌘S, and
the file is rewritten in place, byte-stable and git-diff friendly.

Pure SwiftPM: there is no `.xcodeproj`. `Package.swift` drives everything
(macOS 14+, Swift 5.9 tools).

## Build & test

```sh
swift run labelkit <path>            # dev run
swift build -c release               # release binary at .build/release/labelkit
swift test                           # headless library tests
./scripts/package-app.sh             # assemble labelkit.app next to the binary
./scripts/package-app.sh --universal # arm64+x86_64 fat build (used by release CI)
```

The `Makefile` wraps these (`make build/test/app/universal/install`);
`make install` puts the CLI + app bundle into the Homebrew prefix's `bin`.

For scale/perf testing, generate a realistic dataset instead of hand-rolling
one: `swift scripts/make-sample-dataset.swift 10000 /tmp/labelkit-sample` draws
a few dozen distinct camera-resolution JPEGs (real decode cost) and fans out to
N via symlinks (tiny on disk). See the `swift-perf-profiling` skill in
`.claude/skills/` for the headless xctrace capture/analyze workflow.

CI (`.github/workflows/ci.yml`) builds and tests on macOS 14 and 15, then
smoke-runs `.build/release/labelkit --version` — that invocation must exit
cleanly without ever touching AppKit (no window flash).

## Architecture: two targets, hard boundary

- **`Sources/LabelKit`** — the library: format IO, dataset store, geometry,
  imaging. **No AppKit or SwiftUI imports allowed here.** Everything must run
  headless; all tests (`Tests/LabelKitTests`) target this module only.
- **`Sources/LabelKitApp`** — thin executable shell: ArgumentParser CLI,
  AppKit app controller, SwiftUI views. The directory is named `LabelKitApp`
  rather than `labelkit` because APFS is case-insensitive and would collide
  with the `labelkit` product name.

New logic belongs in `LabelKit` with tests unless it genuinely needs UI.

### Launch rules (don't "modernize" these)

- There is no `@main`: ArgumentParser and SwiftUI both claim it, so
  `main.swift` calls `LabelKitCommand.main()`, and `run()` hands off to the
  app only after arguments validate. CLI-only paths (`--version`, `--help`,
  argument errors) must never initialize AppKit.
- The app is a classic AppKit shell with an **imperatively created
  `NSWindow`** hosting SwiftUI (`LabelKitApp.swift`). SwiftUI's `WindowGroup`
  never creates its window while the app is inactive, and macOS 14+
  cooperative activation refuses terminal-spawned processes — a bare CLI
  launch showed nothing until a Dock click. Do not refactor back to the
  SwiftUI `App`/`WindowGroup` lifecycle.
- The window carries an empty `NSToolbar` on purpose: a hosted
  `NavigationSplitView` only gets the unified-titlebar chrome when the window
  has a toolbar.
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

Releasing = bump that file, commit, tag `vX.Y.Z`, push the tag.
`.github/workflows/release.yml` then builds universal + per-arch artifacts
and publishes the GitHub release; the Homebrew tap
(`shellbear/tap/labelkit`) serves the thin slices via `on_arm`/`on_intel`.
