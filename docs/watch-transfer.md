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
   transfers that have been stuck for 15 minutes, and asks for the next refresh.
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
- Storing a file and joining parts run inside `ProcessInfo.performExpiringActivity`
  (`withBackgroundTime`), so iOS does not suspend the app partway through a 35 MB join.
- If the app is stopped anyway, the staged copy is removed at the next launch
  (`RecordingStore.removeStaleStagingFiles`). The parts stay. At the next activation the
  phone finishes every join that has all its parts and acknowledges it
  (`finishInterruptedJoins`). Before this change, the join waited for the next file to
  arrive.
- SwiftUI's `.backgroundTask(.watchConnectivity)` is not available on iOS, so the phone has
  no equivalent of the watch's task.

## A fast path over `sendMessageData`: not implemented

Sending parts as messages while both apps are reachable, with the reply as the
acknowledgement, looks attractive. It is not implemented, for these reasons:

- **It helps only when the watch app is already open.** On the watch, `isReachable` needs
  the app in the foreground (or running a workout). A finished recording's workout has
  ended, so the fast path would run only while the user looks at the watch app. That is
  exactly when `transferFile` already moves at its best rate. It does nothing for the
  background case, which is the real problem.
- **The message size limit is undocumented.** `WCErrorCodePayloadTooLarge` (7009) exists, but
  the SDK gives no limit. Reports put it near 64 KB, so a 1 MiB part would need 16 or more
  messages and a second layer of chunking on the phone. Chunks would also have to be kept
  apart from the part layouts: `TransferParts.store` drops another layout's parts, so
  storing a message-sized layout would throw away progress made in files.
- **The throughput is unknown.** Messages and files share the same link. No SDK document
  says messages are faster, and the simulator cannot measure WatchConnectivity.
- **It duplicates the pipeline.** A part could be in flight as a file and as messages at
  once. That is safe (the phone keeps duplicates), but it wastes the slow link unless the
  watch also cancels queued file transfers. Cancelling transfers that may be moving is what
  #165 and #167 had to stop doing.

The invariants would hold: the phone would store a chunk durably before replying, and only
the userInfo acknowledgement listing every file would allow deleting. The issue is the cost
and the uncertain gain. Revisit with a measurement: with the watch app open, compare the
time between part acknowledgements in the transfer log with a test build that sends one
1 MiB part as 64 KB messages.

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
| A transfer fails (link drops, phone app not installed, timeout) | A retry after a backoff: 30 s, doubling to 30 min (`TransferPolicy.retryDelay`). One retry is pending per recording, so many parts failing together count once. Until it is due nothing of the recording is queued (only "Send again" overrides), and a part queued before the failure that finishes during the wait does not clear the count. The next refresh covers it if the app is suspended. |
| A part is delivered but its acknowledgement is slow or lost | Not sent again for 10 min (`handoverGrace`), so the window does not cycle through the same parts. After that it goes again, and the phone keeps its copy. |
| A transfer stays queued and never moves, or stops partway | Restarted by the launch or the next background refresh once it has been queued for 15 min without starting, or has sat at the same progress for 15 min (`shouldRequeue`). Progress is kept across launches, so separate background wakes can tell flat from new. A transfer that is moving is never cancelled. |
| The phone app is not running | Transfers wait in WatchConnectivity. The phone receives them at its next launch or background launch. |
| The watch restarts | Transfer times are stored in the metadata, so stuck detection still works. Leftover slices are removed. The phone's holdings are kept on disk. |
| The phone loses or deletes files it acknowledged, or the phone app is reinstalled | The watch's saved holdings are stale. When they claim everything, `meta.json` goes alone, and its live acknowledgement says what the phone really holds. The rest is then sent. Deletion needs a live list. |
| The watch app is reinstalled | Its recordings are gone with its container. Nothing is left to send. |
| A join on the phone is cut short | Finished and acknowledged at the next activation. |
| `meta.json` acknowledged while the last parts are in flight or handed over | No longer sent again on each acknowledgement. It used to go back and forth until the parts arrived. |
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

The simulator does not deliver WatchConnectivity files or background tasks, so these need a
paired iPhone and watch:

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
6. **Rate.** With both apps open, note the times of successive "iPhone holds" lines. The
   interval per 1 MiB part is the transfer rate to compare with the 2 MB/min baseline and
   with any fast-path experiment.
