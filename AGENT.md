# Working on Muse Watch

Read README.md and TESTING.md before changing setup or device behavior.

## Project map

- MuseWatch/: watchOS app; input is voice-only, with cached chat history.
- MusePhone/: iPhone companion; owns Muse authentication and internet access.
- Shared/: account protocol, durable relay models, and native Markdown renderer.
- PiSetup/: one-time Bluetooth pairing and encrypted credential handoff.
- ProtocolTests/ and Tests/: synthetic protocol tests and Watch model checks.
- Configuration/Signing.xcconfig: includes optional, ignored local signing settings.

The verified SDK revision is recorded in ThirdParty/NOTICE.md. Preserve its license notices. Do not replace the pairing helper with the full upstream remote-command service.

## Build and test

Use full Xcode, not Command Line Tools alone. Set DEVELOPER_DIR to your Xcode installation when needed. From the repository root:

```sh
swift test
./scripts/test.sh
python3 scripts/generate_project.py
```

Regenerate the project after adding Swift files. Keep the Watch shared-source allowlist in the generator current. Personal development teams belong in Configuration/Local.xcconfig, copied from its example; that file must remain ignored. The generator migrates an existing inline team into that local file.

Run checks relevant to the change. A successful compile does not prove device pairing, a real reply, or background delivery. Use synthetic fixtures for automated tests. Never send extra live account messages merely to repeat a passed check.

Keep one Muse Watch app installed per device after validation. Remove temporary experiment apps and generated test projects when finished; retain the production unit tests and content-free findings. Speech assets are prepared through scripts/prepare_speech.py and scripts/convert_speech.py, without a separate experiment checkout.

## Behavior to preserve

- The Watch uses its paired iPhone; Muse credentials never go to Watch.
- Save requests and complete audio before acknowledging receipt. Deduplicate immediate and scheduled transfers. Never automatically repost an accepted or potentially submitted message.
- Copy WatchConnectivity temporary files before their delegate returns.
- Voice input is transcribed locally on iPhone using an authorized, supported on-device Speech recognizer. Send only the durable transcript to Muse, never the WAV plus a caption. Keep the immutable original relay request for deduplication, retain recordings on transcription failure, pause failed transcription until explicit retry, and never retry accepted/uncertain turns. Speech permission is requested only in foreground; transcription/recognizer deadlines and background expiration must cancel without submitting. Historical cached audio must remain readable by the storage/protocol layer. Muse requests remain text-only: use SDK text output, omit saved optional voice-note instructions, and do not automatically retrieve presentation audio. Keep recording input/playback. Completed replies support explicit Watch Generate audio using local English Kokoro on iPhone; never generate or play automatically. Keep local speech requests account/text scoped and separate from retained original Muse media. Preserve historical media and metadata.
- One tap starts recording; existing drafts open for review. Sending from Home opens the actual conversation.
- Keep a real parent behind every detail screen, including debug launch routes. Verify Back, left-edge swipe, and vertical scrolling; do not leave users in a detail-only test root.
- Watch chat cards use rounded backgrounds while preserving native swipe actions. iPhone Home shows Muse and chats; profile, connection controls, and earlier prototype chats live under Settings. Recognize old starter chats only by their exact historical title/symbol pairs without a manual/server title. Preserve all history and bookmarks, keep Watch draft/pending-send destinations visible, and let renaming restore an earlier chat to the main list.
- Home stays focused on Voice note and Chats. Preserve selected-chat persistence and existing chat history. New Watch chats travel as validated metadata with their first durable message; adoption must be idempotent and must never replace an existing server session. An older draft keeps its original chat even if selection changes.
- Watch chat rows swipe right to pin/unpin and left for a menu with delete and rename. Use native swipe actions; watchOS context menus are deprecated. Pins precede other chats. Watch-only removal must survive future phone snapshots, preserve phone/Muse copies and recordings, protect drafts/pending sends, and leave a path to New chat after the last removal. Keep these preferences account-scoped and backward-compatible.
- Keep edge gestures confined to the edge so normal reading gestures remain available. Do not dismiss an active recording through a parent gesture.
- Preserve Markdown source from Muse events. Render it natively; user text remains literal. Do not fetch remote images or enable arbitrary link schemes.
- Retained original Muse voice-reply protocol support (hidden in the UI) uses Muse's SDK MP3 endpoint or a correlated audio presentation's bounded workspace-file GET through the iPhone. Workspace media access can return a scoped 403 for gadget credentials; preserve text/pairing, show the limitation, and stop automatic retries for that card. Never use official-app credentials or alternate routes to bypass that denial. Keep download/transfer sizes bounded, verify account/chat/message scope and file hashes, and retain reply text when audio fails. Playback is tap-to-play; never auto-play, repost a user message to obtain audio, or send tokens/media URLs to Watch. Cache before transfer and copy incoming temporary files before the delegate returns.
- Watch names use a separate system name editor; chat messages remain voice-only. Persist pending rename metadata before transfer, preserve it through stale snapshots, and clear it only after a matching/newer name revision arrives from iPhone. Validate account/chat/name scope; accept empty-chat metadata without posting a Muse message. Name revisions must advance on phone edits too, so old or duplicate transfers cannot overwrite newer names.
- Respect a user's custom chat name over optional server topic metadata. Do not invent a title-fetch endpoint or rename chats using arbitrary message/attachment titles.
- Saved-chat subscription 404 and saved-reply timeout are scoped recovery failures. Persist a stop marker, retain accepted IDs/history, and never repost or repeatedly auto-retry those turns. Keep auth failures and live/unscoped stream failures visible. Fresh sends can try the SDK’s unscoped live listener once after a scoped 404, retaining strict chat/turn correlation. The read-only connection check must serialize with the existing client and never post a message.
- iOS background execution is finite. Do not claim unlimited background replies or undocumented full-history/avatar synchronization.

## Privacy and publication

Before every commit/push, inspect the actual staged files and diff, not just gitignore. Keep credentials, tokens, Keychain exports, signing keys/profiles, local configuration, recordings, setup envelopes, app containers, device identifiers, private network addresses, and personal absolute filesystem paths out of Git. Generic tool paths such as /Applications/Xcode.app and /private/tmp are acceptable examples.

ProtocolTests/Fixtures contains deliberately public synthetic cryptographic inputs; preserve the fixture provenance. Real credentials must never be used to regenerate these fixtures.

Device screenshots, Bluetooth logs, and private reports stay in ignored local paths. Commit only content-free verification results. Keep documentation links usable for a fresh clone without those captures. Muse branding and personal avatar artwork are separate from the SDK's Apache license.

Do not overwrite user work, delete their recordings, rewrite remote history, force-push, or change repository visibility without explicit authorization. Use repository-relative paths and configurable device destinations in scripts. Do not hard-code a developer's home directory or physical device identifier.
