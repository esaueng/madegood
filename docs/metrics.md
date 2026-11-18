# Metric definitions

How MadeGood computes each metric. The code is the reference implementation
(`packages/WaterKit`); this page says what it does and why, and changes with it. All
values are SI internally (m, s, m/s, degrees true) and converted only for display.

Live metrics come from `SessionEngine`, which runs on the watch or phone during a
session and only uses data it has already seen. Samples with a non-finite time are
ignored. Post-session analysis (Phase 2) can
revise some of them using the whole track.

## GPS cleaning

`GPSFilter` decides fix by fix whether to use a location. A fix is rejected when:

| Rule | Default |
|---|---|
| Its time is not finite, or not after the last accepted fix | — |
| Latitude or longitude is missing or out of range | — |
| Horizontal accuracy is missing or worse than the limit | 25 m |
| Doppler speed is above the limit | 50 m/s (about 97 kn) |
| Doppler speed changed faster than the limit since the last accepted fix | 8 m/s² |
| The position moved further than the Doppler speed allows | see below |

**Jumps.** The step from the last accepted fix may be at most
`1.5 × max(speed now, speed before) × Δt + both accuracy radii + 20 m`. When neither
fix has a Doppler speed, the speed limit stands in for it.

**Recovery.** After 5 rejections in a row, or 30 s after the last accepted fix, the
next usable fix is accepted as a new anchor. The step to an anchor counts toward
neither distance nor moving time, so a relocation (or a bad first fix) cannot add a
phantom leg.

**Course over ground** is the receiver's Doppler course, smoothed with a circular
exponential filter (time constant 3 s) so it does not jump across north. It is only
updated at 0.5 m/s or faster, because course is meaningless when stopped.

## Distance

The sum of great-circle steps between consecutive accepted fixes while the session
is not paused (spherical Earth, about 0.5 % from WGS 84). Steps to an anchor fix are
left out.

## Speed

Speeds always come from the receiver's Doppler measurement, never from position
changes, which on a wrist are dominated by noise.

- **Current speed:** the mean Doppler speed of the accepted fixes in the last 3 s.
  It is blank when the newest fix with a speed is more than 5 s old.
- **Average speed:** distance divided by moving time.
- **Max speed (2 s, 10 s):** the best time-weighted mean of Doppler speed over a window
  of exactly that length, treating speed as linear between fixes. A window may not
  span a gap between fixes longer than itself. Windows end at each fix, live and after
  the session, and only GPS-filtered fixes count; `waterkit-replay` shows the same
  values. A single fix is never a max speed.

## Moving time and auto-pause

Moving time is the time between accepted fixes while the session is not paused.

Auto-pause is on by default for kayak, canoe and SUP, and off for sailing,
windsurfing and motorboating, where drifting and waiting for wind are part of the
session.

| Setting | Default |
|---|---|
| Pause when speed stays below | 0.4 m/s for 10 s |
| Resume when speed stays at or above | 0.8 m/s for 3 s |

Between 0.4 and 0.8 m/s the state does not change, so drifting does not flicker
between paused and moving. A confirmed pause is dated back to the first slow fix: the
time and distance since then are removed. A confirmed resume is dated back to the
start of the interval in which the speed first rose: the time and distance since then
are added. The engine records these as `pause` and `resume` events with
`{"auto": true}`.

A manual pause stops all accounting until a manual resume, and auto-resume does not
end it. After a manual resume, accounting restarts from the next fix: the interval
that spans the resume is not counted.

Hold timers only run on observed fixes. After a re-anchor (a long GPS gap or recovery
from rejected fixes) they start again, so an unobserved gap can neither pause nor
resume a session. An auto-pause is never dated back past the start of the current lap,
so closed laps keep their totals.

## Laps

A lap closes on the user's `lap` event or, if the sport profile sets an auto-lap
distance, when distance reaches the next whole multiple of it counted from the last
manual lap. Auto-laps are recorded as `lap` events with `{"auto": true}`. Each lap
reports its start and end time, moving time, distance, and average speed (distance
over moving time).

## Paddling replay splits

Kayak, canoe and SUP replay reports successive 1 km splits from the selected track.
Workout laps remain separate. Manual laps and workout auto-laps do not reset the
split counter. The engine's accepted GPS steps and confirmed moving intervals supply
split distance and time. Steps to a new GPS anchor and steps longer than 5 seconds
are left out, matching replay's route breaks. The workout totals can include steps
between fixes more than 5 seconds apart when the GPS filter did not re-anchor.

A complete split ends where accumulated distance crosses 1,000 m, interpolating time
in proportion to distance along the last step. A final positive-distance remainder is
reported as incomplete and ends at the last contributing fix. Average speed is
distance over moving time. The result uses metres and seconds. Format distance and
average speed with the selected sport's display units without changing split boundaries.

Each result exposes its index, completion flag, exact elapsed bounds and contributing
moving ranges. Replay can seek to the lower bound and highlight each moving range
separately, preserving gaps between spans. A middle cut ends the current moving range
but keeps the same split counter. Time and distance from the cut do not contribute.
The bounds use the selected track's clock, including when a trim rebases it. Split
results are computed for replay and are absent from the saved summary. Stroke-based
intervals are not built yet.

## Strokes

Kayak, canoe and SUP strokes come from wrist motion (the raw `motion` stream).
`StrokeDetector` is causal and streaming: the watch and iPhone run it live, and
`StrokeAnalysis` runs it over a whole recording afterwards. Tracks do not keep motion,
so post-session strokes need the raw recording.

| Step | Definition |
|---|---|
| Resampling | Samples are averaged into 40 ms bins (25 Hz), whatever the sensor rate. When the time between two samples is at most 0.2 s, any empty bins are interpolated between the bins either side (never held at the last value); a longer gap restarts the filters, the main axis and the rate |
| Signal | Rotation rate (rad/s) and user acceleration divided by 4 m/s² per rad/s, six channels |
| Band-pass | 0.3–3 Hz per channel (second-order Butterworth high-pass and low-pass) |
| Main axis | First principal component of the filtered channels over the last 3 s, refreshed every 0.5 s: the eigenvector with the largest eigenvalue of their covariance, by the Jacobi method, so a change of movement plane is always found; the previous axis only keeps the sign. After a restart the axis is found afresh and detection runs over the bins that waited for it. PLAN §5 suggests 5 s; 3 s follows a side switch within about a stroke |
| Cycle | A positive lobe of the projected signal above max(0.25, 0.5 × running RMS (3 s time constant)), ended by a swing below −0.3 × that threshold. The peak time is refined with a parabola through the top three bins |
| Minimum gap | Peaks closer than max(0.33 s, 0.45 × median recent period) are one cycle |
| Strokes | Kayak: two per wrist cycle (left and right). Canoe and SUP: one |

**Stroke rate (SPM).** From the last six cycle periods: the mean, leaving out periods
below 0.6× or above 1.6× their median (a missed or split cycle). An interval longer
than 4 s is a pause and does not count. Live, the rate needs three cycles in a row and
blanks once the last cycle is older than min(4 s, 2.5 periods) plus one period. After
the session, the rate over time uses up to four periods per point, and the average is
strokes in counted periods over their total time.

**Distance per stroke.** Distance (moving, as above) over stroke count. Shown in metres
with one decimal, or feet with statute-mile units.

**Sides (canoe, SUP).** Each cycle's mean gravity direction in the device frame. A cycle
more than 40° from the current side's direction is a candidate; three candidates in a
row, each within 30° of their mean, confirm a switch, and those cycles move to the new
side. Side 0 is the side paddled first: the watch cannot tell left from right. Side
balance is the share of strokes on side 0.

**Pauses.** A manual pause stops stroke counting, like all other accounting: a stroke
whose time (a cycle's peak, or kayak's inferred second stroke) falls in [pause, resume)
does not count, whenever its cycle is confirmed, and no period spans a pause. Auto-pause (events with `{"auto": true}`) does not stop counting:
paddling slowly below the auto-pause speed is still paddling.

**Clock.** Detection runs on device uptime, the motion sensor's own clock, live and after
the session, so a wall-clock correction cannot reorder strokes, pauses or the rate's
freshness. After the session, the user's pause and resume events (stored in wall time) are
placed on the uptime clock by walking the clock anchors in recorded order: each event goes
to the first anchor segment, from the previous event's on, where it does not fall before
that event or after the next anchor. Results are then converted to session time with the
anchors, like the motion stream.

**Trims.** Kayak cycles are expanded into their two strokes first, then each stroke is kept
if its own time is inside a retained range. Rates use the cycles inside the retained
ranges, and a period counts only when both of its ends are in the same range.

**Accuracy.** No labeled paddling recordings exist yet, so the PLAN §5 targets (count
within ±3 %, rate within ±2 SPM) are checked in `StrokeDetectorTests` against
`PaddleMotionSimulator`: synthetic wrist motion with noise, harmonics, per-cycle
amplitude and period jitter, pauses, rate changes, side switches, sensor gaps and 50 or
100 Hz sampling. Labeled real sessions still have to confirm them.

## Sailing replay maneuvers

The iPhone's Moments section uses a session-wide wind-from direction entered in
degrees clockwise from true north. This input is optional and lives in the open
detail view. With a direction, replay looks for a sustained course change across
the wind axis with a Doppler speed dip. An upwind crossing is a tack and a
downwind crossing is a gybe. Each retained span is analyzed independently. Pauses,
GPS gaps and unreliable course or speed interrupt the evidence within a span.
A reported course uncertainty greater than 20° also interrupts the evidence.

Each result highlights the detector's approach-to-departure bounds and moves
the replay cursor to the estimated wind-axis crossing. Both use the displayed
selection's clock. The results require wind and sufficient track evidence and
live in the detail view alongside the wind input.

## Windsurf speed categories

Windsurfing sessions track the speedsurfing categories from PLAN §5, live on the watch
and phone and again in session detail. Both run the same streaming code over the
engine's accepted fixes, so the results match. Every category uses Doppler speed,
never position changes; position is used only for alpha's start-to-end check.

Speed is linear between fixes, so Doppler distance over a span is the trapezoid
integral of speed. Every span ends at a fix; its start is interpolated, between fixes
if needed. A span never crosses an interval of more than 10 s between fixes (the
2 s window: 2 s) or a removed interval. Exact ties keep the earlier span.

| Category | Definition |
|---|---|
| 2 s | Best 2 s mean speed: the session's max 2 s speed |
| 10 s | Best 10 s mean speed: the session's max 10 s speed |
| 5 × 10 s | Mean of the five 10 s windows that do not overlap (they may touch; 1 µs of rounding counts as touching) with the highest total. Blank until five fit |
| 100 m, 500 m, nautical mile | Distance over the shortest time to cover 100 m, 500 m or 1852 m of Doppler distance |
| 1 hour | Doppler distance in the best 3600 s window, over 3600 s, including slow stretches |
| Alpha 500 | The fastest 500 m span whose start position is within 50 m of the fix where it ends. The start position is interpolated between fixes, the short way round across the antimeridian. It may start at a GPS re-anchor, where position jumped, but not before it, even when the anchor fix has no speed (speed is then interpolated across it) |

Pauses do not stop the categories, as for the max speeds; GPS gaps do. `waterkit-replay`
reports the same values, computed over the engine's accepted fixes. Planing time
and gybe count (PLAN §5) are not computed yet.

## Heart rate

Current heart rate is the latest reading. Average is the mean of the readings, and max
the highest. Readings that are not positive and finite are ignored.

## Session summary

Track v1 stores the analysis as `summary`, with `analyzerVersion` (currently `1.1.0`,
bumped whenever a definition on this page changes; 1.1.0 added the windsurf keys):

| Key | Meaning |
|---|---|
| `distance` | Distance, m |
| `movingTime`, `elapsed` | Moving time and total time, s |
| `averageSpeed`, `maxSpeed2s`, `maxSpeed10s` | m/s; left out when unknown |
| `heartRateAverage`, `heartRateMax` | bpm; left out without heart rate |
| `best5x10s`, `best100m`, `best500m`, `bestNauticalMile`, `best1h`, `alpha500` | Windsurfing only, m/s; left out until the session has a span that qualifies (see "Windsurf speed categories") |
| `laps` | Each lap's `start`, `end`, `distance`, `movingTime` and `auto`; empty with no laps |

The track's events are the user's events plus the regenerated auto-pause, auto-resume
and auto-lap events.

