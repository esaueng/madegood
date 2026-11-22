# Fixtures

Small, anonymized recordings with ground-truth labels. WaterKit's accuracy tests run
over them (Phase 2), and `waterkit-replay` can open any of them.

```
fixtures/<sport>/<name>/
  meta.json + *.ndjson.gz    a raw recording (docs/formats.md), usually trimmed
  track.json.gz              or a track v1 file instead
  labels.json                ground truth (below)
```

Keep checked-in fixtures small (aim for under 2 MB). The full anonymized corpus
lives in a public R2 bucket. Its objects use the same `<sport>/<name>/<file>` layout.

## Fetching and testing

```sh
FIXTURES_BASE_URL=https://fixtures.example.invalid scripts/fetch-fixtures
swift test --package-path packages/WaterKit
```

Set `FIXTURES_BASE_URL` to the bucket's public HTTP(S) URL, including any common
path prefix. The default is the placeholder above. CI reads the URL from
the GitHub Actions repository variable of the same name. The fetcher uses
Python 3.9 or later and verifies each object's SHA-256 against
[`scripts/fixture-manifest.json`](../scripts/fixture-manifest.json). It reuses
verified files and saves downloads under the ignored `fixtures/.corpus/`
directory. An empty manifest needs no network access.

WaterKit tests the labels present in both directories. In a checkout without
the corpus, it still runs the checked-in fixture tests. Remove the corresponding
local directory in `fixtures/.corpus/` if a fixture is retired from the manifest.

## Publishing a recording

1. **Record and export.** Save the raw session folder and gather independent
   ground truth from video, a manual count, or instruments. Keep the original
   recording and any reference video private.

2. **Anonymize.** Use a staging folder outside Git and a generic, unique name
   made of lowercase letters, numbers, and hyphens.

   ```sh
   stage=$(mktemp -d)
   session=kayak/flatwater-steady
   mkdir -p "$stage/kayak"
   scripts/anonymize-track /path/to/exported-session "$stage/$session"
   ```

   This moves the track to a fake origin in the Atlantic (10°N 30°W), keeping every
   distance and bearing. It shifts all times to 2000-01-01, replaces the session ID,
   and drops altitude, magnetic heading, and event data outside a small allowlist
   (analysis numbers and the auto-pause flag).

   For a paddling recording with reviewed stroke labels (see
   [How to label a session](#how-to-label-a-session)), pass them along:
   `scripts/anonymize-track <recording> "$stage/$session" --labels labels.json`.
   It refuses drafts, labels for another sport, and times outside the recording,
   and writes the labels with only the documented fields. Their times are seconds
   since the session start, which anonymizing keeps.

3. **Label and check.** Write `labels.json` in the staged fixture folder using
   the schema below, unless `--labels` already put it there. Review the filenames
   and description for identifying details, then check the anonymized bytes and
   inspect the replay. For track v1 input, write `track.json.gz` inside the
   fixture folder and pass that file to the replay CLI.

   ```sh
   scripts/anonymize-track --check "$stage/$session"
   swift run --package-path packages/WaterKit waterkit-replay "$stage/$session"
   ```

4. **Upload.** In R2, upload the recording files and `labels.json` under the
   key `<sport>/<name>/<file>`, relative to the configured base URL. Preserve the
   exact file bytes, including gzip files. Leave out hidden files such as
   `.DS_Store`. Use a fresh fixture name for any revision so old commits can still
   fetch the original objects.

5. **Pin the manifest.** From the repo root, add the per-file hashes under
   `fixtures["<sport>/<name>"]` in `scripts/fixture-manifest.json`. For the staged
   recording above, run:

   ```sh
   python3 - "$stage" "$session" <<'PY'
   import hashlib
   import json
   from pathlib import Path
   import sys

   stage, session = sys.argv[1:]
   manifest = Path("scripts/fixture-manifest.json")
   data = json.loads(manifest.read_text())
   if session in data["fixtures"]:
       raise SystemExit(f"Fixture already in manifest: {session}")
   data["fixtures"][session] = {
       file.name: hashlib.sha256(file.read_bytes()).hexdigest()
       for file in (Path(stage) / session).iterdir()
       if not file.name.startswith(".")
   }
   manifest.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
   PY
   ```

   Fetch and test the uploaded fixture using its public URL. Commit the manifest
   change and describe how the ground truth was measured in the pull request.

By contributing a recording you agree to it being published under CC BY 4.0 (or CC0
for generated data), as stated in `labels.json`.

## labels.json (v1)

```json
{
  "v": 1,
  "sport": "kayak",
  "source": "video",
  "description": "Flat water, steady pace, watch on left wrist.",
  "license": "CC-BY-4.0",
  "truth": {
    "strokes": 812,
    "strokeRateSPM": 54.5,
    "distanceM": 2410
  }
}
```

| Field | Notes |
|---|---|
| `v` | `1` |
| `sport` | As in the recording. |
| `source` | How the truth was measured: `video`, `manual-count`, `motion-review` (a person checked every stroke on the recorded signal), `instruments`, `synthetic`. `draft` (unreviewed detector output) is never accepted. |
| `description` | Conditions and setup (wrist, boat or board type). No places, dates, or names. |
| `license` | `CC-BY-4.0`, or `CC0-1.0` for generated data. |
| `truth.strokes` | Ground-truth count for kayak, canoe, or SUP. Use a raw recording with motion. With `strokeTimes`, it is their count; leave it out or make it match. |
| `truth.strokeRateSPM` | Ground-truth average strokes per minute during active paddling, excluding pauses and time between bouts. Measure from the reference data. With `strokeTimes`, it is derived (below); leave it out or make it match within 0.05. |
| `truth.strokeTimes` | Every stroke, as `{ "t": 12.48 }` or `{ "t": 12.48, "side": 0 }`: seconds since session start, the clock of the motion stream. `side` is 0 or 1 when known (canoe, SUP), with the detector's meaning: 0 is the side paddled first. Leave it out for kayak. |
| `truth.excluded` | Stretches that are not paddling, as `{ "start": 0, "end": 41.2 }` in the same seconds: getting in, drifting, resting, carrying. No stroke may lie in one. |
| `truth.maneuvers` | Sailing tacks and gybes as `{ "t": 312.4, "type": "tack" }`. Label the crossing time in seconds since session start. Use `[]` for a session verified to contain neither. |
| `truth.windDirectionDeg` | Sailing wind direction in degrees true, measured from where the wind blows. |
| `truth.distanceM` | Optional reference distance in metres for inspection. |

Include only measured values. Stroke truth from `strokeTimes`: the count is every
labelled stroke. For the rate, strokes form bouts that end at an excluded stretch or at a
gap longer than 4 s per wrist cycle (2 s between kayak strokes, 4 s for canoe and SUP),
and the rate is 60 × the intervals within bouts of at least three strokes over their total
time. The accuracy test compares these with what session detail shows: its count and
average rate, in moving time only. A stroke session detail counts in an excluded stretch
is an error, and so is a labelled stroke it leaves out (for example, paddling below the
auto-pause speed). Sailing maneuver matching uses the correct type
and a crossing within 2 seconds of the label and inside the detected turn. An
unmatched detection counts toward the false-positive fraction of all detections.
When wind truth is available, it sets the wind for maneuver detection and
selects the side of the axis for the independent wind estimate. See
[PLAN.md §5](../docs/PLAN.md#5-sport-metrics-and-algorithms) for the thresholds.

### Paddling labels example

```json
{
  "v": 1,
  "sport": "kayak",
  "source": "motion-review",
  "description": "Flat water, steady pace, watch on left wrist.",
  "license": "CC-BY-4.0",
  "truth": {
    "strokeTimes": [{ "t": 41.92 }, { "t": 42.97 }, { "t": 44.05 }],
    "excluded": [{ "start": 0, "end": 41.2 }]
  }
}
```

## How to label a session

Stroke labels come from a person checking the recording; the detector only proposes
candidates. Everything below stays on your computer until step 7.

1. **Record.** Paddle with MadeGood on the Apple Watch. Note anything unusual (rafting
   up, a portage, a capsize) and roughly when.
2. **Export.** On the iPhone, open the session and choose **Share raw recording**. Save
   the ZIP to your Mac, outside this repository, and unzip it: you get a folder named
   after the session ID with `meta.json` and the stream files. It holds precise
   locations and times, so keep it private.
3. **Draft.** From the repository root:

   ```sh
   scripts/label-strokes draft ~/labelling/<session-folder> ~/labelling/review
   ```

   This writes `labels.draft.json` (the detector's candidate strokes, unreviewed) and
   `review.html`, a self-contained page that loads nothing from the network.
4. **Review.** Open `review.html` in a browser. The dark line is the wrist motion on its
   main axis, with one positive peak per wrist cycle. Markers are strokes, GPS speed is
   along the bottom, and grey shading marks where the app counts no strokes (auto-pause,
   vehicle legs, manual pauses).
   - Page through with <kbd>Space</kbd>; the green bar on the overview shows what you
     have viewed, and <kbd>N</kbd> jumps to the next unviewed part.
   - Click to add a stroke at the nearest peak or trough (<kbd>Alt</kbd>+click places
     it exactly), drag a marker to move it, and right-click (or select and press
     <kbd>Delete</kbd>) to remove it. Grey dashed lines are removed candidates; click one
     to restore it.
   - <kbd>Shift</kbd>+drag marks a stretch that is not paddling, and removes the strokes
     inside. Right-click it to undo that.
   - For kayak there are two markers per cycle. The detector puts the second one half a
     cycle after the first, which can be a few tenths of a second from the other blade's
     stroke; count and rate do not depend on the exact time, so only move a marker that
     is on the wrong stroke.
   - Work is saved in the browser as you go. **Save progress** downloads a file you can
     reopen with **Load labels**, or with
     `scripts/label-strokes draft <session-folder> <folder> --labels <file>`.
5. **Export the labels.** Choose how the truth was measured (`motion-review` when you
   checked the signal, `video` when you checked against video), write a short
   description without places, dates or names, tick the confirmation, and click
   **Export labels.json**.
6. **Score (optional).** `scripts/label-strokes score <session-folder> labels.json`
   prints the labelled and session-detail counts and rates against PLAN §5, with a
   per-stroke breakdown of missed and extra strokes.
7. **Make the fixture.** Follow [Publishing a recording](#publishing-a-recording) with
   `--labels labels.json` in step 2. Only the anonymized folder leaves your computer. The
   accuracy test `labeledPaddlingRecordingsMeetStrokeThresholds` picks up every
   labelled kayak, canoe and SUP fixture; until the first one exists it is skipped.
