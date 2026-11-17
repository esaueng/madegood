# Metric definitions

How MadeGood computes each metric. The code is the reference implementation
(`packages/WaterKit`); this page says what it does and why, and changes with it. All
values are SI internally (m, s, m/s, degrees true) and converted only for display.

Live metrics come from `SessionEngine`, which runs on the watch or phone during a
session and only uses data it has already seen. Post-session analysis (Phase 2) can
revise some of them using the whole track.

## GPS cleaning

`GPSFilter` decides fix by fix whether to use a location. A fix is rejected when:

| Rule | Default |
|---|---|
| Its time is not after the last accepted fix | — |
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
  span a gap between fixes longer than itself. Live, windows end at each fix; after the
  session, windows may also start at a fix. At 1 Hz both give the same result. A
  single fix is never a max speed.

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
end it.

## Laps

A lap closes on the user's `lap` event or, if the sport profile sets an auto-lap
distance, when distance reaches the next whole multiple of it counted from the last
manual lap. Auto-laps are recorded as `lap` events with `{"auto": true}`. Each lap
reports its start and end time, moving time, distance, and average speed (distance
over moving time).

## Heart rate

Current heart rate is the latest reading. Average is the mean of the readings, and max
the highest. Readings that are not positive and finite are ignored.
