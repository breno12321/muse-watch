# Muse Watch device guide

## Installed personal build

The iPhone companion and paired Watch app are named **Muse Watch**. The iPhone icon uses the blue Muse mark with a burgundy audio badge. The old standalone **Muse** prototype may still have a separate icon. Use Muse Watch for live messaging.

1. Open Muse Watch on iPhone. Your current pairing is retained in Keychain; the screen should say **Ready for your Watch**.
2. Open Muse Watch on the paired Apple Watch. Wait for its chats to sync. The avatar, names, and chats remain cached offline.
3. Tap **Voice note**. Recording starts immediately after microphone permission, with moving audio waves and a start haptic. Check the destination shown below the button. Tap **Stop recording**, review or play back the note, then **Send voice note**. Home opens the correct chat automatically after the recording is safely queued. An existing draft keeps its original destination and opens for review instead of being overwritten.
4. Open the conversation to follow **Waiting for iPhone → On iPhone → Sending → Sent / waiting for Muse** and read the real response.
5. Watch chats use voice input only. Tap the microphone in the navigation bar to record; no keyboard or bottom input bar covers the conversation. The bookmark beside a message saves it to **Home gear → Saved messages**. Type messages in the iPhone companion if needed.
6. Open **Chats → New chat**, then use the microphone. Confirm the first note and reply belong to the new chat and the previous chat keeps its history. Go back Home: Voice note now targets the chat you last opened. Try **New chat** on iPhone too, then sync the Watch. Empty chats remain local until their first message; this action alone sends no prompt.
7. On iPhone, edit the Muse name/your name, tap **Save names**, or choose a Muse avatar image. Sync the Watch to transfer the change.

Leave chat with the top-left Back chevron or a rightward drag starting at the left edge. Swipes starting in the middle and ordinary vertical scrolling do not trigger Back. The same edge gesture works on Chats, Settings, and Saved messages.

Muse replies display Markdown headings, emphasis, lists, links, quotes, code, and tables. On Watch, table rows stack vertically for readability.

Older section conversations remain available in Chats. The companion captures its own conversations and replies; earlier account history is not imported by an undocumented API.

## Background and interrupted delivery

Return iPhone to its Home screen without force-quitting Muse Watch, then send a short message or recording from Watch. The nearby iPhone can wake, connect to Muse, and deliver its reply. Voice notes first attempt an immediate, chunked transfer that wakes the companion; the durable WatchConnectivity file is a fallback if the immediate path is unavailable. Transfers may still be delayed by connectivity or system scheduling.

For a longer task, open Muse Watch on iPhone and leave it in the foreground. The app uses a finite iOS background task and releases its network connection when idle. It does not claim an unlimited background WebSocket.

- A request waiting on Watch remains in its persistent outbox until the phone confirms a durable receipt.
- Duplicate transfers are deduplicated; a repeated delivery does not create another Muse post.
- A connection failure before submission can be retried with **Sync Watch & retry connection** on iPhone.
- A potentially submitted request is never automatically resent. **Delivery uncertain** asks you to check official Muse.
- An acknowledged request whose reply was interrupted shows **Sent · open Muse for reply**. Reopening the iPhone can resume listening to a still-running turn without posting again. If the server already completed it, historical replay is not guaranteed; read that reply in official Muse.
- Drafts, recordings, cached replies, and Watch bookmarks survive app relaunch. Corrupt local history is preserved rather than silently replaced.

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

See [Verification/REPORT.md](Verification/REPORT.md) for physical-device results. Synthetic tests alone do not establish end-to-end account compatibility.
