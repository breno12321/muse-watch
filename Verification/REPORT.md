# Local verification — 17 October 2026

Device screenshots and Bluetooth logs are kept locally and excluded from Git. The content-free JSON results below are included. Historical private network addresses have been replaced with placeholders.

**The live Muse Watch app is implemented and installed on the physical iPhone and Apple Watch. Real Watch text and microphone audio reached Muse, and real replies returned to both devices. A first message in a new Ideas conversation also completed and synced to the Watch.** Pairing, credential refresh, and reconnect were previously verified with this account. The older stages below are chronological records, superseded by the final results here.

## Simplified Home and independent chats — latest update

Home now has Voice note and Chats, with the Muse avatar and a settings gear. Chats offers New chat, and the iPhone conversation list has the same action. Existing conversations are retained. The selected chat persists and becomes the Home voice-note destination; an older draft retains its original destination. Saved messages moved into Settings.

New Watch chats are saved locally. Their first durable message carries validated chat metadata so the phone can adopt the same UUID exactly once before submission. Existing sessions cannot be replaced by that metadata. Creating an empty chat sends nothing to Muse. Install matching phone/Watch versions for this feature.

All 28 protocol tests and Watch model checks passed, including offline creation/first voice note, relaunch, snapshots before phone adoption, draft routing, deduplication, legacy archives/requests, and account isolation. Device and simulator Debug builds and the device Release build passed. Matching signed builds were installed and launched on both physical devices. On Watch, observed the two Home actions, an empty new chat, left-edge Back to the list, selected-chat persistence through update/relaunch, and a visible settings glyph. The iPhone New chat action was visible.

No live messages were posted in this verification. The phone displayed `/chat/subscribe` HTTP 404 on launch; a fresh live first-message/reply exchange for this update is not verified. Previous successful live exchanges below are historical evidence. Content-free results: [simple-chat-results.json](simple-chat-results.json). Device captures remain local and ignored.

## Back navigation and publication preparation — previous update

Fixed the direct Debug chat launch so it pushes from a real Home screen, rather than using chat as a navigation root. Voice and Goals test destinations also retain real parents. The chat shows the native Back chevron. A deliberate rightward drag starting in the 24-point left edge dismisses chat, section details, or About; the custom recognizer is confined to that strip so center reading gestures are not intercepted. Parent gestures are disabled while chat presents its recording sheet.

Observed the Back control and left-edge chat-to-Home return on the physical Watch. Installed the final edge-confined implementation. Additional mirrored scrolling checks were interrupted by the iPhone disconnect. Details: [back-navigation-results.json](back-navigation-results.json). The final signed Debug build and all 25 synthetic protocol tests plus Watch model checks passed with machine-local signing. The Release check is recorded in `/private/tmp/muse-publish-release.log`.

Publication preparation moved the personal signing team out of the Xcode project into ignored Configuration/Local.xcconfig. Private device captures and original notes remain local. AGENT.md provides project guidance; AGENTS.md is the discovery entry point. The reviewed commit contains no detected real token patterns, private-key blocks, personal home-directory paths, physical device identifiers, or local signing data. Synthetic protocol fixtures are intentionally retained with provenance.

## App icon, voice-only Watch chat, and formatted replies — earlier update

Installed updated native apps on both physical devices. The iPhone icon uses the recognizable blue Muse mark from the installed official Muse icon, with a burgundy badge containing a large white microphone. Icon generation/provenance is in [Design/phone-icon.md](../Design/phone-icon.md). The 1024×1024 icon is opaque and the MusePhone target now selects its AppIcon catalog in both configurations.

Watch chat input is voice-only: the text field and reserved bottom composer bar are removed, with a microphone in the navigation bar. Assistant bubbles use the available width. The initial toolbar glyph inherited burgundy on its burgundy button and looked like a red dot; the final glyph explicitly uses monochrome white and was visually verified on the physical Watch.

Both apps render native Markdown headings, inline emphasis/links/code, lists/task lists, quotes, fenced code, and pipe tables. Tables use stacked label/value cards on Watch and wrapping columns on iPhone. User text remains literal. Images retain alt text but are not downloaded; unsupported link schemes are not opened. The existing Muse event parser already preserves Markdown, including structured transcript text blocks; regression coverage verifies that path.

A fresh, real formatting request completed with one matching Markdown reply on phone and Watch. Visually verified the heading, emphasis, bullet list, and table on iPhone, and stacked table on Watch. The older chat-not-found error visible before this update did not affect the fresh completed exchange. All 25 protocol tests and the Watch store checks passed. Signed Debug and unsigned Release builds passed; renderer checks against the minimum iOS17/watchOS10 SDK targets passed with strict-concurrency warnings treated as errors.

Evidence: physical Watch table and visible microphone (local capture; omitted from Git). Results: [rich-chat-results.json](rich-chat-results.json). Logs: `/private/tmp/muse-rich-build.log`, `/private/tmp/muse-rich-release.log`, `/private/tmp/muse-rich-text-tests.log`, and `/private/tmp/muse-rich-store-tests.log`. Private chat journals are excluded from repository evidence.

## Recording experience update — earlier device check

The new recording flow is installed on both physical devices. Tapping Talk to Cal starts recording immediately after any first-use permission; existing drafts open for review. The waveform animates with time and microphone level, respects Reduce Motion, and recording starts/stops with haptics. Sending from Home dismisses review and opens the actual recording’s conversation. Pending permission/audio activation is cancelled if the recording view leaves, preventing a late microphone start.

Recordings now attempt immediate 24 KiB WatchConnectivity chunks without relying on a stale reachability gate. The phone assembles bounded audio, verifies its SHA-256 and WAV format, saves it, then acknowledges it. The scheduled file remains a fallback until durable receipt. The existing request journal deduplicates both paths, and conflicting data cannot overwrite an existing recording. The phone requests background execution before yielding out of processing startup.

**Physical background test passed:** a 7.0896875-second Watch recording reached Muse and completed with one real reply on both phone and Watch while the iPhone remained on its Home screen. The Watch outbox was empty. Sending from Home visibly opened Cal’s chat, where the real response appeared. This is the first completed background-reply check and supersedes the earlier failed short background tests below. Longer replies can still exceed iOS execution time; force-quitting the phone companion can prevent wake-up.

All 19 protocol tests passed, including incomplete/corrupt/out-of-order/oversized immediate audio rejection and idempotent chunk retry. Watch storage checks passed. Debug device, Release device, and Watch simulator builds passed. The simulator MCP could not locate its Xcode toolchain, so its build was checked using the installed Xcode CLI; final interaction and background verification used the actual Watch and iPhone. No simulator credentials were copied.

Evidence: background reply on physical Watch (local capture; omitted from Git), recording waveform (local capture; omitted from Git), subsequent waveform frame (local capture; omitted from Git), and [content-free results](recording-experience-results.json). Logs: `/private/tmp/muse-recording-build.log`, `/private/tmp/muse-recording-release.log`, `/private/tmp/muse-recording-sim.log`, `/private/tmp/muse-recording-core-tests.log`, and `/private/tmp/muse-recording-store-tests.log`.

## Final live app verification

| Check | Result |
|---|---|
| Protocol / authentication / relay tests | 19 tests, zero failures |
| Watch model checks | Offline outbox, cached replies, bookmarks, missing recordings, stale snapshots, account isolation, corrupt-file preservation, and text rendering of replies to voice notes |
| Device builds | Debug signed and Release unsigned iPhone builds, each embedding the Watch target, passed |
| Physical installation | Updated iPhone companion and Watch app installed under matching companion identifiers; existing pairing and history retained |
| Watch text | User's real two-character message completed; one real assistant reply present on phone and Watch |
| Watch microphone audio | User's 4.407625-second recording completed; one real assistant reply present on phone and Watch |
| New Ideas conversation | First post completed after scoped subscription; real assistant reply present on phone and Watch |
| Background recording | User's 3.5160625-second recording reached phone and received Muse acknowledgement with iPhone on Home screen; reply capture did not complete before iOS background expiration |
| Longer Goals request | Muse acknowledged and official Muse showed a response; companion background time expired before capturing it |
| Queue consistency | Watch outbox empty after all five requests were durably received by phone; no automatic repost of accepted requests |

The background and Goals entries are explicitly marked **Sent · open Muse for reply**. Reopening the companion can listen to a still-running accepted turn without posting again. The SDK does not guarantee historical replay of a reply that finished while disconnected. Keep the iPhone companion open for longer exchanges and use official Muse for already missed replies. Full background reply completion has not passed on these tests.

The final apps use WatchConnectivity for durable text and hashed WAV transfer, account-scoped caches, local playback, recoverable drafts, and Library bookmarks. Credentials stay in iPhone Keychain. The paired iPhone provides the internet connection; no ongoing Raspberry Pi, Mac, or Tailscale service is needed. Check-in, Ideas, and Goals are dedicated real conversations, not replicas of the iOS section databases. Earlier account history and automatic avatar retrieval are not provided by the documented SDK; a manual avatar chooser is available on iPhone.

Evidence: new Ideas reply on iPhone (local capture; omitted from Git) and real voice-note reply on Watch (local capture; omitted from Git). Content-free results are in [live-relay-results.json](live-relay-results.json). Build and test logs are in `/private/tmp/muse-final-build.log`, `/private/tmp/muse-final-release.log`, `/private/tmp/muse-final-core-tests.log`, and `/private/tmp/muse-final-store-tests.log`. Raw device journals were used only for verification and are not included in the repository.

The installed live app is **Muse Watch** (`dev.breno.musewatch.phone` on iPhone and `dev.breno.musewatch.phone.watchkitapp` on Watch). The earlier standalone **Muse** prototype has a different identifier and may remain installed. The current development provisioning profile expires on **24 October 2026**.

## Earlier feasibility stages

## Completed checks

| Check | Result |
|---|---|
| Swift authentication/protocol tests | 13 tests, 0 failures |
| Pairing v5 interoperation | Matches pinned SDK's published `community_app_v5` cryptographic vector |
| Noise interoperation | Full handshake, two successive client cipher nonces, and decoded server response match independently generated Python SDK fixture |
| Encrypted setup handoff | Separate request/envelope file encoders work; wrong recipient, wrong request, tampering, expiry, and unknown destination hosts rejected |
| Input handling | BLE fragmentation and malformed sequencing; protobuf truncation/overflow; Noise chunk overflow and closed-cipher behavior |
| Reply correlation | Buffers events until server acknowledgement; isolates session; suppresses duplicate completion |
| Existing Watch model suite | History, bookmarks, goals, draft recovery, voice sending, missing-file recovery, demo replies, duration formatting, corrupt-history preservation passed |
| Browser JavaScript | Syntax check passed |
| MusePhone | Ad-hoc signed iPhone simulator build passed; launched on iPhone 18 Pro / iOS 27 simulator |
| iPhone Keychain | Created request successfully; private setup state survives app relaunch; share request and import actions enabled |
| Device architecture | Unsigned iOS device build passed; this does not prove signing or installation |
| MuseSetup | Ad-hoc signed macOS build passed; setup window launched; Start disabled until a request is imported |
| MuseWatch | Original watchOS simulator build passed |

Run `./scripts/check_auth_gate.sh` to repeat the checks. Logs are in `/private/tmp/muse-local-checks`; the Mac build's detailed log is `/private/tmp/muse-auth-mac-build.log`.

The first unsigned simulator launch exposed Keychain error -34018. Rebuilding with Xcode ad-hoc signing supplied the simulator application entitlement. Relaunch and request creation then passed. The repeatable check script uses signed simulator builds.

## Screenshots

- iPhone request screen (local capture; omitted from Git) — request created and retained after app restart.
- Mac setup window (local capture; omitted from Git) — initial window, captured before the latest label-wrapping polish. The secure field is masked. Pairing was not started.

## Physical-device setup update

The iPhone was subsequently connected and trusted. MusePhone now has Personal Team (configured locally) selected, and Xcode created its development signing certificate and managed provisioning profile. A signed physical-iPhone build completed successfully at `/private/tmp/muse-auth-physical-ready/Build/Products/Debug-iphoneos/MusePhone.app` (log: `/private/tmp/muse-phone-signed-build.log`).

Developer Mode was initially disabled and the user deferred testing. On resuming, Developer Mode was enabled and MusePhone installed successfully on the physical iPhone. Signature verification passed, and its provisioning profile includes this phone. First launch was blocked by iOS pending explicit developer-app trust in Settings → General → VPN & Device Management. After the user trusted the developer app, launch succeeded and the initial MusePhone setup screen was visually verified on the physical iPhone with no Keychain error. Real Muse pairing is still pending. The Personal Team profile expires 24 October 2026; rebuild and reinstall through Xcode when it expires. No build process remains pending; the open Muse Setup window and its entered token were preserved. Create the setup request on the physical iPhone when testing resumes so its 10-minute window is fresh.

## Gate still requiring your devices

At initial local verification, Xcode's inventory showed only simulators; the later physical-device setup is recorded above. The Mac helper's CoreBluetooth advertisement lacks the Linux SDK's manufacturer data because macOS does not expose that advertising feature. The official Muse app must discover and pair it successfully before this architecture is considered feasible.

Follow [TESTING.md](../TESTING.md): install MusePhone on your physical iPhone with your signing team, create a fresh request, pair the helper, import the encrypted credentials, quit the helper, obtain a real reply, refresh the credentials, then reconnect and get another real reply. No simulated responses stand in for this gate.

Per the approved staged plan, the live Watch relay, queued audio transfer, foreground/background recovery, and embedded Watch target remain deferred until that gate passes. The existing Watch app retains its explicitly labeled local demo behavior. Full account history and custom avatar retrieval are not documented by the referenced SDK and are not claimed to be synced.

## Reference and fixture provenance

Protocol reference: `facebookincubator/muse-gadget-sdk` revision `f60347aeb851a1fe9438cfc388721776aa24f275`. License and attribution are in `ThirdParty/`.

`ProtocolTests/Fixtures/link_pairing_v5.json` is the upstream synthetic pairing fixture. `noise_reference.json` was generated with the upstream Python Noise, envelope, and framing implementations using deterministic synthetic test keys; it makes no account requests. `scripts/generate_noise_fixture.py` reproduces it from the pinned checkout with the Python `cryptography` dependency. Those keys are public test inputs, never app credentials.

## Physical Muse discovery check

The user reported no MuseGadget in the official Muse app. The helper displayed `MuseGadget04C7E3` with Start disabled and Stop enabled; that UI is set only after the CoreBluetooth advertising callback succeeds. The Bluetooth daemon also recorded the helper powered on, its service being added, and a start-advertising request with the exact SDK service UUID `7FDD3D1C-38EA-46CF-8B46-314ECF5F240C` and that gadget name. Relevant app-only lines are retained in `bluetooth-advertising.txt`.

The iPhone's official Muse screen displayed “No devices found.” A scan retry was initiated while the helper remained active. macOS accepting advertising does not independently verify the bytes received by the phone. The reference SDK also advertises manufacturer company `0xFFFF`, value `00`, as an informational paired flag. The helper cannot send that field using public CoreBluetooth peripheral advertising APIs. Missing manufacturer data or a shortened local name are possible discovery incompatibilities; neither has been proven to be Muse's filtering criterion. The authentication feasibility gate remains unpassed. An independent BLE receiver scan and checking the official Muse app's Bluetooth permission would distinguish radio reception from app filtering.

## Independent iPhone BLE reception result

Added a read-only 20-second scanner to MusePhone, built and installed it on the physical iPhone, and ran it while the existing Mac helper advertised. The scan completed, saw 35 distinct nearby devices, and found one peripheral carrying the exact Muse service UUID. Final signal was -27 dBm. No advertised local name or cached peripheral name was supplied to the scanner (shown as “Unnamed gadget”); no SDK manufacturer flag was received. Service UUIDs and any seen SDK flag are merged across callbacks to avoid mistaking a split scan response for a missing field. The scanner made no peripheral connections and sent no credentials.

Evidence: completed physical scan (local capture; omitted from Git). Device-build log: `/private/tmp/muse-bluetooth-probe-build.log` (BUILD SUCCEEDED). Muse's Bluetooth permission was enabled according to the user, and its discovery screen still showed no devices in the earlier retry. This rules out absence of radio reception for the Muse service. It does not prove which fields Muse requires: the missing name and missing paired flag remain concrete differences from the SDK's Linux advertisement, and discovery compatibility has not passed. The next feasibility path would be pairing with a supported SDK Bluetooth host that can emit the full advertisement, then testing whether provisioned credentials work in the iPhone client. That path is not yet implemented or verified.

## Raspberry Pi preparation

SSH access to `<pi-ssh-host>` as `breno` now works. Inspected Debian 13 on aarch64/Pi 4; `cryptography`, `dbus`, and `gi` were already installed. The user removed the Bluetooth software block. The controller was powered on and supports BLE peripheral advertising. No Muse gadget service was active.

Deployed the pairing-only helper to `~/muse-watch-setup` as the normal user. A three-second diagnostic run registered the actual SDK GATT service and advertisement successfully via BlueZ, then restored the controller alias to `breno-pi`. This diagnostic used no SDK token, did not pair an account, and did not run a Muse command service. Real pairing still needs a fresh iPhone setup request and the SDK token entered privately in the user's SSH terminal.

Five independently generated Python-to-Swift handoff fixtures passed, including whole and fractional Foundation-reference date encodings. The Swift suite now has 10 passing tests. Test log: `/private/tmp/muse-pi-handoff-tests.log`. The helper vendors only the SDK's BLE/pairing/identity/config modules at the pinned revision; it does not include its remote shell or file executor. Its credential-validation request uses a fixed Muse API destination and refuses redirects. Output is exclusively created as an encrypted `.musepair` with mode 0600; SDK token entry uses a hidden terminal prompt.

## Real Raspberry Pi pairing succeeded

The user ran the deployed helper with the SDK token entered through its hidden prompt. The Pi advertised `MuseGadget5B8CD0`; BlueZ showed one active advertisement. The official Muse iPhone app discovered it, and the user completed pairing. The encrypted `MuseWatch.musepair` was created with mode 0600 and request ID `20BF5166-110B-4288-BA74-890C17FD0666`. Creation follows a successful real `/fetch_vms` validation of the provisioned device credentials. The helper stopped and restored the Bluetooth alias to `breno-pi`.

Copied only the encrypted envelope to this Mac's ignored `SetupTransfers/` file. No plaintext credential or token was printed or saved. The Mac-to-iPhone transfer and independent iPhone Noise registration/reply/refresh tests remain pending. The discovery and provisioning portion of the Pi feasibility gate has passed; full iPhone/Watch feasibility is not yet established.

## Existing-chat subscription investigation

Inspected the official Muse macOS app through its normal UI. It displayed the latest dedicated test chat and a real assistant reply, confirming the user’s report. The UI exposed that chat’s identifier without needing a share-link feature. No account credential was extracted from Muse.

Added a read-only existing-chat subscription check and bounded diagnostics containing HTTP status, byte counts, known event categories, and session-match booleans. No tokens, message bodies, or remote identifiers are included in these diagnostics. On the physical iPhone, the existing-chat subscription returned HTTP 200 and a 255-byte `agent.status` event matching the selected chat. No prior assistant message was replayed during observation. The SDK exposes a live NDJSON subscription but does not document a history replay guarantee.

The test app now persists its dedicated chat scope alongside the node-scoped local transcript, opens a scoped subscription on reconnect, and avoids replacing an already matching subscription after posting. Validated message acknowledgements mark the chat as existing. The manually selected existing test chat survived another signed application update. Swift suite: 12 tests, zero failures; signed physical-device build and install succeeded. A controlled same-chat message test is in progress; receiving status events alone does not satisfy the reply gate.

The live events isolated an empty-string compatibility bug: `reply_to_message_id: ""` was treated as an explicit foreign parent by Swift optional coalescing. The upstream Python uses truthy `or`, falling back to `parent_message_id` or treating the parent as absent. Updated the bounded reply accumulator to use nonempty identifiers for those fallbacks. A synthetic regression reproduces the received start/append/structured-transcript completion shape and verifies that a nonempty foreign fallback parent is still rejected. All 13 protocol tests pass. Temporary raw event capture was removed from the app after diagnosis, and its protected device file is removed on launch. Only bounded content-free diagnostics remain.

## Physical iPhone reply verified

Installed the corrected signed build. Reconnected with the saved, previously refreshed device credentials to the existing dedicated test chat, opening its scoped subscription before posting. Submitted “Final reply check: please say hello.” The physical iPhone displayed **Real Muse reply received** and **YOUR MUSE · Hello!** in its live transcript. The official Muse app showed the same submitted message and reply. No generated reply or mocked response was used.

Evidence: reply status (local capture; omitted from Git), reply transcript (local capture; omitted from Git), and the earlier credential refresh (local capture; omitted from Git). Final Swift suite: 13 tests, zero failures. The final physical build, install, and launch succeeded.

The iPhone authentication/refresh/reconnect/text-reply path has passed for this paired account and existing test chat. This does not establish full account-history retrieval or fresh-chat historical replay: a first post creates its side chat, so a very fast first reply may precede its scoped subscription. Reconnect now preserves that chat and opens the subscription before subsequent sends. The Watch relay, real Watch audio delivery, background recovery, and physical Watch installation remain the next implementation stage.

## Physical Apple Watch installation

After the user enabled Developer Mode and paired the Watch with the Mac, Xcode recognized the physical Apple Watch Ultra 2 running watchOS 27.0. The `MuseWatch` scheme built successfully with automatic development signing. Installed `dev.breno.musewatch` directly on the Watch using `devicectl`, launched it successfully, and visually verified its home screen with the avatar, greeting, “Talk to Cal” button, and **LOCAL PROTOTYPE** label. Evidence: physical Watch app (local capture; omitted from Git). Build log: `/private/tmp/muse-watch-physical-build.log`.

This proves physical Watch signing, installation, and launch. It does not add the pending live WatchConnectivity relay: Watch conversations/audio still use the local prototype behavior, while the physical iPhone test app has the verified Muse account connection.
