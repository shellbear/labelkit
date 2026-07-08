---
name: swift-perf-profiling
description: >-
  Profile and fix performance problems in a native macOS/AppKit/SwiftUI app
  (SwiftPM or Xcode) using xctrace/Instruments, analyzed headlessly from the
  command line. Use this whenever a Mac app feels slow, janky, or laggy —
  stuttering while scrolling or navigating a list, dropped frames, beachballs
  or hangs, high CPU on the main thread, or slow selection in a large table —
  and whenever the user mentions Instruments, xctrace, Time Profiler, hitches,
  or "why is my SwiftUI app slow". Reach for this BEFORE hand-optimizing on a
  hunch: it captures a trace while driving the app, then attributes
  main-thread cost to concrete functions so you fix the real bottleneck, not
  a guessed one. Also carries hard-won macOS/Swift performance findings
  (SwiftUI List vs NSTableView at scale, view-identity rebuilds, URL cost,
  decode pipelines) worth consulting even before a trace exists.
---

# Swift / macOS performance profiling

The point of this skill: **measure before you optimize.** GUI performance
intuition is unreliable — the slow thing is rarely where it feels like it is.
A real investigation once spent significant effort optimizing an image-decode
pipeline when a headless trace showed the actual bottleneck was a SwiftUI
`List` re-diffing 10k rows on every keystroke. The trace redirected the whole
effort. Do the same: capture, attribute, then fix the top item.

This works **headlessly** — you can drive the app, record a trace, and analyze
it entirely from the command line, without opening the Instruments GUI.

## When to use

- The app stutters/lags while scrolling, navigating, or selecting.
- Dropped frames, beachballs, "not responding", or main-thread hangs.
- The user wants to know *why* something is slow, or asks about Instruments /
  xctrace / Time Profiler / hitches / hangs.
- Before AND after a performance change, to get a before/after number.

If the user just wants known macOS/Swift perf pitfalls without a trace, jump
straight to `references/findings.md`.

## The workflow

### 1. Build a release binary and launch it

Profile **release** (`-c release` / Release config), never debug — debug
builds have wildly different performance. Launch the app with a realistic
dataset (the bug usually only shows at scale — thousands of items, big files).

Generating a large realistic dataset is the part people get stuck on — real
*content* is cheap to fake, but thousands of realistically-sized *files* are
not. Don't hand-roll it every time: if the project ships a fixtures generator,
use it. In labelkit that's `scripts/make-sample-dataset.swift`
(`swift scripts/make-sample-dataset.swift 10000 /tmp/labelkit-sample`) — it
draws a few dozen distinct camera-resolution JPEGs (real decode cost) and
fans out to N via symlinks (tiny on disk), so per-item decode cost stays
representative. The reusable trick for any image-heavy app: generate a small
set of distinct, realistically-sized base files, then symlink to N unique
names — unique URLs give real cache-miss decodes without N physical files.

### 2. Capture a trace while driving the app

Use `scripts/capture.sh` (below). It attaches `xctrace` to the running
process, records for a fixed window, and — critically — **drives the app
during the recording** so the slow interaction actually happens.

```sh
scripts/capture.sh <label> <process-name> [seconds]
# e.g. scripts/capture.sh before labelkit 8
```

Two things that trip people up, both handled by the script:

- **Prefer `--instrument` over `--template`** on Xcode 26+ (`--template` can
  produce export errors). `'Time Profiler'` is the workhorse — it gives the
  main-thread call tree, which is what attributes the cost.
- **Driving the app:** raw keystroke synthesis (`key code`) and screenshots
  often **do not land** in a headless/automation context. **Menu-bar clicks
  via System Events DO land.** So drive the interaction by repeatedly clicking
  a menu item that triggers it (e.g. a "Next Image" / "Find Next" command).
  If the app has no such menu item, add a temporary one, or ask the user to
  perform the interaction while you record. Edit the `drive_interaction`
  function in `capture.sh` to match the app's menu.

### 3. Analyze the trace (headless)

Use `scripts/analyze.py`. It exports the Time Profiler table and reports
**main-thread on-CPU time attributed by subsystem** (SwiftUI diffing, AppKit,
Core Animation, your own symbols, etc.).

```sh
python3 scripts/analyze.py <label>.trace <label>
```

**The one non-obvious gotcha it handles:** xctrace's XML export **deduplicates
repeated stacks** — the first occurrence of a frame/backtrace is defined with
an `id`, and every later identical sample is emitted as a `ref` with no symbol
names. A naive regex/count over `<frame name=...>` therefore **massively
undercounts** hot paths (you'll see 58 ms where the truth is 800 ms). `analyze.py`
builds the `id -> name` and `backtrace-id -> [frames]` maps first, then
resolves every sample's `ref`. Always resolve refs before trusting counts.

### 4. Interpret — attribute the cost, then fix the top item

Read the subsystem breakdown. Typical culprits and what they mean:

- `OutlineListCoordinator.recursivelyDiffRows` / `diffRows` / heavy `ForEach`
  → a **SwiftUI `List` re-diffing its whole collection**. At thousands of rows
  this is O(n) per update and dominates. Fix: `NSTableView`
  (`references/findings.md`).
- `ViewGraph.setRootView` / `AttributeGraph` churn → SwiftUI view bodies
  re-evaluating too often. Look for a parent view re-rendering the world.
- `CA::` (Core Animation Commit) → layer compositing; usually downstream of
  the above, drops when you fix the view churn.
- Your own hot symbol (e.g. a URL builder, a per-row computation) → cache it.
- Almost-empty main thread but many hangs → the main thread is **blocked
  waiting** (lock/semaphore/sync IO), not burning CPU. Look at what it awaits.

Then fix the single biggest item, re-run `capture.sh after`, and compare the
two numbers. One change at a time — the trace tells you if it worked.

## Known findings (consult even without a trace)

`references/findings.md` is a checklist of concrete, verified macOS/Swift
performance patterns from real investigations — SwiftUI `List` vs `NSTableView`
at scale, `.id()`-driven view rebuilds, isolating re-render scope,
`URL.appendingPathComponent` cost, image-decode pipeline design, embedded EXIF
thumbnails, and the automation/interaction tricks. Read it when designing a
list-heavy or image-heavy Mac UI, or when a trace points at one of these.

## Scripts

- `scripts/capture.sh` — attach xctrace, record a fixed window, drive the app
  via menu clicks, then call the analyzer. Customize `drive_interaction`.
- `scripts/analyze.py` — export the Time Profiler table and report main-thread
  cost by subsystem, resolving xctrace's id/ref stack dedup.
