#!/bin/sh
# Cut a release from this machine: tag, push, wait for CI to publish the GitHub
# release, then point the Homebrew tap at it.
#
#   ./scripts/release.sh           # release the version in Version.swift
#   ./scripts/release.sh --check   # run the preflight checks only
#
# Before running: bump Sources/LabelKit/Version.swift, give CHANGELOG.md a
# "## [X.Y.Z] - YYYY-MM-DD" section, and commit both on main.
set -eu

cd "$(dirname "$0")/.."

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

version="$(grep -o '"[0-9.]*"' Sources/LabelKit/Version.swift | tr -d '"')"
tag="v$version"
fail() { echo "error: $*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "working tree has uncommitted changes"
./scripts/release-notes.sh "$version" > /dev/null || fail "add a CHANGELOG.md section for $version first"
git fetch --quiet origin main --tags
git rev-parse -q --verify "refs/tags/$tag" > /dev/null && fail "tag $tag already exists (bump Version.swift?)"
[ -z "$(git rev-list HEAD..origin/main)" ] || fail "origin/main has commits you don't have; pull first"

echo "preflight ok: ready to release $tag"
[ "$check_only" -eq 1 ] && exit 0

# --- tag and push ------------------------------------------------------------
git tag -a "$tag" -m "labelkit $version"
git push --quiet origin main "$tag"
echo "pushed $tag; waiting for the Release workflow"

# --- wait for the GitHub release ---------------------------------------------
run_id=""
for _ in $(seq 1 30); do
  run_id="$(gh run list --workflow release.yml --branch "$tag" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [ -n "$run_id" ] && break
  sleep 4
done
[ -n "$run_id" ] || fail "the Release workflow never started for $tag"
gh run watch "$run_id" --exit-status > /dev/null || fail "Release workflow failed: gh run view $run_id --log-failed"
echo "GitHub release published: $(gh release view "$tag" --json url --jq .url)"

# --- Homebrew ----------------------------------------------------------------
./scripts/update-tap.sh "$version"
