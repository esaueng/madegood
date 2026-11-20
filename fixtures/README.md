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
   and drops altitude, magnetic heading, and event data outside a small allowlist.

3. **Label and check.** Write `labels.json` in the staged fixture folder using
   the schema below. Review the filenames and description for identifying
   details, then check the anonymized bytes and inspect the replay. For track
   v1 input, write `track.json.gz` inside the fixture folder and pass that file
   to the replay CLI.

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
| `source` | How the truth was measured: `video`, `manual-count`, `instruments`, `synthetic`. |
| `description` | Conditions and setup (wrist, boat or board type). No places, dates, or names. |
| `license` | `CC-BY-4.0`, or `CC0-1.0` for generated data. |
| `truth.strokes` | Ground-truth count for kayak, canoe, or SUP. Use a raw recording with motion. |
| `truth.strokeRateSPM` | Ground-truth average strokes per minute during active paddling, excluding pauses and time between bouts. Measure from the reference data. |
| `truth.maneuvers` | Sailing tacks and gybes as `{ "t": 312.4, "type": "tack" }`. Label the crossing time in seconds since session start. Use `[]` for a session verified to contain neither. |
| `truth.windDirectionDeg` | Sailing wind direction in degrees true, measured from where the wind blows. |
| `truth.distanceM` | Optional reference distance in metres for inspection. |

Include only measured values. Sailing maneuver matching uses the correct type
and a crossing within 2 seconds of the label and inside the detected turn. An
unmatched detection counts toward the false-positive fraction of all detections.
When wind truth is available, it sets the wind for maneuver detection and
selects the side of the axis for the independent wind estimate. See
[PLAN.md §5](../docs/PLAN.md#5-sport-metrics-and-algorithms) for the thresholds.
