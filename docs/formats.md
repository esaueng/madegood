# File formats

MadeGood has two on-disk formats. Both are versioned contracts: WaterKit
(`packages/WaterKit`) is the single implementation, and the recorder app writes files
through the same types the readers use.

| Format | Used for | Leaves the device? |
|---|---|---|
| **Raw recording v1** | Research and algorithm work: every sensor stream at full rate | Only when the user shares it (AirDrop/Files), or with an opt-in "contribute data" setting |
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

---

## Raw recording v1

A session folder, zipped for sharing:

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

Every line has `ts`, the sensor's own timestamp, stored as the sensor reported it:

| Streams | `ts` clock | Source |
|---|---|---|
| `gps`, `hr`, `heading`, `events` | Unix time, s (wall clock) | `CLLocation.timestamp`, HealthKit sample start date, `CLHeading.timestamp`, `Date()` |
| `motion` | Device uptime, s (time since boot, not counting sleep) | `CMLogItem.timestamp` |
| `clock` | Both (see below) | `Date()` and `ProcessInfo.systemUptime`, read together |

Clock anchors pair the two clocks. `meta.clock` is taken at the start; the recorder
appends another anchor to `clock.ndjson` every 60 s and whenever the system clock
changes. Readers convert an uptime value with the latest anchor at or before it:

```
unix = anchor.unix + (uptime - anchor.uptime)
```

Session time is `t = unix - meta.startedAt`. WaterKit's `RawSessionReader` does this
conversion; files never store `t`.

### meta.json

```json
{
  "format": "madegood-raw",
  "version": 1,
  "sessionId": "6F1C2A3E-8A5B-4C1D-9E2F-0A1B2C3D4E5F",
  "sport": "kayak",
  "startedAt": 1809165600.0,
  "endedAt": 1809169200.0,
  "clock": { "unix": 1809165600.0, "uptime": 5000.0 },
  "device": { "kind": "watch", "model": "Watch7,5", "os": "watchOS 26.1" },
  "app": { "version": "0.1.0", "build": "1" },
  "requestedRates": { "motion": 100, "gps": 1 }
}
```

| Field | Notes |
|---|---|
| `format`, `version` | Always `madegood-raw` and `1`. |
| `sessionId` | Device-generated UUID, also used as the track's session ID. |
| `sport` | One of `sailing`, `windsurfing`, `motorboating`, `kayak`, `canoe`, `sup`. |
| `startedAt` | Unix time of the session start, s. |
| `endedAt` | Unix time of a clean stop. Absent if recording stopped unexpectedly. |
| `clock` | The first clock anchor. |
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
{"ts":5000.01,"ax":0.12,"ay":-0.3,"az":0.05,"gx":0.0,"gy":0.0,"gz":-9.80665,"rx":0.1,"ry":0.0,"rz":-0.2,"qx":0.0,"qy":0.0,"qz":0.0,"qw":1.0}
```

| Fields | Meaning | Unit |
|---|---|---|
| `ts` | uptime | s |
| `ax ay az` | user acceleration (gravity removed) | m/s² (CoreMotion's g × 9.80665) |
| `gx gy gz` | gravity | m/s² (g × 9.80665) |
| `rx ry rz` | rotation rate | rad/s |
| `qx qy qz qw` | attitude quaternion | unitless |

**hr** (HealthKit heart-rate samples): `{"ts":1809165603.0,"bpm":99}`, where `ts` is the sample's start date.

**heading** (`CLHeading`): `{"ts":…,"mag":10.0,"true":12.0,"acc":5.0}`. All values are in
degrees. `true` is left out when no location is available.

**events**: `{"ts":…,"type":"mark","data":{…}}`. Types: `start`, `stop`, `pause`,
`resume`, `mark`, `lap`, `mob`, plus analysis types such as `tack` and `gybe`. Unknown
types are kept as they are. `data` is optional and free-form.

**clock**: `{"unix":1809165660.5,"uptime":5060.0}`.

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

Writers round values to keep files small. Rounding never matters for analysis,
because the raw recording keeps full precision:

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

## Privacy

Both formats contain precise locations and times. Before a recording goes into
`fixtures/` or an issue, run `scripts/anonymize-track` on it. It moves positions to
a fake origin, keeping distances and bearings; shifts every timestamp to a fixed
date; and replaces the session ID. See `fixtures/README.md`.
