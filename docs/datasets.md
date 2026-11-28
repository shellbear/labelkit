# Sharing, storing and reusing datasets

A labelkit dataset is Apple's Create ML object-detection format: a folder of
images plus one `annotations.json`. That is deliberately all there is, so the
question of where the images live, and how to trade datasets with people using
other tools, is answered with commands and recipes rather than a service.

- [Import a dataset made elsewhere](#import-a-dataset-made-elsewhere)
- [Export for another tool](#export-for-another-tool)
- [Publish or back up on Hugging Face](#publish-or-back-up-on-hugging-face)
- [Keep images in your own bucket](#keep-images-in-your-own-bucket)
- [Use a big model to label, train a small one](#use-a-big-model-to-label-train-a-small-one)

## Import a dataset made elsewhere

```bash
labelkit import ./downloaded-dataset --into ./cards
```

`import` reads **YOLO**, **COCO** and **Hugging Face image-folder** datasets,
copies their images into your dataset folder and merges their boxes into
`annotations.json`. The format is worked out from what is in the folder;
`--format yolo|coco|huggingface` overrides.

| Source | Recognised by | Notes |
|---|---|---|
| YOLO | `.txt` label files beside images, or `labels/` next to `images/` | class names from `data.yaml` or `classes.txt`; segmentation rows become the box around the polygon |
| COCO | a JSON with `images`, `annotations`, `categories` | pass the folder or the `.json` itself |
| Hugging Face | `metadata.jsonl` with `objects.bbox` | `[x, y, width, height]` in pixels; `categories` or `category`, as names or ids |

A YOLO download often comes without its class names, in which case boxes
import as `class_0`, `class_1`, …. Give the names with `--names`, pointing at
the dataset's `data.yaml` or a text file with one name per line:

```bash
labelkit import ./coco8 --into ./coco8-ml --names coco8.yaml
```

Things it is careful about:

- **Nothing is overwritten.** If a different image already has the same name,
  the incoming one is renamed (`a.jpg` → `a-2.jpg`) and its boxes follow it.
- **Safe to repeat.** Importing the same source again copies nothing and adds
  nothing.
- **All or nothing.** If any box can't be used (outside its image, no size),
  nothing is copied or written and the exit code is `1`. `--lenient` applies
  the rest; `--dry-run` shows what would happen.
- **Splits are merged.** `train/`, `valid/` and `test/` come in together: a
  Create ML dataset is one folder, and Create ML makes its own validation split
  when it trains.
- **Images without boxes are skipped** unless you pass `--negatives`, because
  in a downloaded dataset an image with no boxes may be a deliberate negative
  or simply unlabelled.

Datasets from **Roboflow Universe** can be downloaded in "CreateML" format, in
which case there is nothing to import: open the folder with `labelkit`.

## Export for another tool

```bash
labelkit export ./cards --format yolo        --out ./cards-yolo
labelkit export ./cards --format coco        --out ./cards-coco
labelkit export ./cards --format huggingface --out ./cards-hf
```

| Format | Written into `--out` |
|---|---|
| `yolo` | `images/`, `labels/<name>.txt` (`class cx cy w h`, normalized), `classes.txt`, `data.yaml` |
| `coco` | `_annotations.coco.json` with the images beside it |
| `huggingface` | `README.md` (a dataset card) and `train/metadata.jsonl`, images under `train/images/` |

Every entry whose image file exists is exported, negatives included; images
that have no entry yet are unlabelled and are left out. Class ids follow the
labels in alphabetical order, so a dataset always exports the same numbering.
`--out` must be a new or empty folder, and your dataset is only read. Images
are copied (on APFS a copy takes no extra space until one side changes);
`--no-images` writes just the annotation files.

The YOLO export puts every image under `train`. Split off a validation set with
your YOLO tooling before training.

## Publish or back up on Hugging Face

[Hugging Face](https://huggingface.co/docs/hub/datasets-image) hosts image
datasets as versioned repositories, public or private, and the `huggingface`
export is exactly the layout it expects. It needs their `hf` command-line tool
and an account; labelkit never sees your token.

```bash
labelkit export ./cards --format huggingface --out ./cards-hf
hf auth login
hf upload your-name/cards ./cards-hf --repo-type=dataset
```

A repository is public unless you make it private; set that when creating it
(on the website, or with the option their CLI documents) before uploading
anything you don't want published.

and, on another machine or for someone else's dataset:

```bash
hf download your-name/cards --repo-type dataset --local-dir ./cards-hf
labelkit import ./cards-hf --into ./cards --negatives
```

Before publishing, open the generated `README.md` and add a `license:` line to
the YAML at the top. Worth knowing, from Hugging Face's documentation at the
time of writing: private storage is free up to 100 GB per account, a repository
should stay under 100,000 files, and no folder should hold more than 10,000
(the export splits images into numbered subfolders once a dataset passes 5,000).

## Keep images in your own bucket

For a team that keeps data in-house, the simplest arrangement is: **the
annotations file in git, the images in a bucket.** `annotations.json` is small
and diffs well; the images are large and never change.

Any S3-compatible store works (Cloudflare R2, Backblaze B2, AWS S3), synced with
[rclone](https://rclone.org), which keeps the credentials in its own config:

```bash
# .gitignore: everything in the dataset folder except the annotations
cards/*
!cards/annotations.json

rclone copy ./cards remote:my-bucket/cards --exclude annotations.json   # upload images
rclone copy remote:my-bucket/cards ./cards                              # fetch them elsewhere
```

After fetching, `labelkit validate ./cards` tells you whether every image the
annotations refer to has arrived (`missing-image`), and `labelkit stats ./cards`
lists any that are there but not yet labelled.

If you already use [DVC](https://dvc.org), it works as it is: track the images
with `dvc add` and keep `annotations.json` in git. labelkit needs nothing
special either way, because it only ever reads and writes the local folder.

## Use a big model to label, train a small one

You can't shrink an existing detector with labelkit, but you can use one as a
teacher: let it label your images, check its work, and train a small Create ML
model on the result. For an on-device model this is often the quickest route
to good training data.

```bash
# 1. Draft labels from the teacher
labelkit detect ./cards --model teacher.mlpackage --format ndjson \
  | labelkit annotate ./cards --from -

# 2. Check them: by eye in pictures, and in the editor for the doubtful ones
labelkit render ./cards --out /tmp/check
labelkit ./cards

# 3. Validate, then train the small model
labelkit validate ./cards
labelkit train ./cards -o cards.mlmodel
```

The teacher can be:

- **Any Core ML object detector** via `detect --model`. A YOLO model qualifies
  once exported to Core ML with its own tooling. The built-in Vision detectors
  (`--detector`) cover only a few things (people, faces, cats and dogs,
  rectangles), so expect them to find a fraction of what a trained model would.
- **A vision-language model** (Claude, Gemini, GPT, Qwen, …): have it answer
  with boxes and pass them to `labelkit annotate`. An AI agent with the
  labelkit skill does this loop on its own; see [agents.md](agents.md).
- **A dataset someone already labelled**: `labelkit import` it, then add your
  own images on top.

Treat teacher labels as a draft. A detector trained on unreviewed labels learns
the teacher's mistakes along with its strengths.
