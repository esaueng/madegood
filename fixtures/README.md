# Fixtures

Small, anonymized recordings with ground-truth labels. WaterKit's accuracy tests run
over them (Phase 2), and `waterkit-replay` can open any of them.

```
fixtures/<sport>/<name>/
  meta.json + *.ndjson.gz    a raw recording (docs/formats.md), usually trimmed
  track.json.gz              or a track v1 file instead
  labels.json                ground truth (below)
```

Keep each fixture small (aim for under 2 MB). The full raw corpus will live outside
Git; how it is hosted is still an open decision (docs/PLAN.md §10), and
`scripts/fetch-fixtures` will download it once that is settled.

## Adding a recording

1. **Anonymize it.** Never commit a raw recording as it came off the device.

   ```sh
   scripts/anonymize-track ~/Downloads/<session-folder> fixtures/kayak/flatwater-steady
   ```

   This moves the track to a fake origin in the Atlantic (10°N 30°W), keeping every
   distance and bearing. It shifts all times to 2000-01-01, replaces the session ID,
   and drops altitude and any free-text or position-like event data. Speeds, courses,
   headings, heart rate, and motion data are unchanged.

2. **Check it.** CI runs the same check over the whole folder and fails on anything that
   is not anonymized:

   ```sh
   scripts/anonymize-track --check fixtures
   ```

3. **Look at it** before committing: `swift run --package-path packages/WaterKit
   waterkit-replay fixtures/kayak/flatwater-steady`. Make sure nothing in `labels.json`
   (or the folder name) gives away a place, date, or person.

4. **Add `labels.json`** and say in the pull request how the truth was measured.

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
    "maneuvers": [ { "t": 312.4, "type": "tack" }, { "t": 590.0, "type": "gybe" } ],
    "windDirectionDeg": 225,
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
| `truth` | Only the values that are actually known. Times are `t`, seconds since the session start. Wind direction is degrees true, the direction it blows **from**. |

The accuracy targets these labels are checked against are in docs/PLAN.md §5.
