# Muse Watch device guide

## Installed personal build

The iPhone companion and paired Watch app are named **Muse Watch**. The iPhone icon uses the blue Muse mark with a burgundy audio badge. The old standalone **Muse** prototype may still have a separate icon. Use Muse Watch for live messaging.

1. Open Muse Watch on iPhone. Your current pairing is retained in Keychain; Home shows your Muse and chats; connection details are under the Settings gear. In **Settings → Voice notes**, select your speaking language, tap **Enable transcription**, and allow Speech Recognition. Keep iPhone open for the first test.
2. Open Muse Watch on the paired Apple Watch. Wait for its chats to sync. The avatar, names, and chats remain cached offline.
3. Tap **Voice note**. Recording starts immediately after microphone permission, with moving audio waves and a start haptic. Check the destination shown below the button. Tap **Stop recording**, review or play back the note, then **Send voice note**. Home opens the correct chat automatically after the recording is safely queued. An existing draft keeps its original destination and opens for review instead of being overwritten.
4. Open the conversation to follow **Waiting for iPhone → On iPhone → Sending → Sent / waiting for Muse** and read the real response.
5. Watch chats use voice input only. Tap the microphone in the navigation bar to record; no keyboard or bottom input bar covers the conversation. The bookmark beside a message saves it to **Home gear → Saved messages**. Type messages in the iPhone companion if needed.
6. Open **Chats → New chat**, then use the microphone. Confirm the first note and reply belong to the new chat and the previous chat keeps its history. Go back Home: Voice note now targets the chat you last opened. Try **New chat** on iPhone too, then sync the Watch. Empty chats remain local until their first message; this action alone sends no prompt.
7. On iPhone, open the Settings gear to edit the Muse name/your name, tap **Save names**, or choose a Muse avatar image. Sync the Watch to transfer the change.
8. On Watch, open **Chats**, swipe left on a row and tap the blue **Rename** pencil. Tap **Chat name**, dictate/edit it using the Watch system input, then **Save name**. Confirm it updates on iPhone. Repeat offline and after relaunch; the latest name should survive a stale phone snapshot and sync when reconnected. Renaming an empty Watch chat must adopt its metadata on iPhone without posting any Muse message. In the iPhone chat, tap **Rename**, edit **Chat name**, and Save. Confirm the title updates on both devices and survives relaunch. A manual name should survive later server topic updates. Clear it with **Use Muse topic / Use default name** if desired.
9. Under a completed English reply on Watch, tap **Generate audio**. Confirm **Waiting for iPhone / Generating on iPhone** becomes **Play audio** without playback starting. Play, pause/resume, and replay offline. Check the English caption, duration, progress, bookmark, Back/edge swipe and vertical scrolling. Status changes must not jump the reading position. The outgoing Muse payload remains text-only and no extra Muse request is made. Your own recorded notes and historical original Muse audio remain preserved.
10. In Watch **Chats**, swipe right on a row to show **Pin / Unpin**; tap it and confirm pinned chats appear first with a pin symbol. Swipe left for the menu containing **Delete** and **Rename**. Tap Delete, then confirm **Delete from Watch** or Cancel. Use a new empty local chat for deletion checks; do not delete personal conversations merely to validate the UI. Check the removal survives sync/relaunch, iPhone history remains available, and Back/vertical scrolling still work. Chats with a draft or pending send must explain why deletion is blocked. If all chats are removed, Home should direct you to Chats → New chat.

Leave chat with the top-left Back chevron or a rightward drag starting at the left edge. Swipes starting in the middle and ordinary vertical scrolling do not trigger Back. The same edge gesture works on Chats, Settings, and Saved messages.

Muse replies display Markdown headings, emphasis, lists, links, quotes, code, and tables. On Watch, table rows stack vertically for readability.

Untouched prototype starter chats are under iPhone Settings → Earlier chats; their history remains readable. Renaming an earlier chat returns it to the main lists. A Watch draft or pending send keeps its destination visible. The companion captures its own conversations and replies; earlier account history is not imported by an undocumented API.

Check rounded corners on Watch chat rows, including New chat, with swipe actions open and closed. On iPhone, Home should contain only Muse status and chats; profile, connection controls, help, and Earlier chats belong under the Settings gear. Inspect earlier history without sending test prompts or deleting conversations.

## Transcript-only voice input

For one fresh Watch note, verify that the recognized text replaces “Voice note” on iPhone and appears beside local recording playback on Watch. The Muse post must use the text payload with `message` and `output_modality: text`; it must contain no `items` or base64 recording. Confirm the actual assistant reply separately: an acknowledged post or a downloaded MP3 of Muse’s error message does not establish a successful answer. Do not resend historical accepted/uncertain messages to test the new input mode.

On a disposable development setup, deny Speech permission or use silence/an unsupported on-device language. Confirm that nothing is submitted, the recording survives relaunch, and Settings offers permission/language controls and **Retry saved voice notes**. Other typed requests must still run. Grant permission/change language and retry only the unsubmitted note. Cancel/expire transcription before submission: it must preserve the recording without marking it sent. After a transcript has been saved, reconnect retries must reuse that text; after submission, accepted/uncertain guards still prevent reposting.

The following checks apply to retained audio protocol support, not the current text-only UI. For separate voice-note cards, verify `delta.presentation` with `kind: audio`, accepted-turn/chat/parent correlation, retained phone-only source metadata, and a bounded encrypted GET restricted to workspace audio. No URL/path belongs in Watch snapshots. A 403 must leave text and pairing intact, explain the denial on that reply, and persist a stop marker for automatic retries. Manual audio retry must only read the existing file. Test MP3/WAV/M4A descriptors and legacy MP3 archives. Never bypass a gadget media denial with official-app credentials.

The Speech recognizer is forced on-device and has a 45-second deadline. iOS can end background time sooner. Verify a short background exchange after foreground success; do not assume an earlier WAV-upload background test proves transcription delivery.

## Background and interrupted delivery

Return iPhone to its Home screen without force-quitting Muse Watch, then send a short message or recording from Watch. The nearby iPhone can wake, connect to Muse, and deliver its reply. Voice notes first attempt an immediate, chunked transfer that wakes the companion; the durable WatchConnectivity file is a fallback if the immediate path is unavailable. Transfers may still be delayed by connectivity or system scheduling.

For a longer task, open Muse Watch on iPhone and leave it in the foreground. The app uses a finite iOS background task and releases its network connection when idle. It does not claim an unlimited background WebSocket.

- A request waiting on Watch remains in its persistent outbox until the phone confirms a durable receipt.
- Duplicate transfers are deduplicated; a repeated delivery does not create another Muse post.
- A connection failure before submission can be retried with **Sync Watch & retry connection** on iPhone.
- A potentially submitted request is never automatically resent. **Delivery uncertain** asks you to check official Muse.
- An acknowledged request whose reply was interrupted shows **Sent · open Muse for reply**. Reopening the iPhone can resume listening to a still-running turn without posting again. If the server already completed it, historical replay is not guaranteed; read that reply in official Muse.
- Drafts, recordings, cached replies, and Watch bookmarks survive app relaunch. Corrupt local history is preserved rather than silently replaced.
- Audio is cached before transfer. File arrival may precede chat metadata; it must attach only to the matching account, chat, and assistant message. Missing files offer sync, and failed/expired fetches offer retry. Older text-only replies may have no stream. Do not claim that a spinner or successful download proves audible playback; verify Play/Pause on the physical Watch and its available audio route.

## Connection checks and unavailable saved replies

In iPhone Settings, **Check Muse connection** registers and opens the SDK’s unscoped live listener, then disconnects. It must not create a chat or post a message. The check shares the existing client serially; incoming notes stay queued while it runs. A scoped subscription 404 for an accepted saved turn marks only that recovery unavailable and persists a stop marker, so relaunch/retry does not repeat it or block later notes. The Settings notice explains where to read earlier replies. Preserve authentication errors (401/403), live/unscoped subscription failures, and network errors as connection failures. For fresh sends, a scoped 404 may fall back once to the SDK’s live listener while reply correlation still rejects other chats/turns. Do not claim that this restores historical replies.

## Rebuild / install

Open `MuseWatch.xcodeproj`, configure your signing team in the ignored `Configuration/Local.xcconfig` (copy the example first), confirm the same team on both targets, and choose **MusePhone** with your physical iPhone. Its build embeds MuseWatch. The Watch must be paired to your iPhone and paired for development with Xcode.

Enable Developer Mode on both devices, complete the restart confirmation, and accept any Trust prompt yourself. If Watch Developer Mode is hidden, begin **Device Hub → + → Pair Nearby Device** first and reopen Watch Settings → Privacy & Security. Once it appears in Device Hub, select the **MuseWatch** scheme and your physical Watch to install directly if necessary.

Your current Personal Team profile expires on 24 October 2026. Build and reinstall again when needed. Installing an update with the same iPhone bundle identifier preserves its Muse Keychain credentials.

## First-time Muse authentication

Existing installations do not need to repeat pairing. For a new phone/account:

1. In the iPhone app, tap **Connect your Muse → Create a fresh request**. Share the `.muserequest` to your pairing host. The request expires after ten minutes and contains only a public key and metadata.
2. Follow [PiSetup/README.md](PiSetup/README.md) on a supported nearby Raspberry Pi. The Pi 4 path is physically verified; macOS advertising was not discoverable by official Muse in this setup.
3. Enter your SDK token privately at the helper's hidden prompt. Do not send it in chat, arguments, or a source file.
4. In official Muse: **Settings → Devices → Developer mode → Add Device**, choose the advertised MuseGadget, and complete pairing. Choose the Pi's existing internet connection when offered.
5. Return the resulting encrypted `.musepair` file to this iPhone and open it with Muse Watch (or use **Import encrypted setup**).
6. Wait for validation to complete. The Pi helper stops; no ongoing Pi service is required. Confirm a real text exchange on the phone before relying on Watch delivery.

## Verification commands

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
./scripts/test.sh
```

Protocol tests cover independent SDK crypto fixtures, token/envelope boundaries, chat correlation, the real empty-parent reply shape, WAV upload schema, duplicate delivery, crash recovery, snapshot size limits, and reply-listening recovery. Watch model checks cover offline queue persistence, real cached replies, bookmarks, missing recordings, account changes, stale snapshots, and corrupt-file preservation.

New-chat checks cover independent IDs, validated first-message metadata, idempotent phone adoption without replacing an existing session, offline voice-note destinations, relaunch, sync races before phone adoption, legacy archives/requests, and account isolation. For a device check, briefly disconnect the Watch from its phone, create a chat and record a note, then reconnect; verify it appears once on iPhone and gets a reply in its own conversation. Keep an older draft while opening a different chat and confirm it is still sent to its original destination. Automated tests exercise these cases without live account posts.

Audio/name checks cover bounded split response assembly, audio-only HTTP errors, legacy endpoint fallback paths, URL-component encoding, GET framing, checksum rejection, account isolation, file-before-metadata replay, custom name precedence/reset/validation, and backward-compatible archives. Real server topic metadata is optional and not documented as a guaranteed SDK event; synthetic parser checks do not establish that a server topic was received.

Watch chat-action checks cover pin ordering/selection, unpin, persistence across sync/relaunch, deletion tombstones, Saved messages filtering, last-chat replacement, draft/outbox/sending protection, failed-write rollback, and legacy/account isolation. Pins/deletions belong to this Watch; they do not call an undocumented Muse deletion API. Watch names sync to iPhone through validated, account-scoped metadata edits. Rename tests cover idempotency, out-of-order delivery, phone-edit revision conflicts, offline pending edits, snapshot acknowledgement, empty-chat adoption, failed-write rollback, and legacy archives. Concurrent phone edits win equal revisions; metadata never becomes a chat message.

Chat recency/refresh checks cover newest-first activity ordering, empty and legacy chats, in-place reply updates, stable ties, pin priority, persistence, repeated opening of the same chat, account/chat validation, bounded focused snapshots when another chat fills the global mirror, and merging without losing other conversations or bookmarks. On devices, open an older saved Watch chat, go Back, and reopen it; confirm its latest captured reply is visible and opening it alone does not move it above a more recently updated chat. No new account message is needed for this check.

See [Verification/REPORT.md](Verification/REPORT.md) for physical-device results. Synthetic tests alone do not establish end-to-end account compatibility.

## Local English speech verification

Run `swift test`, `./scripts/test.sh`, and `swift test --package-path LocalSpeech` after speech preparation. For real synthesis/cache verification on Mac, run `python3 scripts/prepare_speech.py --compile-mac`, then `KOKORO_TEST_ASSETS="$PWD/.local/speech/mac" swift test --package-path LocalSpeech`. The otherwise-skipped synthesis check generates synthetic text only. See [production preparation](scripts/speech/README.md).

The completed physical validation used isolated synthetic replies, separate app identities and no production account/container access. **Kokoro Lab** and **Speech Check** have since been uninstalled from both devices, and their projects, generator and private sample files removed. Only Muse Watch remains installed. Historical findings are retained as documentation in [Verification](Verification/SPEECH-REPORT.md); they are not runnable test repositories.

For future physical validation, use synthetic fixtures on a disposable setup without sending live Muse messages. Join phone/Watch measurements by request identity and count only trials backgrounded at both start and finish. Target at least 19/20 transfers ready within 20 seconds. Repeat cold/long-idle cases separately. A successful transfer is not proof of audible playback or preferred voice quality. Remove temporary apps and projects after validation; retain one Muse Watch app on each device.

Check cached playback after relaunch with no app transport, Play/Pause/Resume, retained progress, navigation and recording interruption. Transport-isolated replay does not prove radio-disconnection behavior or physical speaker audibility. Leave working production pairing and history intact.

Check expiration, memory warnings, disconnection, lost files, duplicate delivery, relaunch, account changes and changed reply text. Paused jobs retain chunks; foreground/resume finishes them. Failed jobs require explicit retry. Message delivery/transcription takes priority over generation. Cache eviction affects only generated speech; protect active transfers/playback. Do not reset working Muse pairing or send new account messages for these tests.
