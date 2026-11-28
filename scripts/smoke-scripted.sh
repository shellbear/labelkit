#!/usr/bin/env bash
# End-to-end smoke test of the scripted subcommands (stats, validate, annotate,
# render, skill) against a built binary, on a throwaway dataset. It checks the
# things unit tests can't: that the commands are wired into the CLI, stay
# headless, and keep their exit-code contract (0 ok, 1 problem, 64 usage).
#
#   ./scripts/smoke-scripted.sh                       # uses .build/release/labelkit
#   ./scripts/smoke-scripted.sh path/to/labelkit
set -euo pipefail
cd "$(dirname "$0")/.."

lk="${1:-.build/release/labelkit}"
[[ "$lk" = /* ]] || lk="$PWD/$lk"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ds="$work/dataset"
mkdir "$ds"
cp docs/icon.png "$ds/a.png"          # any real image will do: 512x512
cp docs/icon.png "$ds/b.png"
printf 'x' >> "$ds/b.png"             # same picture, different bytes: not a duplicate file

fail() { echo "smoke: $*" >&2; exit 1; }
# expect <code> <command…>: run it, discard output, require that exit code.
expect() {
    local want="$1" got=0
    shift
    "$@" >/dev/null 2>&1 || got=$?
    [[ "$got" -eq "$want" ]] || fail "expected exit $want, got $got: $*"
}

for command in stats validate annotate render import export skill; do
    expect 0 "$lk" "$command" --help
done

# A folder with no annotations yet: stats works, validate says so with exit 1.
expect 0 "$lk" stats "$ds"
expect 1 "$lk" validate "$ds"

# Write a box, then the same box again: the file must not change by a byte.
expect 0 "$lk" annotate "$ds" --image a.png --box 'thing:10,20,100,80'
cp "$ds/annotations.json" "$work/first.json"
expect 0 "$lk" annotate "$ds" --image a.png --box 'thing:10,20,100,80'
cmp -s "$ds/annotations.json" "$work/first.json" || fail "a repeated annotate changed the file"
grep -q '"x": 60' "$ds/annotations.json" || fail "expected a centre-anchored x of 60 on disk"

# Piped model-style input, in another convention, for the second image.
echo '[{"box_2d": [100, 200, 500, 400], "label": "thing"}]' \
    | "$lk" annotate "$ds" --image b.png --from - >/dev/null
expect 0 "$lk" validate "$ds" --labels thing --strict

# Bad input is refused whole: exit 1 and the file untouched.
cp "$ds/annotations.json" "$work/before-bad.json"
expect 1 "$lk" annotate "$ds" --image missing.png --box 'thing:1,1,5,5'
expect 1 "$lk" annotate "$ds" --image a.png --box 'thing:9000,9000,5,5'
cmp -s "$ds/annotations.json" "$work/before-bad.json" || fail "a refused annotate changed the file"

# stdin belongs to the caller: without --from it is left alone, so a loop
# feeding image names is not swallowed by the first command.
count=0
while read -r name; do
    expect 0 "$lk" annotate "$ds" --image "$name" --negatives --dry-run
    count=$((count + 1))
done < <(printf 'a.png\nb.png\n')
[[ "$count" -eq 2 ]] || fail "annotate consumed the loop's stdin (ran $count of 2)"

# "No boxes" is a no-op unless --negatives says otherwise, even with replace.
echo '{"image": "a.png", "boxes": []}' | "$lk" annotate "$ds" --from - --mode replace >/dev/null
cmp -s "$ds/annotations.json" "$work/before-bad.json" || fail "an empty box list wiped an image without --negatives"

# A name is only accepted spelled as it is on disk, and only for images.
expect 1 "$lk" annotate "$ds" --image A.PNG --box 'thing:1,1,5,5'
expect 1 "$lk" annotate "$ds" --image annotations.json --box 'thing:1,1,5,5'
expect 1 "$lk" annotate "$ds" --image a.png --box 'thing:10,10,-50,-40'
cmp -s "$ds/annotations.json" "$work/before-bad.json" || fail "a refused annotate changed the file"

# Rendering into the dataset folder would overwrite the images: refused.
cp "$ds/a.png" "$work/a-original.png"
expect 64 "$lk" render "$ds" --out "$ds"
expect 64 "$lk" render "$ds" --out "$ds/../dataset/"
cmp -s "$ds/a.png" "$work/a-original.png" || fail "render touched a source image"

# An annotations file that isn't Create ML JSON is a dataset problem (1), not a
# usage error, and validate still reports it as JSON.
broken="$work/broken"
mkdir "$broken"
cp docs/icon.png "$broken/a.png"
echo '{"not": "an array"}' > "$broken/annotations.json"
expect 1 "$lk" stats "$broken"
expect 1 "$lk" validate "$broken"
report="$("$lk" validate "$broken" 2>/dev/null || true)"
grep -q '"invalid-annotations-file"' <<<"$report" \
    || fail "validate should report an unreadable annotations file as an issue"
expect 1 "$lk" annotate "$ds" --from "$broken/annotations.json"

# Piping boxes in without --from - would silently do nothing; it is refused.
expect 64 "$lk" annotate "$ds" --image a.png

# Usage errors are 64, before anything is read.
expect 64 "$lk" annotate "$ds" --box 'thing:1,1,5,5'
expect 64 "$lk" annotate "$ds" --image a.png --origin bottom-left --box 'thing:1,1,5,5'
expect 64 "$lk" stats "$work/no-such-dataset"

# Reports are JSON with the documented fields.
"$lk" stats "$ds" | grep -q '"annotated" : 2' || fail "stats should count 2 annotated images"
"$lk" validate "$ds" | grep -q '"ok" : true' || fail "validate should report ok"

# Render writes one picture per image.
expect 0 "$lk" render "$ds" --grid 100 --out "$work/out"
[[ -s "$work/out/a.jpg" && -s "$work/out/b.jpg" ]] || fail "render didn't write both pictures"

# Export to each format and import it back: same images, same boxes, and a
# second import that changes nothing.
for format in yolo coco huggingface; do
    expect 0 "$lk" export "$ds" --format "$format" --out "$work/out-$format"
    expect 0 "$lk" import "$work/out-$format" --into "$work/back-$format"
    cp "$work/back-$format/annotations.json" "$work/back-$format.json"
    expect 0 "$lk" import "$work/out-$format" --into "$work/back-$format"
    cmp -s "$work/back-$format/annotations.json" "$work/back-$format.json" \
        || fail "a repeated $format import changed the file"
    "$lk" stats "$work/back-$format" | grep -q '"annotated" : 2' || fail "$format round trip lost images"
    expect 0 "$lk" validate "$work/back-$format" --labels thing --strict
done
expect 64 "$lk" export "$ds" --format yolo --out "$work/out-yolo"     # not empty
expect 64 "$lk" export "$ds" --format yolo --out "$ds"                 # the dataset itself
expect 64 "$lk" import "$work/no-such-source" --into "$work/x"
[[ ! -e "$work/x" ]] || fail "a refused import created its target"

# The skill prints, matches the committed copy, and installs.
"$lk" skill | cmp -s - skills/labelkit/SKILL.md || fail "labelkit skill differs from skills/labelkit/SKILL.md"
expect 0 "$lk" skill --install --dir "$work/skills"
[[ -s "$work/skills/labelkit/SKILL.md" ]] || fail "skill --install didn't write SKILL.md"
"$lk" skill --snippet | grep -q 'labelkit stats' || fail "skill --snippet is missing its commands"

echo "smoke: scripted subcommands ok"
