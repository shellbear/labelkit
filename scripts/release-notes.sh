#!/bin/sh
# Print the CHANGELOG.md section for one version, without its heading.
#
#   ./scripts/release-notes.sh 0.2.0
#
# Used by .github/workflows/release.yml as the GitHub release body. Exits
# non-zero when the version has no section (or an empty one), so a tag pushed
# without a changelog entry fails the release instead of publishing blank notes.
set -eu

version="${1:?usage: release-notes.sh X.Y.Z}"
changelog="$(dirname "$0")/../CHANGELOG.md"

notes="$(awk -v heading="## [$version]" '
  index($0, heading) == 1 { found = 1; next }
  found && /^## \[/       { exit }
  found && /^\[[^]]*\]: / { exit }
  found                   { print }
' "$changelog")"

# Trim surrounding blank lines; fail if nothing is left.
notes="$(printf '%s\n' "$notes" | sed -e '/./,$!d')"
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  echo "error: CHANGELOG.md has no notes for version $version" >&2
  exit 1
fi
printf '%s\n' "$notes"
