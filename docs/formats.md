# File formats

MadeGood has two recording formats. Both are versioned contracts: WaterKit
(`packages/WaterKit`) is the single implementation, and the recorder app writes files
through the same types the readers use.

| Format | Used for | Leaves the device? |
|---|---|---|
| **Raw recording v2** | Research and algorithm work: every sensor stream (motion at 100 Hz, GPS at 1 Hz, heading at about 1 Hz), rounded well below sensor noise | Only when the user shares it (AirDrop/Files), or with an opt-in "contribute data" setting |
| **Track v1** | The stored and uploaded session: GPS, heart rate, events, analysis summary | Uploaded when sync is on |

WaterKit also exports tracks as **GPX 1.1** for other apps (see [GPX export](#gpx-export)).
GPX is output only: nothing reads it back.

All values are SI: metres, seconds, m/s, m/s², rad/s, and degrees true (0–360,
clockwise from north). Convert units only for display, with WaterKit's `SpeedUnit`
(kn, km/h, mph, m/s) and `DistanceUnit` (m/km, nm, mi). They use the exact
definitions 1 nm = 1852 m, 1 mi = 1609.344 m and 1 h = 3600 s.

## Compatibility rules

- A reader rejects a version it does not know, with a clear error, rather than guessing.
- Adding an **optional** field does not change the version. Readers ignore unknown fields.
- Removing a field, renaming one, changing a unit or meaning, or making an optional
  field required bumps the version. WaterKit keeps a reader for every older version.
- Wire names (field names, sport names, event types) never change once released.
- Sampling rates and value resolution are not part of a version. Writers may record a
  stream at a different rate or round its values to a different step (see
  [Resolution](#resolution)) without a version bump, so readers must take rates from the
  timestamps and must not assume more precision than the written digits carry.

---

## Raw recording v2

A session folder, zipped for sharing. Version 2 holds only absolute timestamps: no file
carries a reading of the device's boot-time clock (version 1 did; see
[Raw recording v1](#raw-recording-v1), which readers still accept):

```
<sessionId>/
  meta.json
  gps.ndjson[.gz]
  motion.ndjson[.gz]
  hr.ndjson[.gz]
  heading.ndjson[.gz]
  events.ndjson[.gz]
  clock.ndjson[.gz]
```

- Each stream is newline-delimited JSON: one object per line, UTF-8, `\n` line ends.
- Each stream may be plain (`.ndjson`) or gzipped (`.ndjson.gz`), but not both.
  A gzipped stream may hold several gzip members appended one after another; the
  recorder writes one member per flush, so a crash loses at most the last flush.
- Missing stream files mean the stream was not recorded.
- Readers skip a damaged last line (a write cut off by a crash) and report it, and
  report and skip any other line that does not parse. A recording never fails to open
  because of a damaged stream.

### Clocks and timestamps

Every line has `ts`, an absolute time in Unix seconds:

| Streams | `ts` clock | Source |
|---|---|---|
| `gps`, `hr`, `heading`, `events` | Wall clock | `CLLocation.timestamp`, HealthKit sample start date, `CLHeading.timestamp`, `Date()` |
| `motion` | The session's monotonic clock | `CMLogItem.timestamp`, converted on the device (below) |
| `clock` | Both (see below) | `Date()` and the monotonic clock, read together |

The **monotonic clock** is the device's uptime clock moved onto Unix time at the session
start. The recorder reads `Date()` and `ProcessInfo.systemUptime` together when the session
starts, keeps that pair in memory only, and writes every boot-time reading as

```
mono = startedAt + (uptime − uptime at start)
```

So it equals the wall clock at `meta.startedAt` and then advances steadily, without the
jumps a system clock correction makes. Times are stored as doubles in Unix seconds, which
resolve to about 0.24 µs at today's dates: motion samples keep their order and their
relative timing to within that, far finer than the 10 ms between samples. A sample that
rounds onto an anchor's `mono` value belongs to the segment before that anchor.

Clock anchors pair the two clocks. The start is an implicit anchor (`mono = unix =
startedAt`); the recorder appends another anchor to `clock.ndjson` every 60 s and whenever
the system clock changes. Readers convert a monotonic time with the latest anchor before it
(the first anchor for times at or before the start):

```
unix = anchor.unix + (mono - anchor.mono)
```

Session time is `t = unix - meta.startedAt`. WaterKit's `RawSessionReader` does this
conversion; files never store `t`. Analysis that must not see wall-clock jumps (paddle
strokes, with the user's pauses) runs on the monotonic clock instead.

### meta.json

```json
{
  "format": "madegood-raw",
  "version": 2,
  "sessionId": "6F1C2A3E-8A5B-4C1D-9E2F-0A1B2C3D4E5F",
  "sport": "kayak",
  "startedAt": 1809165600.0,
  "endedAt": 1809169200.0,
  "device": { "kind": "watch", "model": "Watch7,5", "os": "watchOS 26.1" },
  "app": { "version": "0.1.0", "build": "1" },
  "requestedRates": { "motion": 100, "gps": 1, "heading": 1 }
}
```

| Field | Notes |
|---|---|
| `format`, `version` | Always `madegood-raw` and `2`. |
| `sessionId` | Device-generated UUID, also used as the track's session ID. |
| `sport` | One of `sailing`, `windsurfing`, `motorboating`, `kayak`, `canoe`, `sup`. |
| `startedAt` | Unix time of the session start, s. |
| `endedAt` | Unix time of a clean stop. Absent if recording stopped unexpectedly. |
| `device` | `kind` is `watch` or `phone`; `model` is the hardware identifier. **Never** the user-assigned device name. |
| `requestedRates` | Requested sampling rates, Hz. Actual rates come from the data: sensors may deliver less often, and gaps are visible in `ts`. |

`meta.json` is written at the start and rewritten at a clean stop.

### Stream lines

Optional fields are left out when the sensor reported the value as invalid
(CoreLocation uses -1). JSON cannot hold NaN or infinity; recorders must drop such
values, and the line encoder rejects them.

**gps** (`CLLocation`; speed and course are the receiver's Doppler values)

```json
{"ts":1809165601.0,"lat":0.0001,"lon":0.0002,"alt":1.2,"hacc":4.0,"vacc":3.0,"spd":1.5,"spdacc":0.3,"crs":90.0,"crsacc":5.0}
```

| Field | Unit | Required |
|---|---|---|
| `ts` | Unix s | yes |
| `lat`, `lon` | degrees (WGS 84) | yes |
| `alt` | m | no |
| `hacc`, `vacc` | m (accuracy radius) | no |
| `spd`, `spdacc` | m/s | no |
| `crs`, `crsacc` | degrees true | no |

**motion** (`CMDeviceMotion`, device frame)

```json
{"ts":1809165600.01,"ax":0.12,"ay":-0.3,"az":0.05,"gx":0.0,"gy":0.0,"gz":-9.80665,"rx":0.1,"ry":0.0,"rz":-0.2,"qx":0.0,"qy":0.0,"qz":0.0,"qw":1.0}
```

| Fields | Meaning | Unit |
|---|---|---|
| `ts` | monotonic clock (Unix) | s |
| `ax ay az` | user acceleration (gravity removed) | m/s² (CoreMotion's g × 9.80665) |
| `gx gy gz` | gravity | m/s² (g × 9.80665) |
| `rx ry rz` | rotation rate | rad/s |
| `qx qy qz qw` | attitude quaternion | unitless |

**hr** (HealthKit heart-rate samples): `{"ts":1809165603.0,"bpm":99}`, where `ts` is the sample's start date.

**heading** (`CLHeading`): `{"ts":…,"mag":10.0,"true":12.0,"acc":5.0}`. All values are in
degrees. `true` is left out when no location is available. The recorder writes at most one
line per second (about 1 Hz), although CoreLocation reports heading about 50 times a second.
Earlier recordings hold every report.

**events**: `{"ts":…,"type":"mark","data":{…}}`. Types: `start`, `stop`, `pause`,
`resume`, `mark`, `lap`, `mob`, plus analysis types such as `tack` and `gybe`. Unknown
types are kept as they are. `data` is optional and free-form.

`linePing` records one end of a race start line pinged during the countdown
(docs/metrics.md, "Start line"). The countdown is before the session, so the recorder
writes the line in use at the `start` event's `ts`, one event per pinged end:
`{"ts":…,"type":"linePing","data":{"end":"pin","lat":…,"lon":…,"fixes":3,"hacc":4.0,"age":42.5}}`.
`end` is `pin` or `boat`; `fixes` the fixes averaged; `hacc` their mean accuracy (m,
optional); `age` the seconds from the ping to the event (the ping was at `ts - age`).
It holds positions, so it is not part of published recordings or shared copies.

**clock**: `{"unix":1809165660.5,"mono":1809165660.0}` (here the wall clock is 0.5 s
ahead of the monotonic clock 60 s in).

### Resolution

Writers round values to these steps (`RawFormat.Resolution`). Each step is far below the
sensor's noise or accuracy, so analysis gives the same results, and short numbers keep a
recording about a third of its unrounded size. Rounding divides by an exact power of ten,
so a value prints as its short decimal (`0.079`, not `0.07900000000000001`).

| Stream | Fields | Step | Sensor, for comparison |
|---|---|---|---|
| motion | `ts` | 1 µs (1e-6 s) | samples every 10 ms, jitter under 10 µs |
| motion | `ax ay az`, `gx gy gz` | 0.001 m/s² | noise 0.04–0.19 m/s² (acceleration), 0.002–0.004 m/s² (gravity) |
| motion | `rx ry rz` | 0.0001 rad/s | noise 0.01–0.04 rad/s |
| motion | `qx qy qz qw` | 0.00001 | noise 1–2e-4 |
| gps | `ts` | 0.001 s | |
| gps | `lat`, `lon` | 1e-7° (about 1 cm) | accuracy several metres |
| gps | `spd` | 0.01 m/s | |
| gps | `alt`, `crs` | 0.1 (m or degrees) | |
| heading | `ts` | 0.001 s | |
| heading | `mag`, `true` | 0.1° | accuracy typically about 10° |

Accuracy fields (`hacc`, `vacc`, `spdacc`, `crsacc`, heading `acc`) are written as
reported, never rounded: analysis accepts or rejects readings by comparing them with
thresholds (for example `hacc` at most 25 m), and rounding must not change that decision.
`hr`, `events` and `clock` values are written as reported. Converted (version 1) and
anonymized copies are written with the same steps. Earlier recordings hold every
value at full double precision. Both are valid version 2; readers must not assume either
precision.

### Raw recording v1

Recordings made before version 2. Readers convert them on reading, and the iPhone converts
one before sharing it (`RawFormatConversion`, streamed and cached per target version and
revision), so a shared raw recording is always version 2 and holds only the recording's own
files. A conversion that hits anything but a truncated or damaged last gzip member (a read
error, a stream that is not gzip, the inflate limit) fails and leaves nothing behind. The
watch sends a recording only when its `meta.json` names a version the iPhone app says it
reads (`rawVersions` in its WatchConnectivity application context); one whose version it
cannot read stays on the watch too. An iPhone never acknowledges a recording whose version
it cannot read, so the watch keeps its copy. Version 1 differs only in its clocks:

- `meta.json` has `"version": 1` and `"clock": {"unix": …, "uptime": …}`, the wall clock and
  the device uptime (seconds since boot) read together at the start.
- `motion` `ts` is device uptime, s (`CMLogItem.timestamp`, unconverted).
- `clock` lines are `{"unix": …, "uptime": …}`.

Readers put them on the monotonic clock with the `meta.json` anchor,
`mono = clock.unix + (uptime − clock.uptime)`, and then read them as version 2.

---

## Track v1

Gzipped JSON (`track.json.gz`), column-oriented. The iPhone writes it into a finished
recording's folder, next to the raw streams, when it first analyzes the session, and
rewrites it when the analysis changes. Times are `t`, seconds since
`startedAt`.

```json
{
  "v": 1,
  "sessionId": "6f1c2a3e-8a5b-4c1d-9e2f-0a1b2c3d4e5f",
  "sport": "sailing",
  "startedAt": "2027-05-01T10:00:00.000Z",
  "gps": { "t": [0, 1], "lat": [0.0001, 0.00011], "lon": [0.0002, 0.0002],
           "spd": [2.5, null], "crs": [10.0, null], "hacc": [4.0, 3.5] },
  "hr": { "t": [0.5], "bpm": [92] },
  "events": [ { "t": 1.2, "type": "tack", "data": { "durationS": 8.1 } } ],
  "summary": { },
  "analyzerVersion": "1.0.0"
}
```

| Field | Notes |
|---|---|
| `v` | `1`. |
| `sessionId` | Lowercase UUID. |
| `startedAt` | ISO 8601 UTC. Writers include milliseconds; readers accept either form. |
| `gps` | Required columns `t lat lon spd crs hacc`; optional columns `alt spdacc crsacc` appear only when at least one value exists. Every column has the same length. `null` marks an invalid value. |
| `hr` | Columns `t bpm`. |
| `events` | As in the raw format, with `t` in place of `ts`. |
| `summary` | The sport's analysis summary (defined per sport in `docs/metrics.md`). Optional. |
| `analyzerVersion` | Version of the analyzer that wrote `summary` and analysis events. Optional. |

Writers round values to keep files small. Rounding never matters for analysis: the raw
recording keeps its own, finer or equal, [resolution](#resolution), and the GPS steps
below are the same as the raw ones.

| Column | Step |
|---|---|
| `t` | 0.001 s |
| `lat`, `lon` | 1e-7° (about 1 cm) |
| `spd`, `spdacc` | 0.01 m/s |
| `crs`, `crsacc`, `hacc`, `alt` | 0.1 |
| `bpm` | 0.1 |

Raw motion data is not part of a track.

### Upload

`PUT /api/sessions/<id>/track` takes the gzipped file exactly as written: the body is
`track.json.gz` with `Content-Type: application/gzip` and no `Content-Encoding`, at most
8 MiB (8,388,608 bytes), declaring at most 64 MiB inflated in its gzip trailer. `GET`
returns it the same way. The server stores the bytes unchanged; on upload it checks only
the gzip header and that the file starts a JSON object, so clients must send a valid
track v1 whose `sessionId` matches the URL.

### Shared copies

`GET` returns the stored file only to the session's owner. Anyone else who may see the
session (public or unlisted) gets a shared copy built by the server, still a valid
track v1:

- GPS fixes inside the owner's privacy zones are removed, and only the columns
  `t lat lon spd crs hacc` are kept.
- A `privacyGap` event (`{"t": …, "type": "privacyGap", "data": {"index": …}}`) marks
  the first fix after removed fixes, and any kept fix whose line from the fix before it
  might pass through a zone. `index` is that fix's position in the shared GPS columns;
  readers must not draw a line from the fix before it. Match by index, not by `t`: fixes
  on both sides of a zone can share a timestamp.
- "Might pass through" covers any line a reader may draw between the two fixes: the
  great circle, or any path monotonic in latitude and in longitude the short way round
  (such as a straight line on a Mercator map, or linear interpolation in degrees). Readers
  must take the short way round across ±180°.
- Fixes beyond Web Mercator's latitude limit (±85.0511°) are left out, with a gap, since
  maps clamp them to their edge and would draw a line the check never covered. Readers
  must draw shared lines without simplification (MapLibre: `tolerance: 0`).
- Shared copies are built only for tracks up to 8 MiB inflated and 500,000 fixes; above
  that, others get 422 `track_too_large` and only the owner can download the track.
- `hr` is empty. Events are limited to `start`, `stop`, `pause`, `resume`, `lap`, `tack`
  and `gybe`, with no `data` except a numeric `durationS` on maneuvers.
- `summary` holds only the numbers the API shares with other viewers.

---

## GPX export

`GPXWriter` turns a track into a GPX 1.1 document (UTF-8). `waterkit-replay <path> --gpx
<out.gpx>` does the same from the command line, for a raw recording or a track file.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="MadeGood" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2" …>
  <metadata>
    <name>Sailing</name>
    <time>2000-01-01T12:00:00.000Z</time>
  </metadata>
  <trk>
    <name>Sailing</name>
    <type>sailing</type>
    <trkseg>
      <trkpt lat="10.00001" lon="-30"><ele>1.2</ele><time>2000-01-01T12:00:01.000Z</time><extensions><gpxtpx:TrackPointExtension><gpxtpx:speed>2.5</gpxtpx:speed><gpxtpx:course>45</gpxtpx:course></gpxtpx:TrackPointExtension></extensions></trkpt>
    </trkseg>
  </trk>
</gpx>
```

| Element | Content |
|---|---|
| `gpx/@creator` | `MadeGood`. |
| `metadata/name`, `trk/name` | The sport's name (`Sailing`, `Windsurfing`, `Motorboating`, `Kayak`, `Canoe`, `Stand-up paddle`), or a name the caller passes. |
| `metadata/time` | `startedAt`. |
| `trk/type` | The sport's wire name (`sailing`, `kayak`, …). |
| `trkpt/@lat`, `@lon` | Degrees (WGS 84), up to 7 decimals. |
| `ele` | Altitude, m, 1 decimal. Left out when the fix has none. |
| `time` | `startedAt + t`, ISO 8601 UTC with milliseconds. |
| `extensions/gpxtpx:TrackPointExtension` | Garmin's [TrackPointExtension v2](https://www8.garmin.com/xmlschemas/TrackPointExtensionv2.xsd) (`http://www.garmin.com/xmlschemas/TrackPointExtension/v2`), which Strava, Garmin Connect, GPXSee and most other readers understand. `gpxtpx:speed` is the receiver's Doppler speed in m/s (2 decimals); `gpxtpx:course` is the Doppler course in degrees true (1 decimal, 0 ≤ course < 360). Each is left out when invalid, and the block is left out when both are. |

Rules:

- **One track.** Every session is one `<trk>`. Heart rate, events and the analysis
  summary are not exported.
- **Time order.** Fixes are written sorted by `t`; fixes with the same `t` keep their
  stored order. Tracks may be stored out of order, so writers must not assume they are.
- **Invalid fixes are skipped:** a non-finite `t`, latitude or longitude, a latitude
  outside ±90° or a longitude outside ±180°.
- **Segments.** A new `<trkseg>` starts at the first fix at or after a `resume` event
  that follows a `pause` (a `resume` with no `pause` before it, or a `pause` that is
  never resumed, splits nothing). A new `<trkseg>` also starts when consecutive fixes
  are more than **30 s** apart (`GPXWriter.defaultSegmentGap`; callers can change it),
  so a signal loss is not drawn as a straight line. Fixes recorded while paused stay in
  the segment before the resume.
- **Text** (names, the creator) is XML-escaped (`& < > " '`), and characters XML 1.0
  does not allow are dropped. Numbers use `.` as the decimal separator and never an
  exponent.
- A track with no valid fixes is written as a `<trk>` with no segments.

---

## Local trim metadata

The trim store keeps one JSON file per session, named `<lowercase-session-id>.json`
in an app-owned directory outside the recording folders. A beginning/end trim uses
`{"version":1,"start":1.25,"end":5.5}`. An edit with interior cuts uses
`{"version":2,"keptSpans":[{"start":1.25,"end":5.5},{"start":7,"end":10}]}`.
Spans are ordered, strictly disjoint and positive in duration. Bounds are inclusive
and use seconds from the original recording start, so a fix or event exactly at
either cut boundary is retained. The store atomically replaces the file when an
edit changes. Restore Original removes it. The edit metadata stays on the device
outside the raw and track-v1 files.

The selected track's start date shifts by the lower bound. Its GPS, heart rate
and events use that shifted origin. Replay keeps the removed intervals visible on
this clock and skips them during playback. Total time sums the lengths of the
retained spans. GPS filtering, speed windows, lap ranges and interpolation start
afresh after each cut. Analysis carries forward an active manual pause from the
source clock and recalculates auto-pause and auto-laps from the retained samples.
Off-water proposals use the original recording clock. An accepted proposal
uses the same inclusive kept-span bounds as a manual cut.

Selected GPX writes each fix's timestamp from the original recording clock and
begins a new track segment after a cut regardless of GPS gap length. The track's
`extensions` contains one `mg:removedInterval` in namespace
`urn:madegood:gpx:edit:1` for every cut. Its `start` and `end` attributes are
numeric seconds from the GPX metadata start time. Readers that ignore the
extension still see separate track segments.

---

## Boundary pack v1

WaterKit's local off-water prototype reads a bounded synthetic `.mgwb` file. The first line is
`MGWB ` followed by eight lowercase hex digits and LF. The digits encode zlib-compatible
CRC-32 of the exact remaining bytes, including any final newline. The remainder is UTF-8 JSON.
The importer validates the entire file before offering evidence. CRC-32 covers accidental
corruption. The provenance fields are producer declarations.

- `manifest` requires `formatVersion: 1`, a nonempty `packID`, positive integer `revision`,
  a `provenance` object and finite nonnegative `uncertaintyMeters`. Provenance requires
  `kind: "synthetic"`, plus nonempty `source`, `revision` and `license` strings.
- `coverage` is the verified rectangle, with integer `westE6`, `eastE6`, `southE6`, `northE6`
  bounds in WGS84 microdegrees. Each span is at most one degree and greater than zero. The
  rectangle excludes the antimeridian and stays within 80 degrees of the equator.
- `coastalWater`, `inlandWater`, `docks`, `bridges` and `unverified` are required polygon arrays.
  Each polygon has an `outer` ring and a `holes` array. Vertices are `[longitudeE6, latitudeE6]`
  and edges are straight in these coordinates. Closure is implicit. Rings are simple, with
  unique vertices and no consecutive collinear triples. Holes are strictly inside the outer
  ring and disjoint from one another. All vertices lie within the coverage rectangle. Water is
  the union of its two layers outside masks and unverified areas.
- Limits are 256 KiB per file, 256 vertices per polygon including holes, and 4096 vertices total.

Clearance uses a distance floor of 110,000 m per degree of latitude and 110,000 m times the
cosine of the maximum absolute latitude of the rectangle per degree of longitude. For paths
inside coverage, these scales bound the WGS84 metric from below. Paths leaving the rectangle
must first reach its edge, which also caps the reported distance. The adapter also caps clearance
by every polygon ring, including internal seams and holes, then subtracts the combined source,
processing and quantization uncertainty and one millimetre for floating-point roundoff. Fixes
in or within that allowance of masks or water edges yield ambiguous evidence. Unverified areas
and the exterior and uncertainty band of coverage yield unknown, including where another layer
offers evidence. See the [local validation commands](off-water-suggestions.md#local-boundary-pack-prototype).

---

## Settings sync snapshot

The phone and watch apps send each other their per-sport settings as a flat dictionary
(the WatchConnectivity application context, of which only the latest is delivered),
built and applied by WaterKit's `SettingsSync`. Every snapshot is the sender's full
state, so a skipped one loses nothing.

Each per-sport key (`settings.<field>.<sport>`) has its own last-writer-wins stamp,
stored on the device in `settings.stamps`: a dictionary from key to `[revision, device]`.
The revision is a hybrid logical clock in milliseconds (`max(now, highest seen + 1)`);
stamps compare by revision, then device ID. A local edit stamps only the keys whose
values change. A return to the default removes the value and keeps a new stamp, so
"absent with a stamp" means "set to the default".

A snapshot carries:

- every stored per-sport value (values equal to their default are not stored),
- `settings.stamps`, the stamps of every key the sender has stamped,
- `settings.revision` and `settings.revisionDevice`: the newest stamp, for builds before
  per-setting versions.

Applying a snapshot takes each key whose stamp is newer than the local one (value or
default) and keeps every other key, including keys the snapshot has no stamp for. The
receiver sends its own snapshot back when it holds a key newer than the one received, or
one the sender has no stamp for; once both hold the same stamps nothing more is sent.

### Builds before per-setting versions

Those builds send only values and `settings.revision`/`settings.revisionDevice`, and
apply a snapshot with a newer (revision, device) by writing every key they know. A
snapshot without `settings.stamps` is read as stamping, with its revision, the first
per-sport fields (`speedUnit`, `distanceUnit`, `firstScreen`, `autoPause`, `saveWorkout`,
`distanceAlert`, `countdown`, `hidden`) of every sport plus any per-sport key it carries.
Because such a build takes the whole state of any newer snapshot, its snapshot wins its
keys only when it is newer than every stamp on the receiver; otherwise the receiver
answers with its own state and both end the same. On first launch of a build with
per-setting versions, every stored value gets the stored revision as its stamp (values
from before revisions get a new one). Settings at their default get no stamp: "never
written" loses to any stamp, so when both devices migrate, one's defaults never erase
the other's explicit values.

Each device lets a sport be hidden only while another stays visible, but crossing edits
can still hide every sport. When applying a snapshot leaves every sport hidden, the
receiver shows again the sport whose hide has the oldest stamp (no stamp counts as
oldest; ties follow the usual sport order) as a new local edit, and replies. Both devices
hold the same stamps by then, so both pick the same sport.

Limits while one device runs an older build:

- Sync between the two is whole-snapshot last-writer-wins for the keys the older build
  knows, as before: concurrent edits of different settings can lose the older one.
- A build that knows the Action button (#58) or the fuel estimate (#60) does not store a
  reset of such a key to its default, so its snapshot omits it, which looks the same as
  not knowing the key. The receiver keeps its value and the reset does not propagate.
  No value is lost, and only those builds are affected. A later edit of any other
  setting on the newer device sends a newer snapshot revision, so the older device takes
  the newer device's value back and the reset is undone there too. This affects only
  mixed builds and ends once both devices run a build with per-setting versions.

---

## Account export

Account exports use an unversioned ZIP layout with a `manifest.json` index and
session documents in `sessions/sessions-*.json`. Newly generated session documents
omit the legacy `wind` field. WeatherKit wind is fetched on shared session views
and stays out of the archive. Exported track files retain their original track format
and version. See [how export jobs work](self-hosting.md#account-export).

---

## Privacy

Both formats contain precise locations and times. Before a recording goes into
`fixtures/` or an issue, run `scripts/anonymize-track` on it. It moves positions to
a fake origin, keeping distances and bearings; shifts every timestamp to a fixed
date; and replaces the session ID. See `fixtures/README.md`.

The website's maps load tiles from OpenStreetMap (and OpenSeaMap when seamarks are on),
so those tile servers see the area being viewed and the viewer's IP address, as with any
tile map; the iPhone's maps do the same with Apple Maps.
