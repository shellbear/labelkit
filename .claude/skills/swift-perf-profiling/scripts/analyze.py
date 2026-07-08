#!/usr/bin/env python3
"""Analyze an Instruments Time Profiler trace headlessly.

    python3 analyze.py <trace.trace> <label>

Exports the time-profile table via `xctrace export` and reports MAIN-THREAD
on-CPU time attributed by subsystem, so you can see whether the cost is in
SwiftUI diffing, AppKit, Core Animation, or your own code.

THE GOTCHA THIS HANDLES: xctrace's XML export deduplicates repeated stacks.
The first time a frame/backtrace appears it is defined with an `id`; every
later identical sample is emitted as a bare `ref` with NO symbol names. A
naive count over `<frame name=...>` therefore massively undercounts hot paths
(you'll see 58 ms where the truth is 800 ms). We build id->name and
backtrace-id->[frames] maps first, then resolve every sample's ref.
"""
import re
import subprocess
import sys
from collections import Counter

# Substrings to attribute samples to. Order/independence doesn't matter; a
# single stack can match several buckets (they overlap because a stack nests
# e.g. ViewGraph -> OutlineList -> ForEach). Add your own symbols here.
SUBSYSTEMS = [
    "recursivelyDiffRows", "diffRows", "OutlineList", "ForEach",   # SwiftUI List
    "ViewGraph", "AttributeGraph", "SwiftUICore",                  # SwiftUI graph
    "NSTableView", "NSOutlineView", "NSCollectionView",            # AppKit lists
    "CA::", "QuartzCore",                                          # Core Animation
    "AppKit", "NSScrollView",
    "ImageIO", "CGImageSource", "AppleJPEG", "resample",           # image decode
    "appendingPathComponent", "_SwiftURL",                        # URL building
]


def export_time_profile(trace: str) -> str:
    """Return the time-profile table XML, trying the schema then table index."""
    def run(xpath: str) -> str:
        return subprocess.run(
            ["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
            capture_output=True, text=True).stdout

    for run_no in ("1", "2"):
        xml = run(f'/trace-toc/run[@number="{run_no}"]/data/table[@schema="time-profile"]')
        if "<row>" in xml:
            return xml
    # Fallback: some traces expose it only positionally.
    for run_no in ("1", "2"):
        for i in range(1, 60):
            xml = run(f'/trace-toc/run[@number="{run_no}"]/data/table[{i}]')
            if 'schema name="time-profile"' in xml and "<row>" in xml:
                return xml
    return ""


def main() -> None:
    trace, label = sys.argv[1], sys.argv[2]
    xml = export_time_profile(trace)
    if "<row>" not in xml:
        print(f"[{label}] no time-profile samples found in {trace}", file=sys.stderr)
        print("  (was 'Time Profiler' recorded? did the interaction run?)", file=sys.stderr)
        sys.exit(1)

    # id -> symbol name (defined anywhere in the doc)
    frame_names = dict(re.findall(r'<frame id="(\d+)" name="([^"]*)"', xml))
    # backtrace id -> ordered list of frame names (resolving nested frame refs)
    backtrace = {}
    for m in re.finditer(r'<backtrace id="(\d+)">(.*?)</backtrace>', xml, re.S):
        names = []
        for fm in re.finditer(r'<frame (?:id="(\d+)"[^>]*name="([^"]*)"|ref="(\d+)")', m.group(2)):
            names.append(fm.group(2) if fm.group(2) is not None else frame_names.get(fm.group(3), "?"))
        backtrace[m.group(1)] = names
    thread_fmt = dict(re.findall(r'<thread id="(\d+)" fmt="([^"]*)"', xml))

    rows = re.findall(r"<row>(.*?)</row>", xml, re.S)

    def thread_of(row: str) -> str:
        m = re.search(r'<thread (?:id="(\d+)"|ref="(\d+)")', row)
        return thread_fmt.get(m.group(1) or m.group(2), "?") if m else "?"

    def frames_of(row: str):
        m = re.search(r'<backtrace (?:id="(\d+)"|ref="(\d+)")', row)
        return backtrace.get(m.group(1) or m.group(2), []) if m else []

    MS_PER_SAMPLE = 0.1  # 100 µs default Time Profiler interval
    main_ms = 0.0
    by_subsystem = Counter()
    own = Counter()  # your own hottest symbols (heuristic: not system frames)
    for row in rows:
        if "Main Thread" not in thread_of(row):
            continue
        main_ms += MS_PER_SAMPLE
        frames = frames_of(row)
        joined = " ".join(frames)
        for s in SUBSYSTEMS:
            if s in joined:
                by_subsystem[s] += 1
        # Attribute to the deepest frame that looks like app code (contains a
        # dotted Swift symbol and isn't an obvious stdlib/runtime frame).
        for f in frames:
            if ("." in f and "(" in f
                    and not f.startswith(("swift_", "objc_", "specialized "))
                    and "AG::" not in f and "CA::" not in f):
                own[f] += 1
                break

    print(f"[{label}] main-thread on-CPU = {main_ms:.0f} ms  ({len(rows)} total samples)")
    print("  by subsystem (ms of main-thread time whose stack touches it):")
    for name, count in by_subsystem.most_common():
        print(f"    {count * MS_PER_SAMPLE:8.1f} ms  {name}")
    print("  hottest app-code frames:")
    for name, count in own.most_common(12):
        print(f"    {count * MS_PER_SAMPLE:8.1f} ms  {name}")


if __name__ == "__main__":
    main()
