import Foundation

/// The instructions labelkit hands to AI agents: an Agent Skill (`SKILL.md`)
/// and a short snippet for a project's `AGENTS.md`.
///
/// They are compiled into the binary on purpose. `labelkit skill` then always
/// describes the commands of the version that is actually installed, and an
/// agent can get the guide with nothing but the CLI on its PATH. The repo's
/// `skills/labelkit/SKILL.md` is the same text, kept identical by a test, so
/// installers that read a repository (`npx skills add`, plugin marketplaces)
/// serve the same thing.
public enum AgentGuide {
    public static let skillName = "labelkit"

    /// Where agent clients look for user-level skills, relative to the home
    /// directory. `.agents/skills` is the cross-client convention (Codex,
    /// Cursor, opencode, Gemini CLI, Copilot, Amp, Goose, …); Claude Code reads
    /// only its own directory, so both are written.
    public static let userSkillDirectories = [".agents/skills", ".claude/skills"]

    /// Write `SKILL.md` into `<skillsDirectory>/labelkit/`, creating
    /// directories as needed, and return the file's URL. Overwrites a previous
    /// install, so re-running after an upgrade refreshes the guide.
    @discardableResult
    public static func install(into skillsDirectory: URL) throws -> URL {
        let folder = skillsDirectory.appendingPathComponent(skillName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try Data(skill.utf8).write(to: file, options: .atomic)
        return file
    }

    /// A few lines for a project's `AGENTS.md` (or `CLAUDE.md`, `GEMINI.md`, …):
    /// enough for any agent that can run shell commands, including ones with no
    /// skills support.
    public static let agentsSnippet = #"""
    ## Labelling images (labelkit)

    Object-detection datasets here are Apple Create ML folders (images plus one
    `annotations.json`) and are edited with the `labelkit` CLI. Do not edit
    `annotations.json` by hand.

    - `labelkit stats <dataset>` — what is labelled and what is not (JSON).
    - `labelkit render <dataset> --unlabeled --grid 100 --out <dir>` — pictures to label from, with a pixel ruler.
    - `labelkit annotate <dataset> --image <name> --box 'label:x,y,width,height'` — add boxes (x,y = top-left corner, in pixels of the image file).
    - `labelkit render <dataset> --out <dir>` — draw the saved boxes to check them.
    - `labelkit validate <dataset>` — exits 1 if the dataset has errors.

    Run `labelkit skill` for the full guide and `labelkit <command> --help` for every option.

    """#

    /// The Agent Skill. Frontmatter sticks to the fields of the open Agent
    /// Skills specification (`name`, `description`) so every client accepts it.
    public static let skill = #"""
    ---
    name: labelkit
    description: Label images for object detection with the labelkit CLI on macOS. Adds, checks and fixes bounding boxes in Apple Create ML datasets (a folder of images with an annotations.json), runs Core ML or Vision detectors, and trains a Core ML object detector. Use when asked to annotate or label images, draw or correct bounding boxes, review or validate an object-detection dataset, or train a Create ML model.
    ---

    # labelkit

    labelkit edits Apple Create ML object-detection datasets: a folder of images
    plus one `annotations.json`. Drive it through its subcommands. They write the
    file through the same code as the editor, so entry order, unknown keys,
    negative examples and formatting all survive, and `git diff` shows only real
    changes.

    ## Ground rules

    - **Never edit `annotations.json` by hand.** Use `labelkit annotate`.
    - **`labelkit <dataset>` with no subcommand opens the GUI editor.** Run it
      only when the user wants to look at or fix labels themselves. Everything
      below is headless.
    - **stdout is the result (JSON), stderr is notes.** Parse stdout.
    - **Exit codes:** `0` ok · `1` the command ran and found or hit a problem
      (stdout says what, or stderr if there is no report) · `64` you called it
      wrong (read stderr, fix the call).
    - **Coordinates are pixels of the image file, top-left origin, with `x`,`y`
      at the box's top-left corner**, unless you state another convention with
      flags. (On disk Create ML stores box centres; labelkit converts.)
    - A dataset is addressed by its folder: `labelkit stats ./cards`.

    ## The loop

    1. **See where things stand.**
       `labelkit stats <dataset>` → counts, per-label totals, and `unlabeled`
       (images with no entry yet, the work to do).
    2. **Look at the images to label.**
       `labelkit render <dataset> --unlabeled --grid 100 --limit 10 --out <dir>`
       writes downscaled copies with a labelled line every 100 pixels of the
       *original* image. Open them. The JSON gives each image's real `width`
       and `height`. `--out` is a scratch directory, never the dataset folder
       (labelkit refuses that).
    3. **Write boxes.**
       `labelkit annotate <dataset> --image a.jpg --box 'cat:40,30,200,160' --box 'dog:300,90,120,210'`
       or many images at once with `--from boxes.json` (shapes below).
    4. **Check your work by eye.**
       `labelkit render <dataset> a.jpg --out <dir>` draws the saved boxes,
       numbered `#1`, `#2`, … Open the picture. If a box is off, fix it with
       `--mode replace` (step 3 again for that image) and re-render. Expect two
       or three passes on hard images.
    5. **Check the dataset.**
       `labelkit validate <dataset>` → exit `1` and a list of issues if anything
       would break training. Fix and repeat.

    Before labelling a batch, agree the policy with the user and apply it the
    same way everywhere, because inconsistent boxes hurt a detector more than
    slightly loose ones:

    - **Extent:** the whole object, or only part of it (a card including its
      border, or just the artwork)?
    - **Cut-off and hidden objects:** box what is visible, or skip them?
    - **Label names:** exact spelling. `validate --labels a,b,c` enforces the set.

    ## Getting coordinates right

    You are usually shown a downscaled copy of an image, so pixel positions you
    estimate are positions in *that copy*, not in the file. Three safe ways to
    give boxes, best first:

    1. **Read them off the grid.** `render --grid N` labels its lines in
       original-image pixels, so numbers read from the picture are already
       correct. This is the most accurate method.
    2. **Use relative units.** `--units normalized` (0–1) or `--units 0-1000`
       are independent of image size.
    3. **Say what size you looked at.** `--image-size 1568x1176`, or `"width"`
       and `"height"` on a JSON entry, and labelkit rescales to the real image.

    Never guess a scale. A box that lies outside its image is rejected, not
    silently moved.

    ## Giving boxes to `annotate`

    Inline, for one image:

    ```
    labelkit annotate <dataset> --image a.jpg --box 'cat:40,30,200,160'
    labelkit annotate <dataset> --image a.jpg -l card --box 40,30,200,160 --box 300,90,120,210
    ```

    From a file or stdin, for any number of images. stdin is read only with
    `--from -`. JSON, a JSON array, or NDJSON; a Markdown code fence around it
    is fine:

    ```json
    {"image": "a.jpg", "boxes": [
      {"label": "cat", "x": 40, "y": 30, "width": 200, "height": 160}
    ]}
    ```

    With `--image a.jpg --from answer.json` the file is just that image's boxes
    (a list of them, or a single box object), so a vision model's raw answer can
    be passed straight through.

    Shapes that describe themselves need no flags:

    | Box written as | Meaning |
    |---|---|
    | `"x","y","width","height"` (or under `"box"`) | the convention set by flags; by default top-left corner, pixels |
    | `"normalized": {x,y,width,height}` | the same, as fractions 0–1 |
    | `"xyxy": [x1,y1,x2,y2]`, or `x1/y1/x2/y2`, `xmin/ymin/xmax/ymax` keys | two corners |
    | `"box_2d": [y1,x1,y2,x2]` | Gemini: y first, 0–1000 |
    | `"bbox_2d": [x1,y1,x2,y2]` | Qwen: add `--units 0-1000` for Qwen3-VL |
    | `"coordinates": {x,y,width,height}` | Create ML: centre-anchored pixels |
    | a COCO file (`images`/`annotations`/`categories`) | read whole |
    | `labelkit detect` output | read as is |

    For anything else, name the convention instead of converting numbers:

    | Flag | Use for |
    |---|---|
    | `--order xyxy` / `--order yxyx` | four bare numbers that are corners |
    | `--anchor center` | `x`,`y` is the box centre |
    | `--units normalized` / `0-1000` / `percent` | relative coordinates |
    | `--units normalized --anchor center` | YOLO |
    | `--units normalized --origin bottom-left` | Apple Vision |
    | `--image-size WxH` | pixels of a resized copy |
    | `-l NAME` | boxes that carry no label |

    Behaviour worth knowing:

    - **`--mode add` (default)** keeps existing boxes and skips any new box that
      is already there (same label, overlapping). Re-running the same input
      changes nothing, so retrying is always safe.
    - **`--mode replace`** gives each listed image exactly the boxes supplied.
      Other images are untouched. Use it to correct an image.
    - **An image given with no boxes is left untouched**, in either mode, so a
      detector that found nothing can never wipe existing labels. `--negatives`
      makes it count: `--image empty.jpg --negatives` records an object-free
      image as a negative example (real training signal), and
      `--image a.jpg --mode replace --negatives` clears an image's boxes.
    - **`--dry-run`** reports what would change without writing.
    - If any input is unusable (unknown image, box outside the image), nothing
      is written and the exit code is `1`. `--lenient` applies the rest.
    - Boxes hanging over an edge are trimmed and counted as `clamped`. A box
      smaller than one pixel, or with a negative width or height, is refused.

    ## Letting a detector do the first pass

    ```
    labelkit detect <dataset> --model model.mlpackage --format ndjson | labelkit annotate <dataset> --from -
    labelkit detect <dataset> --detector rectangles -l card --format ndjson | labelkit annotate <dataset> --from -
    ```

    `--detector` is a built-in Apple Vision detector (`rectangles`, `faces`,
    `humans`, `animals`, `saliency`); `--model` is a Core ML object detector,
    including one trained earlier on this dataset. Detections are a draft:
    render and review them like any other boxes.

    ## Datasets from and for other tools

    ```
    labelkit import ./downloaded --into <dataset>            # YOLO, COCO or Hugging Face layout, detected
    labelkit export <dataset> --format yolo --out ./for-yolo  # or coco, huggingface
    ```

    `import` copies the source's images into the dataset and merges its boxes.
    It never overwrites a file (a clashing name is renamed and reported),
    repeating it changes nothing, and source images without boxes are skipped
    unless `--negatives` is given. If labels come in as `class_0`, `class_1`, …
    the source has no class names: pass its `data.yaml` or a one-name-per-line
    file with `--names`. `export` writes a new folder and only reads
    the dataset; `--out` must be new or empty. Use `--dry-run` on `import` first
    when unsure what a folder contains.

    ## Checking a dataset

    `labelkit validate <dataset>` reports, as JSON `issues` with a stable `code`:

    - **errors** (exit 1): `no-annotations-file`, `invalid-annotations-file`,
      `missing-image`, `duplicate-entry`, `empty-label`, `empty-box`,
      `box-outside-image`, `unknown-label` (with `--labels`).
    - **warnings** (exit 0, or 1 with `--strict`): `box-overflows-image`,
      `duplicate-box`, `duplicate-image` (the same photo under two names),
      `unreadable-image`, `unused-label`.

    Each issue names the `image` and the `box` number, matching the `#n` drawn
    by `render`.

    `labelkit stats <dataset>` also shows what `validate` cannot judge:

    - labels with very few boxes. Apple's guidance is to start from roughly 30
      annotated images per class, balanced across classes;
    - `boxesPerImage.max` and `maxImage`: one image with far more boxes than the
      rest can skew a model, so look at it;
    - `--per-image` lists every image with its status and box count.

    ## Training

    ```
    labelkit train <dataset> -o model.mlmodel
    ```

    Trains a Create ML object detector and prints a JSON report. It can take
    minutes to hours and needs real image files (not symlinks). Run `validate`
    first. Create ML holds out part of the data for validation on its own
    (`--validation-split` to control it). See `labelkit train --help`.

    ## When to hand over to the user

    The editor is the right tool for a human check: suggest `labelkit <dataset>`
    when labels need a judgment call you cannot make from a picture, or before
    training on labels nobody has reviewed. Say what you labelled and what you
    were unsure about.

    ## Command summary

    | Command | Does | Writes |
    |---|---|---|
    | `labelkit stats <dataset> [--per-image]` | counts, labels, unlabelled images | nothing |
    | `labelkit validate <dataset> [--labels a,b] [--strict]` | finds problems, exit 1 on errors | nothing |
    | `labelkit annotate <dataset> …` | adds or replaces boxes | `annotations.json` |
    | `labelkit render <dataset> [images…] --out DIR [--grid N] [--unlabeled]` | pictures with boxes drawn | files in DIR |
    | `labelkit detect <image-or-dir> --model M \| --detector D` | runs a detector, prints boxes | nothing |
    | `labelkit import <source> --into <dataset>` | brings in a YOLO, COCO or Hugging Face dataset | images and `annotations.json` |
    | `labelkit export <dataset> --format F --out DIR` | writes the dataset as YOLO, COCO or Hugging Face | files in DIR |
    | `labelkit train <dataset> [-o model.mlmodel]` | trains a Core ML detector | the model file |

    Every command has `--help` with examples. `stats`, `validate` and `annotate`
    also take `--format text` for a human-readable summary.

    """#
}
