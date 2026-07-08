# macOS / Swift performance findings

Concrete, trace-verified patterns from real investigations. Each entry: the
symptom, the cause, and the fix. Consult when designing a list-heavy or
image-heavy Mac UI, or when a trace points at one of these.

## 0. Profile before optimizing (the meta-lesson)

GUI slowness intuition is wrong more often than it's right. In one case, a team
optimized an image-decode pipeline (prefetch, caching, debounce) — all real
improvements — while the actual scrub bottleneck was a SwiftUI `List`
re-diffing 10k rows per keystroke, which none of the decode work touched. Only
a Time Profiler trace revealed it. **Capture a trace, attribute main-thread
cost to a function, fix the top item, re-trace. One change at a time.**

## 1. SwiftUI `List` re-diffs its whole collection at scale → use `NSTableView`

**Symptom:** holding an arrow key / fast selection changes stutter; the trace
shows `OutlineListCoordinator.recursivelyDiffRows`, `diffRows`, and heavy
`ForEach` dominating the main thread (hundreds of ms per update at ~10k rows).

**Cause:** SwiftUI `List` reconciles its entire row collection on any update
that a selection change triggers — an O(n) diff. It is inherent; you cannot
fix it from the SwiftUI side. Verified by removing, one at a time: the
`selection:` binding, the root view's re-render, and even every per-row read of
the selection — the diff persisted each time (samples barely moved: 61 → 42 →
45).

**Fix:** wrap `NSTableView` (or `NSCollectionView`) in an `NSViewRepresentable`.
Selection and scroll become O(1) and only the affected rows update — no
diffing. In the real case this dropped main-thread scrub cost ~780 ms → ~180 ms
and `recursivelyDiffRows` 215 ms → ~2 ms. Bonus: `NSCollectionView` exposes a
prefetch protocol (`NSCollectionViewPrefetching`) that SwiftUI `List` lacks.

Cost: you re-draw the cell and the selection highlight yourself in AppKit.
Keep cells lightweight (a backing-layer thumbnail + `NSTextField`), cancel
async work in `prepareForReuse`, and match the system look (e.g. subtle
`quaternaryLabelColor` badges — don't force a darker alpha).

Note: a *small* SwiftUI `List` (a few dozen rows, e.g. an inspector) is fine —
this only bites at scale with frequent updates.

## 2. `.id(...)` on a view forces a full teardown + rebuild → update in place

**Symptom:** every navigation step re-creates a whole subtree; `@State` (view
models, loaders) resets and the view flashes to a placeholder each step;
`NSViewRepresentable`s get torn down and re-made.

**Cause:** changing the value passed to `.id()` tells SwiftUI the view has a new
identity, so it destroys the old one and builds a new one from scratch.

**Fix:** keep stable identity and update the existing view via
`.onChange(of: key)`, resetting per-item state explicitly (zoom, selection,
etc.). Reserve `.id()` for coarse identity that genuinely should rebuild (e.g.
switching *datasets*, not switching *items* within one).

## 3. Isolate re-render scope so one change doesn't re-render siblings

**Symptom:** changing a selection re-runs a big parent `body`, which re-creates
an expensive sibling (like the whole sidebar) even though only the detail
should change.

**Cause:** the parent `body` reads the changing value (e.g. `selectedEntry`) to
build the detail pane, so the entire parent — including unrelated children —
re-evaluates.

**Fix:** push the volatile read down into the smallest child that needs it
(extract a `DetailPane` view that reads `selectedEntry`). The parent stops
depending on it, so navigation re-renders only that child. This alone removed
one full sidebar re-create per step in the real case.

## 4. `URL.appendingPathComponent` is surprisingly expensive → cache URLs

**Symptom:** a URL-builder helper shows up as a top main-thread symbol
(`_SwiftURL`, `appendingPathComponent`) during scrolling.

**Cause:** `appendingPathComponent` does path normalization; called per visible
row per update it adds up (223 ms of a scrub in one trace).

**Fix:** precompute the URLs once (e.g. a `[filename: URL]` map built at load)
and look them up. Dropped 223 ms → 6 ms.

## 5. Image-decode pipeline for large collections

Design the decoder as a shared actor with all of:

- **Bounded concurrency** — a small slot count (2–3); a fast scroll must not
  fan out one full-size decode per item. Unbounded decodes spiked one app to a
  ~830 MB footprint.
- **Cancellation that actually cancels** — an unstructured `Task` does NOT
  inherit the caller's cancellation. Use `withTaskCancellationHandler` (or an
  explicit token) so a scrolled-away request drops before it starts. A
  synchronous decode already in flight can't be interrupted, so the win is
  skipping not-yet-started work.
- **A per-key LRU cache** (`NSCache`, byte-budgeted, keyed at the largest size
  decoded) so revisiting an item is instant, not a fresh disk decode.
- **Velocity-aware debounce** — a discrete step decodes immediately (feels
  instant); a fast held scrub debounces the expensive decode and shows a cheap
  placeholder, so CPU stays free for the placeholders to keep up.
- **Direction-aware prefetch** on deliberate steps (warm the next few items),
  suppressed during a fast scrub.

## 6. Prefer the embedded EXIF thumbnail for small tiers

For sidebar/placeholder thumbnails of large JPEGs, pass
`kCGImageSourceCreateThumbnailFromImageIfAbsent` (not `...FromImageAlways`) to
`CGImageSourceCreateThumbnailAtIndex`. Camera JPEGs embed a ~160 px thumbnail;
using it is ~10× cheaper than DCT-decoding a 4000 px image, and it falls back
to a full decode when absent (so it's never slower). Keep the *full-detail*
canvas decode on `...FromImageAlways` — an embedded thumb is useless there.
Also read image dimensions header-only for cheap aspect-ratio layout.

## 7. SwiftUI animation scope leaks into geometry

**Symptom:** navigating between differently-sized items animates the frame
width/height (the image visibly grows/shrinks) when only a cross-fade was
intended.

**Cause:** an ambient `.animation(_:value:)` on a container animates *every*
change in its scope — including a `.frame(...)` that changed in the same
transaction as the animated value.

**Fix:** don't put a broad `.animation(value:)` over views whose geometry also
changes. Scope the animation to just the property that should animate, or drop
the implicit animation entirely (an instant swap is better than a warping one).

## 8. Automation / interaction tricks (headless profiling)

- **Menu clicks land; keystrokes and screenshots often don't.** In a headless
  automation session, synthesized `key code` events frequently don't reach the
  app and `screencapture` returns black (no interactive window server). But
  clicking a menu-bar item via System Events *does* land — so drive slow
  interactions through a menu command (add a temporary one if needed).
- **`sample <pid> <secs>`** is a quick symbolized CPU snapshot when you don't
  need hitches/hangs — but it can't drive the app, so pair it with menu clicks.
- **`xcrun xctrace export --toc`** lists a trace's tables; export one with
  `--xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'`.
- **Resolve id/ref dedup** before counting (see `scripts/analyze.py`).
- **`filtercalltree`** can post-process a call tree (inversion,
  library-cost attribution) if you'd rather not hand-roll the aggregation.
- Useful tables: `time-profile` (CPU), `hitches` / `potential-hangs` (dropped
  frames & main-thread stalls, with durations), `swiftui-*` (View Body updates
  — note these may not capture in an `NSHostingView`-based app).
