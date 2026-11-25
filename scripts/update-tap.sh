#!/bin/sh
# Point the Homebrew formula (shellbear/tap/labelkit) at a published release.
#
#   ./scripts/update-tap.sh            # version from Sources/LabelKit/Version.swift
#   ./scripts/update-tap.sh 0.3.0      # explicit version
#   ./scripts/update-tap.sh --dry-run  # show the formula diff, change nothing
#
# Reads the release's checksums.txt (so the GitHub release must already exist),
# rewrites the formula's version, URLs and per-arch sha256, then commits and
# pushes the tap. Uses your own git/gh credentials; nothing runs in CI.
#
# The tap checkout defaults to Homebrew's own clone; override with TAP_DIR.
set -eu

cd "$(dirname "$0")/.."

dry_run=0
version=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -*) echo "usage: update-tap.sh [--dry-run] [X.Y.Z]" >&2; exit 64 ;;
    *) version="$arg" ;;
  esac
done
[ -n "$version" ] || version="$(grep -o '"[0-9.]*"' Sources/LabelKit/Version.swift | tr -d '"')"
tag="v$version"

tap_dir="${TAP_DIR:-$(brew --repository shellbear/tap 2>/dev/null || true)}"
formula="$tap_dir/Formula/labelkit.rb"
if [ ! -f "$formula" ]; then
  echo "error: no formula at $formula (run 'brew tap shellbear/tap' or set TAP_DIR)" >&2
  exit 1
fi

checksums="$(gh release download "$tag" --repo shellbear/labelkit --pattern checksums.txt --output -)" || {
  echo "error: release $tag has no checksums.txt yet (has the Release workflow finished?)" >&2
  exit 1
}
sha_for() {
  printf '%s\n' "$checksums" | awk -v f="labelkit-$tag-$1.tar.gz" '$2 == f { print $1 }'
}
arm_sha="$(sha_for arm64)"
intel_sha="$(sha_for x86_64)"
if [ -z "$arm_sha" ] || [ -z "$intel_sha" ]; then
  echo "error: checksums.txt for $tag is missing the arm64 or x86_64 archive" >&2
  exit 1
fi

if [ -n "$(git -C "$tap_dir" status --porcelain)" ]; then
  echo "error: $tap_dir has uncommitted changes" >&2
  exit 1
fi
git -C "$tap_dir" pull --quiet --ff-only

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
awk -v version="$version" -v arm="$arm_sha" -v intel="$intel_sha" '
  /^[[:space:]]*on_arm do/   { arch = "arm" }
  /^[[:space:]]*on_intel do/ { arch = "intel" }
  /^[[:space:]]*end/         { arch = "" }
  /^[[:space:]]*version "/   { sub(/"[^"]*"/, "\"" version "\"") }
  /^[[:space:]]*url "/ {
    gsub(/download\/v[0-9.]+\/labelkit-v[0-9.]+-/, "download/v" version "/labelkit-v" version "-")
  }
  /^[[:space:]]*sha256 "/ && arch == "arm"   { sub(/"[^"]*"/, "\"" arm "\"") }
  /^[[:space:]]*sha256 "/ && arch == "intel" { sub(/"[^"]*"/, "\"" intel "\"") }
  { print }
' "$formula" > "$tmp"

if cmp -s "$tmp" "$formula"; then
  echo "tap already serves labelkit $version"
  exit 0
fi

if [ "$dry_run" -eq 1 ]; then
  diff -u "$formula" "$tmp" || true
  echo "(dry run: formula not changed)"
  exit 0
fi

cat "$tmp" > "$formula"
git -C "$tap_dir" commit --quiet -m "labelkit $version" Formula/labelkit.rb
git -C "$tap_dir" push --quiet
echo "tap updated: brew upgrade labelkit now installs $version"
