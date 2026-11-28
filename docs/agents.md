# Using labelkit from an AI agent

labelkit can be driven end to end from the terminal, so a coding agent (Claude
Code, Codex, opencode, Cursor, Gemini CLI, GitHub Copilot, Amp, Goose, Aider,
…) can label a dataset, check its own work, and hand the result to you for
review in the editor.

There is nothing to run in the background and no server to configure. The
agent calls the same `labelkit` binary you do; labelkit ships the instructions
that teach it how.

## Set up in one minute

```bash
brew install shellbear/tap/labelkit   # if you haven't already
labelkit skill --install              # teach your agents how to use it
```

Then ask your agent, in a project that has a folder of images:

> Label the photos in `./cards` for object detection: one box per playing
> card, label `card`. Show me the ones you're unsure about.

`labelkit skill --install` writes a small instruction file (an
[Agent Skill](https://agentskills.io)) to the two places agent clients look for
them, `~/.agents/skills/labelkit/` and `~/.claude/skills/labelkit/`. The agent
loads it only when a task calls for it. Run the command again after upgrading
labelkit: the guide is built into the binary, so it always describes the
version you have.

## Per-client setup

Locations are the ones each client documented in November 2026. If yours
differs, `labelkit skill --install --dir <skills directory>` puts the skill
anywhere.

| Client | Picks the skill up from | Set up with |
|---|---|---|
| **Claude Code** | `~/.claude/skills`, `.claude/skills` | `labelkit skill --install` |
| **Codex CLI** | `~/.agents/skills`, `.agents/skills` | `labelkit skill --install` |
| **opencode** | `~/.agents/skills`, `~/.claude/skills`, `~/.config/opencode/skills` | `labelkit skill --install` |
| **Cursor** | `~/.agents/skills`, `.agents/skills`, `~/.cursor/skills` | `labelkit skill --install` |
| **Gemini CLI** | `~/.agents/skills`, `~/.gemini/skills` | `labelkit skill --install` |
| **Antigravity CLI** | `.agents/skills` in the project, `~/.gemini/skills` | `labelkit skill --install --project`, or `--dir ~/.gemini/skills` |
| **GitHub Copilot** (CLI, coding agent) | `~/.agents/skills`, `.agents/skills`, `.github/skills` | `labelkit skill --install` |
| **Amp** | `~/.agents/skills`, `.agents/skills`, `~/.claude/skills` | `labelkit skill --install` |
| **Goose** | `~/.agents/skills`, `.agents/skills` | `labelkit skill --install` |
| **Aider**, and any agent without skills | whatever you tell it to read | `labelkit skill --snippet >> AGENTS.md` (Aider: add `read: AGENTS.md` to `.aider.conf.yml`) |

Other ways to get the same file:

- **For one project, shared with your team:** `labelkit skill --install --project`
  writes `.agents/skills/labelkit/` and `.claude/skills/labelkit/` in the
  current directory. Commit them.
- **From the repository, without labelkit installed yet:**
  `npx skills add shellbear/labelkit` (the skill lives at
  [`skills/labelkit/SKILL.md`](../skills/labelkit/SKILL.md)).
- **As a Claude Code plugin:**
  `/plugin install labelkit --marketplace shellbear/labelkit`.
- **Just a few lines in `AGENTS.md`:** `labelkit skill --snippet` prints a short
  section naming the commands. Any agent that can run a shell command can work
  from that, and `labelkit <command> --help` covers the rest.

### Why there is no MCP server

Every client above can already run shell commands, so a plain CLI with JSON
output works in all of them with nothing to install, start, or keep in sync. An
MCP server would add a second interface to maintain without reaching a single
extra client.

## What the agent does

The skill teaches this loop. You can run it by hand too; every step is one
command.

```bash
# 1. Where do things stand?
labelkit stats ./cards
#    → images, boxes per label, and "unlabeled": the images still to do

# 2. Look at what needs labelling, with a pixel ruler drawn on
labelkit render ./cards --unlabeled --grid 100 --limit 10 --out /tmp/todo

# 3. Write boxes
labelkit annotate ./cards --image IMG_0412.jpg \
  --box 'card:412,230,318,455' --box 'card:790,244,310,450'

# 4. Draw the saved boxes and look again
labelkit render ./cards IMG_0412.jpg --out /tmp/check

# 5. Anything wrong with the dataset as a whole?
labelkit validate ./cards
```

Two details make this dependable for a model working from pictures:

- **The grid is in the original image's pixels.** A vision model is shown a
  downscaled copy, so a position it estimates is a position in that copy.
  `render --grid` labels its lines in real pixels, so numbers read off the
  picture are already right.
- **Every step can be repeated.** Running the same `annotate` twice changes
  nothing: boxes that are already there are skipped and the file's bytes stay
  identical. An agent that retries after an interruption does no harm.

## Reviewing the agent's work

There are two reviewers, and each has its own tool:

- **The agent checks itself with `render`.** It draws the saved boxes, numbered
  `#1`, `#2`, …, onto downscaled JPEGs it can open. That is the quick inner
  loop: 40 twelve-megapixel photos render in under half a second.
- **You check in the editor.** `labelkit ./cards --select IMG_0412.jpg` opens
  the editor on that image. If the editor is already open on the dataset it
  reloads from disk and jumps there, so an agent can run this to say "look at
  this one". Fix a box by dragging it and press ⌘S.

One caution: the editor does not notice changes made to `annotations.json`
while it is open. If an agent labels a dataset you have open, re-run
`labelkit <dataset>` to reload before you edit, or your next save will write the
older state back. (It asks before discarding unsaved edits of your own.)

## Giving boxes to `annotate`

By default a box is `x, y, width, height` in **pixels of the image file, with
`x`,`y` at the top-left corner**:

```json
{"image": "a.jpg", "boxes": [
  {"label": "cat", "x": 40, "y": 30, "width": 200, "height": 160}
]}
```

Input can be one such object, a JSON array of them, or NDJSON, from a file
(`--from boxes.json`) or stdin (`--from -`). With `--image a.jpg` the input is
just that image's boxes. A Markdown code fence around the JSON is ignored, so a
model's raw answer can be piped straight in.

You rarely need to convert anything. Shapes that describe themselves are read
as they are, and for the rest you name the convention with a flag:

| What you have | How to pass it |
|---|---|
| **Gemini** — `[{"box_2d": [ymin, xmin, ymax, xmax], "label": …}]`, 0–1000 | `--image a.jpg --from answer.json` |
| **Claude, GPT** — ask for `{"label": …, "xyxy": [x1, y1, x2, y2]}` in pixels | `--image a.jpg --from answer.json`, plus `--image-size WxH` if the model saw a resized copy (or have it read the `render --grid` picture instead) |
| **Qwen3-VL** — `bbox_2d`, 0–1000 | `--units 0-1000` |
| **Qwen2.5-VL** — `bbox_2d`, pixels of the resized input | `--image-size WxH` |
| **Grounding DINO, OWL-ViT, Florence-2** — `boxes` and `labels` lists, corners in pixels | `--order xyxy` |
| **Moondream** — `objects` with `x_min … y_max`, 0–1, no label | `--units normalized -l cat` |
| **`labelkit detect`** output | `labelkit detect … --format ndjson \| labelkit annotate <dataset> --from -` |
| **COCO** JSON | `--from instances.json` |
| **Create ML** annotations (to merge two datasets) | `--from other/annotations.json` |
| **YOLO** rows — `class cx cy w h`, normalized | as JSON boxes, with `--units normalized --anchor center` |
| **Label Studio** — percent units | `--units percent` |
| **Apple Vision** — normalized, origin bottom-left | `--units normalized --origin bottom-left` |
| Pascal VOC, CVAT, others | convert to COCO first (`supervision`, `datumaro` and FiftyOne all can) |

The flags follow the three terms Create ML itself uses for annotations
(`--units`, `--origin`, `--anchor`), plus `--order` for four bare numbers
(`xywh`, `xyxy`, `yxyx`) and `--image-size` for coordinates measured on a
resized copy. Nothing is guessed from the values: a box that ends up outside
its image is reported, not moved.

## The contract

These hold for `stats`, `validate`, `annotate`, `render` and `skill`, and are
treated as a public interface.

- **stdout is the result, and only the result.** JSON by default
  (`--format text` for people). Notes and progress go to stderr.
- **Exit codes:** `0` success · `1` the command ran and found or hit a problem
  (the JSON says what) · `64` usage error.
- **Reports are versioned.** Each carries `schemaVersion`; fields may be added,
  but an existing field changing meaning bumps the version.
- **Writes are all-or-nothing.** If any input can't be applied — an image that
  isn't in the dataset, a box outside its image — `annotate` writes nothing and
  exits `1`. `--lenient` applies the valid part. `--dry-run` writes nothing
  either way.
- **The file stays yours.** `annotate` writes through the same code as the
  editor: entry order, unknown keys, negative examples and the file's own
  indentation are preserved, and coordinates are saved to 2 decimals. `git diff`
  shows the boxes that changed and nothing else.
- **Headless.** None of these commands opens a window or touches the GUI.

### `annotate` report

```json
{
  "schemaVersion": 1,
  "mode": "add",
  "dryRun": false,
  "written": true,
  "totals": { "images": 1, "added": 2, "duplicates": 0, "removed": 0, "clamped": 0 },
  "images": [
    { "image": "IMG_0412.jpg", "added": 2, "duplicates": 0, "removed": 0,
      "clamped": 0, "total": 2, "created": true }
  ],
  "problems": []
}
```

`duplicates` are boxes skipped because an equivalent one was already there.
`clamped` are boxes trimmed to the image edge. `problems` lists input that was
refused, each with its `image` and a `message`.

### `validate` issues

```json
{ "severity": "error", "code": "box-outside-image", "image": "IMG_0412.jpg",
  "box": 3, "label": "card", "message": "box lies outside the 4032x3024 image (…)" }
```

| Code | Severity | Meaning |
|---|---|---|
| `no-annotations-file` | error | the dataset has no annotations file |
| `missing-image` | error | an entry's image file isn't in the folder |
| `duplicate-entry` | error | one image has two entries (only the first is used) |
| `empty-label` | error | a box has no label |
| `empty-box` | error | a box has zero or negative width or height |
| `box-outside-image` | error | a box lies entirely outside its image |
| `unknown-label` | error | a label isn't in `--labels a,b,c` |
| `box-overflows-image` | warning | a box extends past an image edge |
| `duplicate-box` | warning | two near-identical boxes with the same label |
| `duplicate-image` | warning | the same photo under two names (and whether they are labelled differently) |
| `unreadable-image` | warning | the image's size couldn't be read |
| `unused-label` | warning | a label from `--labels` has no boxes |

Warnings exit `0` unless `--strict` is given. `box` is the box's position in
the image's annotations, starting at 1, and matches the `#n` that `render`
draws.

## Speed

The scripted commands are meant to be called in a loop, so they are kept
cheap. Measured on a 10,000-image dataset with 26,000 boxes (Apple silicon):

| Command | Time | Peak memory |
|---|---|---|
| `labelkit stats` | 0.2 s | 44 MB |
| `labelkit annotate` (one image) | 0.1 s | 35 MB |
| `labelkit validate` | 0.5 s | 70 MB |

On a dataset of a few hundred images each is a few hundredths of a second.
Images are only ever opened to read their dimensions (`annotate`, `validate`)
or to draw them (`render`), and that work is spread across cores.

## For other tools and scripts

Nothing here is specific to AI agents. The same commands work in a Makefile, a
CI job or a notebook:

```bash
labelkit validate ./cards --labels card --strict   # fail the build on a bad dataset
labelkit stats ./cards | jq '.images.unlabeled'     # how much is left
```
