# Watch-to-iPhone recording transfer

How finished recordings get from the watch to the phone, why it works this way, and how to
test it on devices. The protocol and its invariants are in the header comment of
`apps/apple/Shared/Sources/Recorder/RecordingTransfer.swift`; parts are in `TransferParts.swift`;
timing and sizing decisions are in `TransferPolicy.swift` (unit-tested on iOS).

## What we measured

On an iPhone (iOS 27.2.1) and an Apple Watch Ultra (watchOS 26.6.1):

- A 42-minute kayak session is about 40 MB: motion 35 MB (100 Hz), heading 3.9 MB, the rest small.
- `WCSession.transferFile` sends one file at a time, at roughly 2 MB/min with the watch app open.
- With the watch app in the background, a whole-file 35 MB transfer sat at 0% for 32+ minutes.

## Invariants

These never change:

- The watch deletes a recording only on a live phone acknowledgement that lists every
  recording file at the same size.
- The phone acknowledges only what it has stored durably.
- The recording in progress is never sent or deleted.
- Raw format files are never changed. Parts are copies.
- The watch never calls the API.

## Keeping the transfer moving in the background

Large files go in 1 MiB parts. The watch keeps a window of parts queued and tops it up as
parts finish. A suspended app is not told when a transfer finishes, so finished transfers
alone cannot top up the window. Three things keep the queue going:

1. **Acknowledgements wake the watch app.** The phone acknowledges every stored file or part
   with `transferUserInfo`, which watchOS delivers to a suspended app as a WatchConnectivity
   background task. Every acknowledgement that does not complete the recording sends the
   watch round again, which queues the parts the phone lacks and that are not in flight. The
   SwiftUI `.backgroundTask(.watchConnectivity)` handler keeps the task open until the
   session is active, `hasContentPending` is false, and the work it started (handling
   acknowledgements and the sends they queued) has finished, or until 20 s pass
   (`TransferPolicy.backgroundWorkDone`).
2. **Background app refresh.** While any finished recording waits, the watch keeps one
   background refresh scheduled with `WKApplication.scheduleBackgroundRefresh`, whose
   `userInfo` is the `.appRefresh(_:)` identifier. It asks for 15 minutes ahead, or sooner if
   a retry is due (`TransferPolicy.nextRefresh`). The refresh sends what waits, restarts
   transfers that have been stuck for 15 minutes, and asks for the next refresh. A request
   that fails is made again right away, up to 3 times, while the process still runs. After
   that it is asked for at every send, every WatchConnectivity wake, and whenever the app
   moves to the background or the foreground (and after 60 s if the process keeps running).
   If watchOS keeps refusing, the next WatchConnectivity delivery or the next time the app
   is opened resumes sending.
   `BGTaskScheduler` is unavailable on watchOS (checked in the watchOS 27.2 SDK headers).
3. **A larger window.** The window grows from 10 to 32 parts when the watch has room (see
   below). At about 2 MB/min that is about 16 minutes of sending, longer than the refresh
   interval, so the queue should not run dry between wakes.

watchOS decides how often a background app gets these wakes. An app with a complication on
the active watch face gets more of them. Nothing here can force progress on a watch that
gives the app no background time. The watch app moves fastest while it is open.

## The iPhone in the background

- `MadeGoodApp.init` sets the session delegate and activates the session at launch, before
  any scene exists. This also covers launches iOS makes in the background. Storing and
  acknowledging run entirely on the WatchConnectivity delegate queue, so nothing waits on the
  UI.
- Each received file asks for background time with `ProcessInfo.performExpiringActivity`
  (`BackgroundTime`) and waits up to 2 s for the answer. The incoming file is moved into
  place whatever the answer, because WatchConnectivity deletes it when the callback
  returns. A join starts only while the time is held, and it stops between parts if the
  time runs out. Its staged copy is then removed and its parts stay. Placing a joined file
  is one rename, and acknowledgements list only what is in place, so running out of time
  never leaves a half-placed file and never acknowledges one.
- Joins left over (out of time, or the app was stopped) are finished and acknowledged at
  the next file, at the next activation, and when the app comes to the foreground
  (`finishInterruptedJoins`). Until then, the acknowledgements list the parts, not the file.
  So the watch sends `meta.json` on its own, and that `meta.json` brings the phone back to
  the join. A staged copy left by a stopped app is removed at the next launch
  (`RecordingStore.removeStaleStagingFiles`).
- SwiftUI's `.backgroundTask(.watchConnectivity)` is not available on iOS, so the phone has
  no equivalent of the watch's task.

## The fast path over `sendMessageData`

While the watch app is open and the phone is reachable, the watch sends what the phone lacks
by message instead of queuing more file transfers. `transferFile` stays the fallback, and the
only path in the background. The code is `MessageTransfer.swift` (pure, unit-tested on iOS)
and the "fast path" section of `RecordingTransfer.swift`.

An earlier study argued against it: `isReachable` on the watch needs the app on screen, so
it does nothing for the background case, and no SDK document says messages are faster than
files. Both still hold. It is built because opening the watch app is the one thing a user
can do to hurry a recording along, and `transferFile` stays at about 2 MB/min even then.
Whether messages beat that is measured on devices (step 7 below); the log gives the numbers.

### When it runs

All of these, checked before every message (`MessageTransfer.mayUse`):

- The watch app is the frontmost app: scene phase `.active` or `.inactive` (wrist lowered).
  Any background phase means files only.
- The session is activated and `isReachable`.
- The phone app says it takes chunks: it puts `messageTransfer: 1` in its application
  context, next to `rawVersions`. A phone build without it has no handler, so the watch never
  tries; nothing changes for older phone builds.
- It has not been turned off for the process (messages too large at every chunk size), and
  no pause after a failure is running.

While these hold, the fast path chooses what is sent: a send queues no new file transfers,
and file transfers already queued carry on. When any stops holding, every waiting recording
is sent again through the normal file path (`sendAllPending`).

### Chunks

- A unit is what the file path would send: a whole file up to 1 MiB, or one 1 MiB part
  (the same `file|total|partSize` layout). The fast path sends one unit at a time, as
  chunks, each waiting for the phone's reply before the next goes. The reply is the flow
  control: one message in flight.
- **Chunk size.** The limit for a message is undocumented (`WCErrorCodePayloadTooLarge`,
  7009, exists; reports put it near 64 KB). The first chunk is 60 KiB of data plus a header
  of a few hundred bytes, under 64,000 bytes in all (a test checks this for the largest
  header). On 7009 the size halves (30, 15, 7.5, then 4 KiB) and the same chunk goes again;
  the size that worked is kept for the process and shown on the watch's diagnostics. If
  4 KiB is too large, the fast path is off until the app is relaunched, and files carry on.
  A 1 MiB part is 18 messages at 60 KiB.
- **Frame.** `MGT1`, a 4-byte header length, a binary property list header (session ID,
  file, the part's metadata with the same keys as a file transfer's, the unit's length, its
  CRC-32 and the chunk's offset), then the chunk's bytes.
- **Phone.** A chunk is written at its offset into a staging file per unit,
  `.messages/<file>~<layout>.<index>~<crc>` in the recording folder (`.messages` is never a
  recording file, so listings, exports and acknowledgements ignore it). The reply says how
  many bytes of the unit the staging file holds (`have`). Once it holds all of them, the file
  is synced to disk, checked against the unit's length and CRC-32, then handed to the same
  store path as a file transfer: `TransferParts.store` for a part, the staged rename for a
  whole file, `meta.json`'s version check, then joining and the `transferUserInfo`
  acknowledgement listing every file. The reply says `done` only after the store; the join
  and acknowledgement follow, so a long join does not time out the reply.
- **Watch.** A `done` reply counts like a file transfer that finished: the unit is handed
  over (`handoverGrace`) until the acknowledgement says what the phone holds. A queued file
  transfer of the same unit that has not started (no progress, not transferring) is then
  cancelled, since the phone stored its content; one that has started is left alone.
  Deleting still needs the acknowledgement that lists every file at the watch's size.

### How the two paths share the work

- A unit is never sent by message while its file transfer is moving (transferring, or any
  progress), or while a transfer's callback is not handled yet (`Submitted`).
- File transfers queued but not started are taken last, after everything no file carries,
  and the last queued first, so the one the file queue starts next is the last the fast path
  takes. This is what makes opening the app help when the window of 32 parts was queued in
  the background and is not moving: the fast path works from the far end of the queue.
  If the file queue starts a part the fast path is sending, both arrive; the second is kept
  as "already had" and costs only link time.
- The unit the fast path is sending is in flight for the file path, as long as a message
  went or a reply came in the last 60 s (`MessageTransfer.claimGrace`). So after the fast
  path stops, a send does not queue that unit as a file while its last message may still
  land, and a callback that never comes does not block it for longer.
- `meta.json` stays last on both paths (`units` and `MessageTransfer.order`).
- All of this runs on the watch's send queue, the same serial queue as file sends, so
  choosing what goes by message and queuing files never race.

### When reachability drops mid-part

The message in flight fails with `WCErrorCodeNotReachable` (or the next chunk sees
`isReachable` false, or the app leaves the screen). The run stops, every waiting recording
goes to the file path, and the unit is queued as a file once its claim lapses (at once if the
error came). The phone keeps the staging file. If the fast path takes the same unit again,
its first chunk goes from offset 0, the reply says how much the phone holds, and the rest
continues from there: one repeated chunk, not the whole part. If the file arrives first, the
phone stores it and removes the staging file.

Other failures (a reply timeout, delivery failed, the phone refusing a chunk, an unreadable
reply, three replies in a row that do not move forward, no answer for 60 s) also stop the
run and pause the fast path: 30 s, doubling to 30 min while failures continue
(`TransferPolicy.retryDelay`), reset by a unit delivered. Not reachable is no failure: the
fast path resumes as soon as the phone is reachable again.

### Duplicates

Every way a unit can arrive twice is harmless:

- A chunk sent again (its reply was lost) is not written again; an overlapping chunk (after
  the chunk size changed) adds only the new bytes; a chunk past what the phone holds is not
  written, and the reply brings the watch back.
- A unit the phone holds already (as a stored part, or the joined file in place at the
  part's total size, or a whole file at its length) is answered `done` without writing.
- A part stored by both paths is kept once (`TransferParts.store` returns "already had").
- Staging files are removed when the part or file is stored by either path. Staging names
  carry the layout and CRC, so chunks of different content or layout never mix.

### What is still unknown

- Throughput. With one chunk in flight, a part costs 18 round trips. Pipelining several
  chunks is possible later if the round trip, not the link, turns out to limit it.
- The real message size limit, and whether it differs by watch or OS version. The log says
  when a size was too large.
- Battery and radio cost while sending by message. It runs only while the app is open.

## Window and part size
## Window and part size

- **Part size stays 1 MiB.** At about 2 MB/min a part takes about 30 s, so an interruption
  costs at most about 30 s of sending. Each part is acknowledged separately, which gives the
  watch a wake about every 30 s while transfers move. Larger parts would make those wakes
  rarer and each loss bigger. Smaller parts would add per-transfer overhead and more wakes
  than watchOS is likely to grant. Changing the size also changes the layout of files
  already partly sent (the phone drops the other layout's parts), so it should change only
  on evidence. The per-part acknowledgements in the log give the per-part time to measure
  it.
- **The window is 32 parts, limited by free space** (`TransferPolicy.window`). It queues as
  many parts as fit above 512 MiB of free space, and never fewer than 2, so a nearly full
  watch still makes progress. The cost is up to 32 MiB of slice copies per waiting
  recording. Each slice is removed when its transfer finishes. Slices that no transfer
  uses any more (after a restart or a cancellation) are removed before the next send
  (`TransferParts.staleSlices`).

## Never stuck for good

| Situation | What recovers it |
|---|---|
| A transfer fails (link drops, phone app not installed, timeout) | A retry after a backoff: 30 s, doubling to 30 min (`TransferPolicy.retryDelay`). One retry is pending per recording, so many parts failing together count once. Until it is due nothing of the recording is queued (only "Send again" overrides), and a part queued before the failure that finishes during the wait does not clear the count. Retries are kept across launches, so a relaunch during the wait neither sends at once nor starts the count over. The next refresh covers it if the app is suspended. |
| A part is delivered but its acknowledgement is slow or lost | Not sent again for 10 min (`handoverGrace`), so the window does not cycle through the same parts. After that it goes again, and the phone keeps its copy. |
| A transfer stays queued and never moves, or stops partway | Restarted by the launch or the next background refresh once it has been queued for 15 min without starting, or has sat at the same progress for 15 min (`shouldRequeue`). Progress is kept across launches, so separate background wakes can tell flat from new. A transfer that is moving is never cancelled. |
| The phone app is not running | Transfers wait in WatchConnectivity. The phone receives them at its next launch or background launch. |
| The watch restarts | Transfer times are stored in the metadata, so stuck detection still works. Leftover slices are removed. The phone's holdings are kept on disk. |
| The phone loses or deletes files it acknowledged, or the phone app is reinstalled | The watch's saved holdings are stale. When they claim everything, `meta.json` goes alone, and its live acknowledgement says what the phone really holds. The rest is then sent. Deletion needs a live list. |
| The watch app is reinstalled | Its recordings are gone with its container. Nothing is left to send. |
| A join on the phone is cut short | Finished and acknowledged at the next activation. |
| `meta.json` acknowledged while the last parts are in flight or handed over | No longer sent again on each acknowledgement. It used to go back and forth until the parts arrived. |
| A message gets no reply or error, or the phone stops being reachable mid-part | The run stops (after 60 s at most), the unit and everything else waiting go as files, and the phone keeps the bytes it has for a later run by message. |
| Messages fail while the app is open | The fast path pauses (30 s, doubling to 30 min) and files carry on meanwhile. |
| The phone app cannot read the raw version | Not sent, and no refreshes are asked for. The watch asks the user to update the phone app. |

## Design note: sending during the recording

Raw streams are append-only gzip: one member per flush, and bytes before the last flush
never change (`docs/formats.md`). So whole 1 MiB stretches of `motion.ndjson.gz` are final
long before the session ends, and they could go while the user is still on the water. The
workout keeps the watch app running, and `isReachable` is often true. That would leave only
the tail to send at the end. What it would take:

- **A layout that does not depend on the total size.** Today a part's layout key includes
  the file's final size, which is unknown while recording. Parts sent early would be keyed by
  file and part size alone, with the total fixed by a final "closing" message. The phone
  would join once the closing message and every part up to it are held. That is a protocol
  change (a new acknowledgement field), and an older phone build must keep working: the
  watch would send early parts only to a phone that advertises support, the way
  `rawVersions` works.
- **Only bytes before the last flush.** The recorder would expose its flushed length per
  stream. Parts end at or before it.
- **"Never sent while recording" changes meaning.** The invariant becomes "never deleted
  while recording, and never sent past what is flushed". The delete rule does not change: a
  live acknowledgement listing every final file at its final size.
- **Battery and radio during the session.** The radio is already busy with mirroring and
  heart rate. Sending would need to back off, for example to every few minutes, or only
  while the link is otherwise idle.

This is not implemented. It would change the transfer protocol, it needs measurements on
devices, and it overlaps the separate work on making raw recordings smaller.

## Device test steps

The simulator does not deliver WatchConnectivity files, messages or background tasks, so
these need a paired iPhone and watch:

1. **Background progress.** Record a session of 20 minutes or more, stop it, and lower your
   wrist so the watch app goes to the background. Open the iPhone app's History once, then
   lock the iPhone. After 20–30 minutes, open About → iPhone → Waiting to send on the
   watch. The log should show "iPhone holds … parts of motion…" entries with times spread
   across the period, and "Queued …" lines between them. Check that "Next wake" shows a time.
2. **Refresh wake.** Turn the iPhone's Bluetooth and Wi-Fi off with the recording partly
   sent, keep the watch app in the background for 20 minutes, then turn them back on. The
   log should show "Woke in the background with 1 recording to send", and, if the watch
   noticed the failures, "sending again in …" lines with growing waits.
3. **iPhone in the background.** Force-quit the iPhone app, then finish a session on the
   watch. Without opening the iPhone app, wait for the watch's log to show "iPhone holds …".
   That shows the phone was launched in the background to receive. Then open History and
   check that the recording is complete.
4. **Interrupted join.** Force-quit the iPhone app at the moment the last motion part
   arrives (it is hard to time; repeat a few times). Relaunch it. The phone's log should show
   "Joined motion.ndjson.gz from N parts" and "Confirmed to watch" within a second of
   launching.
5. **Phone reinstall.** With a recording partly sent, delete and reinstall the iPhone app.
   Open it. The watch should send `meta.json` alone, then the whole recording again, and
   delete it only after the phone lists every file.
6. **Rate (files).** The baseline is the 2 MB/min above. To measure files again with the
   watch app open, use an iPhone build from before the fast path (the watch then sends files
   only, step 10) and note the times of successive "iPhone holds" lines: the interval per
   1 MiB part is the file rate.
7. **Rate (messages).** Finish a 20-minute session with both apps open and the iPhone
   nearby. About → iPhone → Waiting to send should say "Sending by: Messages". The log shows
   "Sent motion.ndjson.gz part … by message: 1048576 B in 18 messages, … s" per part. Compare
   those seconds with step 6, and check that the recording completes and is removed from the
   watch. Note the message size shown: if it is below 60 KB, a size was too large (the log
   says which).
8. **Reachability drop mid-part.** While parts go by message, walk out of Bluetooth range
   (or turn the iPhone's Bluetooth and Wi-Fi off). The log should show "Stopped sending …
   by message at N of 1048576 B: … sending as files" and "Queued …" lines. Come back: the
   next "Sent … by message" for that part should take fewer messages than 18 if the fast path
   took it again, or the file arrives and the phone keeps one copy. The recording completes
   and the joined file is byte-identical (export it from the iPhone and compare its size and
   checksum with the watch's diagnostics sizes).
9. **Background.** While parts go by message, press the crown to leave the app. The log
   should show "Sending as files: the watch app is in the background", and the file path's
   "Queued …" lines. Open the app again: "Sending by: Messages" again.
10. **Old iPhone build.** With an iPhone build from before this change, the watch's
    diagnostics should say the iPhone app does not take recordings by message, and the
    recording should arrive as files as before.
