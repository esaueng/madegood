# Metric definitions

How MadeGood computes each metric. The code is the reference implementation
(`packages/WaterKit`); this page says what it does and why, and changes with it. All
values are SI internally (m, s, m/s, degrees true) and converted only for display.

Live metrics come from `SessionEngine`, which runs on the watch or phone during a
session and only uses data it has already seen. Samples with a non-finite time are
ignored. Session detail on the iPhone replays the recording through the same engine
(`SessionReplay`), so live and after-session values match, and adds analyses that need
the whole track: sailing maneuvers and wind, paddling splits, and strokes from the raw
recording.

## Where each metric is shown

| Metric | Watch and iPhone, live | iPhone session detail | Stored in track v1 `summary` (and so on the website) |
|---|---|---|---|
| Distance, moving time, elapsed time, average speed | yes | yes | yes |
| Max speed 2 s and 10 s | yes | yes | yes |
| Heart rate (current, average, max) | yes | yes | average and max |
| Heart-rate zones (all sports) | watch: current zone | iPhone: time in each zone | — |
| Laps | yes | yes | yes |
| Windsurf speed categories | yes | yes | yes |
| Strokes, stroke rate, distance per stroke, sides | yes | yes, from the raw recording | no |
| Paddling 1 km splits | no | yes (replay) | no |
| Sailing wind axis, VMG, tacks and gybes | yes | yes | no |
| Motorboat trip log, engine time, fuel estimate | yes | yes | no (the website shows the distance) |

The website shows what the summary stores, plus the track (map, speed and heart-rate
charts). Units are converted for display only. In the apps they are set per sport and
default ("Automatic") to knots and nautical miles for sailing, windsurfing and
motorboating, and km/h and km for kayak, canoe and SUP. The website uses the account's
single units setting (nautical by default).

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

## Sailing maneuvers

Session detail's Moments section lists tacks and gybes. It uses a session-wide
wind-from direction (degrees clockwise from true north): the one the user enters, or
else the track's own estimate (below). Without either, it asks for a direction. The
user's direction is used only in the open detail view.

With a direction, replay looks for a sustained course change across the wind axis with
a Doppler speed dip. An upwind crossing is a tack and a downwind crossing is a gybe;
with only the wind's axis known (below) they are listed as "Tack or gybe".
Each retained span is analyzed independently. Pauses, GPS gaps and unreliable course
or speed interrupt the evidence within a span. A reported course uncertainty greater
than 20° also interrupts the evidence.

| Rule | Value |
|---|---|
| Course | The receiver's course, median of three to remove single-fix spikes |
| Turn | More than 60° and less than 180°, crossing the axis, at most 20 s from the approach leg to the departure leg, at most 20° of counter-turn |
| Legs | At least three fixes over 3 s within a 12° band, either side of the turn |
| Speed dip | The lowest speed in the turn at least 10 % below the slower leg's mean |

Each maneuver reports:

| Value | Definition |
|---|---|
| Time | The estimated wind-axis crossing, interpolated between fixes |
| Duration | Approach-leg edge to departure-leg edge, s |
| Speed loss | 1 − lowest speed in the turn ÷ the approach leg's mean speed, % |
| Turn angle | Between the approach and departure legs' mean courses (3 s each), degrees |

Each result highlights the detector's approach-to-departure bounds and moves the replay
cursor to the crossing. Both use the displayed selection's clock.

## Sailing wind and VMG

**Wind estimate (PLAN §5).** Sailing time is binned by course over ground: 5° bins,
each fix weighted by the time to the next fix (at most 5 s), only at 1.0 m/s (about
1.9 kn) or faster and with the same run breaks as maneuvers. A leg's mass is the time
within ±12.5° of a bin. The estimate takes the pair of bins 70–110° apart with the most
combined mass, where each has at least 20 s and both together at least 60 s. Each leg's
direction is the time-weighted circular mean of courses within ±17.5°, and the wind is
the direction midway between the two legs.

The legs fix the wind's axis, not its side: two legs 90° apart are as consistent with
beating as with gybing downwind. A prior picks the side, the Open-Meteo direction when
the user has fetched it, but only when it lies within 60° of one end of the axis (and
so at least 120° from the other). A forecast further from both, across the axis, is
inconclusive and decides nothing. Without a side (no prior, or an inconclusive one)
the estimate is reported as an axis, and the analysis uses one end of it (as if the
legs were upwind) only to find axis crossings: the apps then never say upwind or
downwind, tack or gybe, or starboard or port, and show one maneuver count, |VMG| along
the axis and the angle to the axis. A direction the user enters is taken as resolved.

**Axis confidence** is the share of sailing time on the two legs, scaled by
min(1, shorter leg's time ÷ 120 s). It rates the axis only, not the side, and is a
heuristic for whether to show the estimate, not a probability. **Axis uncertainty**
(±) is the mean circular standard deviation of the courses within ±17.5° of each leg,
at least 2.5°.

**Accuracy.** No labelled real sailing recordings exist yet. `SailingWindTests` checks
the PLAN §5 targets (wind within ±10°, ≥ 95 % of maneuvers found, < 5 % false
positives) on synthetic beats and downwind runs with course noise, uneven tacks and
directions across north, with hand-computed VMG and tack totals. Real labelled
sessions still have to confirm them.

**VMG.** True wind angle (TWA) is the wind's direction relative to the course over
ground, positive with the wind over the starboard side (starboard tack). VMG =
Doppler speed × cos(TWA): positive upwind, negative downwind.

| Value | Definition |
|---|---|
| Upwind VMG | Time-weighted mean VMG while \|TWA\| < 80°, m/s |
| Downwind VMG | Time-weighted mean of −VMG while \|TWA\| > 100°, m/s |
| Pointing | Time-weighted mean \|TWA\| while upwind, degrees |
| Starboard / port tack | Time and Doppler distance (mean speed of each interval × its time) with TWA > 0 / < 0 |
| VMG along the axis | Time-weighted mean \|VMG\| while not reaching, m/s: the same whichever side the wind is on |
| Angle to the axis | Time-weighted mean of min(\|TWA\|, 180° − \|TWA\|) while not reaching, degrees |

These use the intervals between consecutive fixes in a run, with each interval's mean
speed and its first fix's course, at most 5 s long and at 1.0 m/s or faster. Intervals
that touch a maneuver's approach-to-departure range are left out. Reaching (80–100°)
counts toward the tack totals but neither VMG.

**Live.** The watch and iPhone run the same rules over the engine's accepted fixes so
far (raw course, as after the session), with the same run breaks, including a gap of
more than 5 s between accepted fixes. Every 10 s they re-estimate the wind (without a
prior, so only its axis is known) and look for maneuvers in the observations since a
minute before the previous scan. The shown axis follows the estimate while it stays
within 10°; a different axis replaces it only after winning six refreshes in a row with
at least 10 % more time on its legs, so two near-equal axes cannot alternate. Every
observation is rescanned when the shown axis has moved more than 10° since the last
rescan, at most once every 5 minutes, and once more when the session stops, so a turn
completed after the last refresh still counts. Live, a turn once counted is never
removed (counts only grow); session detail recomputes from scratch. The estimate
appears once both legs have their time, which on a beat is shortly after the first
tack. The live page shows the axis (both ends, and a line rather than an arrow), |VMG|
from the current speed (3 s mean) and smoothed course, the angle to the axis, and the
total of tacks and gybes. Manual pauses, GPS anchors and unreliable course break the
runs. After the session the analysis is one pass over the selection.

`waterkit-replay` prints the wind axis, the maneuver count and VMG along the axis for
sailing recordings (it has no prior).

### Open-Meteo

Session detail on the iPhone can fetch Open-Meteo's modelled 10 m wind for a sailing
session, only when the user taps "Compare with Open-Meteo"; the button says beforehand
that it sends the approximate area (~50 km) and dates. The watch never calls the
network. The result is shown beside the estimate and used as its prior. It is kept on
the phone keyed by the request (rounded position, dates, the session's hours and the
variables), so a selection trimmed to another area or day asks again.

Sent to Open-Meteo, with no API key, cookies or identifiers: the mean position of the
selection's fixes rounded to 0.5° (about 50 km; the models' grids are coarse anyway),
its UTC start and end dates (whole days), and the requested variables. Sessions that ended more than 7 days ago
use the historical archive API, newer ones the forecast API. The direction is the
speed-weighted circular mean of the hourly values from the hour before the start to
the hour after the end; the speed is their mean. Offline or on any error, the detail
keeps the track's own estimate and offers to try again.

## Start line

`StartLine` in WaterKit (`Stats/StartLine.swift`), shown on the sailing countdown screens.
Not for navigation: the GPS is on the wrist or phone, a few metres from the bow.

- **Pings.** Pressing Pin or Boat averages the fixes from 3 s before to 2 s after the
  press with accuracy ≤ 15 m; it needs at least two. Each fix is first moved to the press
  time along its own Doppler speed and course (not below 0.3 m/s, where course is
  noise), so a boat sailing past the pin pings where it was at the press. The average is
  weighted by 1/accuracy² on the unit sphere. Too few fixes: the ping fails (a failure
  buzz). The pin is the port end, the boat (committee) the starboard end, looking from
  the pre-start side.
- **Line.** Ends 10 m – 5 km apart. The whole line is kept for 6 h after its last ping
  (checked at each countdown start, every read, every ping and the gun; a ping after
  expiry drops the old end rather than reviving it), so later races off the same line
  reuse it. Saved ends are used again only once a fresh (≤ 5 s old by the countdown
  clock) and accurate (≤ 25 m) position is within 2 km of them; until then they are
  neither shown, checked nor recorded. Farther away they are ignored for that countdown
  but kept. The line in use is recorded with the session (`linePing` events,
  docs/formats.md).
- **Distance to the line.** Perpendicular distance to the line's great circle, exact on
  the spherical Earth used by `Geo` (no local projection, so it holds across ±180° and
  near the poles). Positive on the pre-start side (right of pin → boat), negative when
  over. "Outside ends" when the foot of the perpendicular lies beyond either end.
- **Time to the line.** Distance ÷ the velocity component towards the line from the
  current Doppler speed and course. None when over, not closing, or below 0.3 m/s.
- **Time to burn.** Countdown time left − time to the line: positive is early, negative
  late.
- **Bias.** With a wind estimate, degrees the line is off square to the wind at its
  middle, and which end is upwind (favoured); within 2° it is square. The countdown's
  estimate comes from its own sailing (the course histogram of "Sailing wind and VMG"),
  which knows only the axis; the wind is then taken from the course side of the line.
- **Countdown clock.** Times during the countdown are unix seconds derived from the
  monotonic clock through one anchor taken at the countdown's start. A fix's time is its
  age on arrival subtracted from its arrival on that clock, so a device clock change
  cannot make an old fix look fresh or move the gun.
- **OCS.** The gun is the countdown's deadline (moved by a sync) on that clock, however
  late the app handles it. The newest fix stamped at or before the gun (0.25 s
  tolerance) and at most 2 s older is moved to the gun along its Doppler speed and
  course (from 0.3 m/s). Over the line: "OCS: return". Within the fix's accuracy and
  heading for the line, or within it and too slow to trust the course: "Possibly OCS".
  No such fix: "OCS unknown", never a silent all-clear. A ping still being averaged at
  the gun is finished first with the fixes it has; one that fails then, or failed in
  the 15 s before the gun, is reported on the session screens. An over warning clears
  when a recorded fix is behind the line by more than its accuracy, when dismissed, or
  5 minutes after it appeared (on a timer, with or without GPS). Start now skips the
  check.

## Motorboating

- **Trip:** the session's distance (above), shown in nautical miles by default.
- **Log total:** live, the trip plus every saved motorboat session on the iPhone, leaving
  out the session in progress and any recording still being written; in session detail
  ("Log to date"), the trip plus every saved motorboat session whose recording started
  before it. Order uses the original recording start, so trimming never changes it.
- **Engine time:** moving time made of intervals whose mean Doppler speed (the mean of
  the two fixes' speeds, or the one known) is at least 1.0 m/s (about 1.9 kn). It follows
  the same pauses, auto-pause roll-backs and GPS anchors as moving time, so it never
  exceeds it. It is not stored in the session summary.
- **Fuel (estimate):** `burn under way × engine time + idle burn × (moving time −
  engine time)`, from rates the user enters in litres or US gallons per hour (stored as
  L/h; idle defaults to 0). Without an under-way rate there is no estimate. It is always
  labeled an estimate: actual burn depends on load, trim and sea state.

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
reports the same values, computed over the engine's accepted fixes.

**Planing time** estimates time above the user's Windsurfing → Planing speed
setting (default 5 m/s, about 9.7 kn). The setting syncs between iPhone and Watch and
is stored in m/s. Speed is linearly interpolated between consecutive accepted
Doppler readings. A run must stay above the threshold for at least 3 s, and the
whole run counts once it qualifies. The 3 s minimum filters out brief spikes
without a second speed threshold. Manual and auto-pauses, cuts, GPS re-anchors,
gaps over 5 s, and fixes without usable speed break a run. The percentage is
of active time with usable Doppler intervals, including observed time below
the threshold. It is blank without usable intervals. iPhone detail uses the
current setting, including for older sessions and trims. The Watch summary
uses the setting from the start of the recording.

**Estimated gybes** reuse sailing's course-over-ground detector, including its
stable approach and departure legs and Doppler speed dip. For windsurfing, the
two dominant headings may be 65–170° apart in the course histogram. They must
account for at least half of the course time observed at 3 m/s or faster. The
detector checks both possible ends of the wind axis and allows turns under
240° (sailing uses 180°), since a gybe from an upwind reach can take the longer
arc. If turns cluster around just one end of the axis, that end is assumed
downwind and those turns count. The count is blank when there is too little
evidence for the axis or qualifying turns cross both ends. This assumption can
mistake upwind tacks for gybes and miss turns on other headings or between
reciprocal reaches.
The count is independent of the user's planing threshold and has been checked
against synthetic tracks.

## Start countdown and distance alerts

These are cues, not metrics, but they follow fixed rules:

- **Start countdown** (per sport: off, 1, 3 or 5 minutes): recording starts when it
  reaches zero; the countdown itself is not part of the session. Haptics mark each
  whole minute and each of the last 10 seconds. **Sync** rounds the time left to the
  nearest whole minute, for matching a race start signal; with under 30 s left it
  starts at once.
- **Distance alert** (per sport: off or every 0.25, 0.5, 1, 2, 5 or 10 distance units):
  fires each time the session distance passes a whole multiple of the interval. A
  recalculation that lowers the distance never repeats an alert, and a jump past
  several multiples alerts once.

## Heart rate

Current heart rate is the latest reading. Average is the mean of the readings, and max
the highest. Readings that are not positive and finite are ignored.

**Heart-rate zones** apply to all sports. The default maximum of 190 bpm is a starting
point. Set your own maximum (60–250 bpm) and optionally change the four thresholds in
iPhone **Settings → Heart Rate Zones**. Maximum and thresholds sync independently with
Apple Watch. By default, zones 2–5 start at 60%, 70%, 80% and 90% of maximum, respectively.
Zone 1 covers all positive readings below 60%, and zone 5 includes readings above maximum.
Custom thresholds are increasing whole percentages. The watch shows the current zone
during recording while active and while the latest valid reading is at most 15 s old.

**Time in zones** is an estimate calculated when opening the iPhone session detail, using
the current settings. Each valid reading represents the interval until the next reading,
provided both readings are valid and at most 15 s apart. The interval ends early at a manual
or replayed auto-pause, and counting resumes with the first valid reading at or after
resume. There is no time credited before the first reading, after the last, through sensor
gaps, or across removed trim intervals. Sessions without a qualifying interval omit the
breakdown.

## Anchor alarm

The iPhone measures great-circle distance (m) and initial bearing (degrees true)
from the most recent position to the selected anchor point. Bearing is omitted at
the anchor itself. The swing radius is stored in metres and displayed in metres or
feet according to the motorboat distance setting. The circle is not for navigation.

A fix is confidently outside when its distance minus horizontal accuracy exceeds
the radius, using at least 5 m of accuracy for that comparison. With good GPS
(reported accuracy of 5 m or better), drift confirmation requires fixes more than
5 m beyond the selected swing radius. Drift is confirmed after three distinct
confidently outside fixes, regardless of how far apart they arrive. A confidently
inside fix (distance plus reported accuracy below the radius) resets the count
and clears the confirmed drift state.
A fix whose accuracy circle touches or crosses the boundary leaves the count
unchanged. Fixes with unknown accuracy, accuracy worse than 25 m, or locations
older than 15 s do not enter the calculation. These readings are live only and do
not change the session summary or track format.

The iPhone schedules a GPS backup alarm for 120 s after arming. Only usable fixes
that are confidently inside or overlap the swing circle before drift is confirmed
can renew it. After drift is confirmed, an overlapping fix preserves the GPS
fallback deadline. After the first eligible fix, renewals are coalesced to one
per 30 s of fix time. Each renewal sets a deadline 150 s after its fix, giving
the latest eligible fix at least 120 s and up to 150 s before the backup is due.
The app installs the replacement before cancelling the previous scheduled alarm.
Alarm changes and a once-per-minute foreground check restore missing coverage. An alarm that disappears before it
has been observed ringing is restored at its original deadline, or as soon as
AlarmKit can schedule it if overdue. Significant clock changes and foreground
checks reconcile both fixed system alarms against saved monotonic deadlines.

Use Stop on the system alarm or in the Anchor Alarm screen. Stopping the current
GPS backup snoozes it for 120 s. The next eligible fix can renew it immediately.
Stopping an older GPS backup leaves the current deadline in place.
Stopping the drift alarm schedules another alert after 120 s of elapsed time if
drift is still confirmed. A confidently inside fix clears the scheduled drift
re-alert when it can still be safely cancelled, and a new alert requires drift
to be confirmed again. Automatic cancellation requires more than 10 s until the
pending alarm is due, allowing for app preemption and AlarmKit processing time.
AlarmKit reads state and cancels in separate calls. If iOS suspends the app beyond
that margin between the calls, an automatic cancel can remove an alarm that has
just started ringing.

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

## Not computed yet

PLAN §5 lists these; they have no definition here until they ship:
Race start line (pinging the ends, distance and time to the line) and stroke-based
intervals. Apple Health's workout builder supplies calories.

