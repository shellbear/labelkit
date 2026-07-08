#!/bin/bash
# capture.sh <label> <process-name> [seconds]
#
# Records an Instruments Time Profiler trace of an ALREADY-RUNNING macOS app
# while driving the slow interaction, then analyzes it. Headless — no GUI.
#
#   scripts/capture.sh before MyApp 8
#   scripts/capture.sh after  MyApp 8
#
# Then eyeball the printed subsystem breakdown, or diff before vs after.
#
# Prerequisites: the app is already launched (release build) on a realistic
# dataset, and its process name matches <process-name> (see `pgrep -fl`).
set -euo pipefail

# ---------------------------------------------------------------------------
# Customize this to trigger YOUR slow interaction during the recording.
#
# Why menu clicks: synthesized key events (`key code`) and screenshots often
# DO NOT land in a headless/automation session, but clicking a menu-bar item
# via System Events reliably does. So expose the slow action as a menu command
# (e.g. View > Next Image, Edit > Find Next) and click it in a loop. If there
# is no such command, add a temporary one, or have the user drive it manually
# while this records.
#
# The menu-bar title System Events sees is the *process* name, which may differ
# from the bundle name — check with `pgrep -fl`.
drive_interaction() {
  local proc="$1"
  osascript \
    -e "tell application \"$proc\" to activate" \
    -e "tell application \"System Events\" to tell process \"$proc\"" \
    -e "repeat 55 times" \
    -e "click menu item \"Next Image\" of menu \"View\" of menu bar item \"View\" of menu bar 1" \
    -e "delay 0.08" \
    -e "end repeat" \
    -e "end tell" >/dev/null 2>&1 || \
    echo "  (drive_interaction failed — edit capture.sh to match the app's menu)" >&2
}

# ---------------------------------------------------------------------------
LABEL="${1:?usage: capture.sh <label> <process-name> [seconds]}"
PROC="${2:?usage: capture.sh <label> <process-name> [seconds]}"
SECONDS_LIMIT="${3:-8}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUTDIR:-$PWD}/$LABEL.trace"

PID="$(pgrep -f "$PROC" | head -1 || true)"
if [ -z "$PID" ]; then
  echo "no running process matching '$PROC' — launch the release app first" >&2
  exit 1
fi
echo "attaching to pid=$PID, recording ${SECONDS_LIMIT}s -> $LABEL.trace"
rm -rf "$OUT"

# Time Profiler is the workhorse (main-thread call tree). Use --instrument,
# NOT --template: templates can fail to export on Xcode 26+.
xcrun xctrace record --instrument 'Time Profiler' --attach "$PID" \
  --time-limit "${SECONDS_LIMIT}s" --output "$OUT" >/dev/null 2>&1 &
REC=$!
sleep 1.2   # let the recorder spin up before we start driving

drive_interaction "$PROC"

wait "$REC" 2>/dev/null || true
sleep 1
python3 "$HERE/analyze.py" "$OUT" "$LABEL"
