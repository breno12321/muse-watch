# Muse Watch

A personal Apple Watch app for talking to your Muse through your iPhone. Tap once to record, review and send a voice note, then read the real reply in chat. Watch input is voice-only; the iPhone companion also supports typed messages. Includes formatted replies, cached conversations, bookmarks, and your Muse avatar.

```text
Apple Watch → WatchConnectivity → paired iPhone → Muse
```

The iPhone provides internet access. The Watch does not need its own Wi-Fi or cellular connection. **The Mac and Raspberry Pi are setup tools; neither needs to run during everyday use. Tailscale is optional SSH access to the Pi, not part of messaging.**

## Quickstart

### Already installed and paired

1. Open **Muse Watch** on iPhone once after installation. Confirm your account is connected, then return to the Home screen. Avoid force-quitting the app.
2. Open **Muse Watch** on your paired Apple Watch and wait for the chats to sync.
3. Tap **Voice note**. Recording starts immediately, with animated audio waves and a haptic. The destination chat appears below the button. Allow microphone access on first use. An existing draft opens for review in its original chat instead.
4. Tap **Stop recording**, optionally play it back, then **Send voice note**. The app opens that conversation automatically. Read Muse’s reply and tap **Play reply** to hear its audio on the Watch. Playback supports pause/resume and progress; downloaded replies stay available offline. Audio never plays automatically.
5. Tap **Chats** to reopen a conversation, or **New chat** to start a separate one. Opening a chat selects it for the next Home voice note. Tap its microphone to record another note; Watch input remains voice-only. **New chat** is also available on iPhone. Creating an empty chat sends nothing to Muse; the first message creates its server conversation.

To leave a Watch chat, tap the top-left Back chevron or drag right from the left edge. Vertical scrolling and the Digital Crown still scroll messages. The Home gear opens connection settings and **Saved messages**; tap the bookmark beside a message to save it there. Recordings stop at 60 seconds. Unsent drafts, new chats, and the selected conversation survive a relaunch, including while offline. Change the Muse name, your name, and avatar in the iPhone companion.

**Chat names:** on iPhone, open a chat and tap the pencil (**Edit chat name**). Save a name of up to 80 characters; it syncs to the Watch and takes priority over subsequent server topic metadata. **Use Muse topic / Use default name** removes your override. The gadget SDK does not document a thread-title fetch API; scoped topic metadata is used when present, and manual naming remains available.

**Watch chat actions:** in **Chats**, swipe a row **right** for **Pin / Unpin**, or **left** for the **Delete** and **Pin / Unpin** action menu. Pinned chats show a pin and stay above other conversations. Delete asks for confirmation and removes the conversation from the Watch list and Saved messages, including after future syncs; its iPhone/Muse copies and recordings are preserved. Send/discard a draft or finish sending before deleting its chat. Pins and removals are saved on this Watch and work offline. After deleting the last chat, use **Chats → New chat**.

**Older voice replies:** tap **Get voice reply** on either device to try Muse’s existing MP3 stream for that saved assistant message. This does not repost your note or require replaying the historical chat subscription. **Sync voice reply** copies an already cached phone reply to Watch. Some older text-only messages have no voice stream; text stays readable if audio is unavailable. Keep iPhone open for long downloads, and use the Watch’s available speaker/headphone route for playback.

Watch playback uses Apple’s long-form audio routing: supported models can use the built-in speaker, while other models need a Bluetooth output. Speaker playback is unavailable while the Watch is charging. See [Apple’s Watch audio routing guidance](https://developer.apple.com/documentation/avfaudio/avaudiosession/activate(options:completionhandler:)).

**Background delivery:** a real Watch recording and reply completed with the iPhone on its Home screen. Longer replies can exceed iOS background time; open Muse Watch on iPhone and keep it open for those. If a reply already finished while disconnected, read it in official Muse. See [delivery states](#delivery-states-and-background-behavior).

### Let an AI agent help with setup

Open this repository in a local coding agent that can use the Mac terminal and Xcode. Give it your Pi’s SSH address and username, and connect your iPhone and Watch. The agent can check requirements, build and install the apps, prepare the Pi helper over SSH, transfer setup files, run tests, and diagnose delivery. It needs access to those tools and devices; a chat-only assistant cannot install the app for you.

You handle Apple/Muse sign-in, passwords, device unlocks, Trust prompts, Developer Mode confirmations, and pairing approval in official Muse. Enter the SDK token yourself at the helper’s hidden terminal prompt. Do not paste passwords, SDK tokens, or private keys into the agent chat.

Copy this prompt and replace the placeholders:

```text
Help me install and authenticate Muse Watch on my own iPhone and Apple Watch.

Repository: /path/to/muse-watch
Pi SSH address: my-user@my-pi.local
Current setup: first-time setup / already installed and paired

Read README.md, TESTING.md, and PiSetup/README.md first. Check my local
requirements and existing setup, then carry out the applicable steps.

- Preserve existing pairing, credentials, history, recordings, and local changes.
  If already paired, skip provisioning; do not disconnect or reset my account.
- Use the full Xcode toolchain, configure matching companion targets with my
  signing team, and build/install on my physical devices when available.
- For first-time authentication, prepare the Pi before creating the ten-minute
  request. Use this repository's pairing-only helper, not the full Muse daemon.
- Tell me when I must unlock a device, confirm a system prompt, approve Muse
  pairing, or enter the SDK token privately. Never print or commit credentials.
- Transfer the public request and encrypted handoff to the correct devices.
- Run local tests, then guide me through a real Watch recording and reply.
  Check a short exchange with the iPhone on its Home screen too. Do not treat
  simulator output or a send acknowledgement as proof that a reply arrived.
- Report what actually passed, anything blocked, background limits, and when
  the development build needs renewal. Leave normal use independent of the Pi.
```

Keep the devices nearby during setup. If the agent cannot access a device or SSH session, have it prepare the remaining steps and give you the exact action needed to continue. Requirements and the manual setup path follow below.

## Requirements

| Requirement | What you need |
|---|---|
| Mac for building/installing | Full Xcode with iOS and watchOS SDKs and support for the OS versions on your devices. Command Line Tools alone are insufficient. Python 3 is needed only if regenerating the project. |
| iPhone | iOS 17 or later, internet access, and the official Muse app signed into your account. |
| Apple Watch | watchOS 10 or later, paired to that iPhone. Microphone permission is required for voice notes. |
| Development signing | An Apple account signed into Xcode, a signing team selected for both app targets, and Developer Mode enabled on both devices. A Personal Team was used here. |
| Muse authentication | A working Muse account, access to **Settings → Devices → Developer mode** in official Muse, and an `mgst_…` SDK token for initial pairing. Get the token from [Muse Gadgets → SDK tokens](https://gadgets.muse.ai/settings/sdk-tokens). |
| One-time pairing host | A nearby Linux computer with BlueZ and a Bluetooth LE controller capable of peripheral advertising. Raspberry Pi 4 is the verified option. It needs internet access, Python 3.10+, `cryptography`, `dbus`, and `gi`. |
| Device access during setup | iPhone USB connection for initial Mac trust, both devices unlocked when Xcode prepares or launches them, and local access to confirm system prompts. SSH is sufficient to operate the Pi. |

Verified on **Xcode 27.0**, a physical **iPhone 17 Pro / iOS 27**, **Apple Watch Ultra 2 / watchOS 27**, and **Raspberry Pi 4 / Debian 13**. The deployment targets above are lower than the tested device versions; those older versions have not been tested on physical hardware. Swift protocol tests require macOS 14 or later.

The native apps use Apple frameworks and have no third-party package dependencies to install. You do not need CocoaPods, Node.js, the full Linux Muse service, a hosted backend, or an always-on Pi.

## First-time setup

Complete installation and Pi preparation **before** creating the iPhone setup request: its ten-minute expiry covers pairing and import.

### 1. Install the iPhone and Watch apps

On your Mac, clone the repository if needed:

```sh
git clone https://github.com/breno12321/muse-watch.git
cd muse-watch
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
open MuseWatch.xcodeproj
```

Skip clone/cd if you already have the checkout. If Xcode is installed elsewhere, adjust `DEVELOPER_DIR` in all commands below.

1. Sign into **Xcode → Settings → Accounts**. Copy `Configuration/Local.xcconfig.example` to `Configuration/Local.xcconfig` and replace `YOUR_TEAM_ID` with your Apple Development team identifier. This local file is ignored by Git and applies to both targets. In **Signing & Capabilities**, confirm automatic signing and the same team for **MusePhone** and **MuseWatch**. For a separate developer’s installation, use a unique iPhone bundle identifier and a Watch identifier prefixed by it; also update `WKCompanionAppBundleIdentifier` in the Watch Info.plist. Keep the identifiers stable on later updates.
2. Connect and unlock your iPhone by USB. Accept **Trust This Computer** and let Xcode finish preparing it.
3. On iPhone, enable **Settings → Privacy & Security → Developer Mode**, restart, and confirm it after restart.
4. Pair the Watch to your iPhone normally. Pair it with Xcode’s device tools as well. In the tested Xcode version, this is **Device Hub → + → Pair Nearby Device**. If Watch Developer Mode is missing, begin this development pairing first, then check **Watch Settings → Privacy & Security → Developer Mode**. Restart and confirm.
5. Select the **MusePhone** scheme and your physical iPhone, then Run. This target builds the iPhone companion and embeds the Watch app.
6. If iOS blocks launch as an untrusted developer, open **Settings → General → VPN & Device Management → Developer App**, select your Apple account, and complete the Trust or Allow & Restart flow shown by iOS.
7. If the Watch app has not appeared, select **MuseWatch** and your physical Watch in Xcode, then Run directly. Keep both devices unlocked during preparation and launch.

Both apps are named **Muse Watch**. An earlier standalone prototype may remain as a separate **Muse** icon; use **Muse Watch** for live messaging. The browser preview is also a separate design demo.

### 2. Prepare the Raspberry Pi

On your Mac, replace the SSH address below with your Pi’s address. A LAN hostname or Tailscale hostname works; the Pi still needs to be physically near the iPhone for Bluetooth pairing.

```sh
PI_HOST="your-user@your-pi.local"
ssh "$PI_HOST" 'mkdir -p ~/muse-watch-setup'
scp -r PiSetup/* "$PI_HOST:~/muse-watch-setup/"
ssh "$PI_HOST"
```

In the Pi’s SSH terminal, install dependencies if needed:

```sh
sudo apt-get update
sudo apt-get install -y bluez rfkill python3 python3-cryptography python3-dbus python3-gi
sudo systemctl start bluetooth
sudo rfkill unblock bluetooth
bluetoothctl power on
/usr/bin/python3 -c 'import cryptography, dbus; from gi.repository import GLib; print("Pairing dependencies ready")'
```

Use the Pi’s system Python so the apt-installed D-Bus and GI modules are available. Run the pairing helper as your normal SSH user. That user must be allowed to register BlueZ GATT services and advertisements. Do not install the upstream full Muse daemon for this setup: this repository’s helper only pairs and exports encrypted credentials.

### 3. Pair Muse and return the encrypted setup

1. On iPhone, open **Muse Watch → Connect your Muse → Create a fresh request → Share setup request**. AirDrop the `.muserequest` file to your Mac.
2. On your Mac, send the received file to the Pi. Replace the source path with the actual downloaded filename:

   ```sh
   PI_HOST="your-user@your-pi.local"
   scp ~/Downloads/MuseWatch-REQUEST-ID.muserequest "$PI_HOST:~/muse-watch-setup/request.muserequest"
   ```

3. In the Pi SSH terminal, run:

   ```sh
   cd ~/muse-watch-setup
   /usr/bin/python3 pair.py --request request.muserequest --output MuseWatch.musepair
   ```

4. Enter the `mgst_…` SDK token at the **hidden prompt**. In official Muse on your nearby iPhone, open **Settings → Devices**, enable **Developer mode**, then **Add Device**. Select the exact `MuseGadgetXXXXXX` name printed by the helper and confirm pairing. Choose **Pi internet (already connected)** if asked for Wi-Fi.
5. Wait for **Paired. Encrypted setup saved.** The helper validates the provisioned credentials and stops. In a terminal on your Mac, retrieve the encrypted file:

   ```sh
   PI_HOST="your-user@your-pi.local"
   scp "$PI_HOST:~/muse-watch-setup/MuseWatch.musepair" ~/Downloads/MuseWatch.musepair
   ```

6. AirDrop that `.musepair` to the **same iPhone that created the request**. Open it with Muse Watch, or use **Connect your Muse → Import encrypted setup** and choose the file. Wait for account validation to finish.

**Finish within ten minutes of creating the request**, including import. If it expires, create and transfer a new request and repeat pairing. The helper refuses to overwrite an existing output file; use a new `--output` filename on another attempt and retrieve that matching filename.

The SDK token enables pairing; it is **not a standalone chat API bearer key**. Pasting it into the Watch does not authenticate this app. Pairing provisions the device identity and access/refresh credentials that the iPhone needs. Enter tokens only at the helper’s private prompt, not in commands, chat, source files, or Git.

### 4. Confirm the whole flow

1. Open Muse Watch on iPhone and confirm it is connected. Send a short text in one conversation and check for a real Muse reply.
2. Open Muse Watch on Watch, wait for sync, then record and send a short note. Confirm it opens chat and the reply arrives.
3. Return iPhone to its Home screen without force-quitting the companion. Repeat a short Watch exchange to check background delivery on your setup.
4. Stop using the setup helper. Normal messaging now needs only the paired iPhone and Watch.

To check credential renewal separately, use **Renew Muse connection** on iPhone while the app is idle. Then send another short message. Detailed device checks are in [TESTING.md](TESTING.md).

## Delivery states and background behavior

| What the Watch shows | What it means / what to do |
|---|---|
| **Waiting for iPhone** | Saved in the Watch outbox. Keep the paired phone nearby; reconnect or open the companion and use **Sync Watch & retry connection** if it stays queued. |
| **On iPhone / Connecting / Sending** | The phone saved the request and is working on delivery. Wait; do not send a second copy. |
| **Sent · waiting for Muse** | Muse acknowledged the message. The reply is still being received. |
| **Sent** | This turn completed. Captured replies remain readable offline. |
| **Delivery uncertain · not resent** | Submission may have succeeded before the connection ended. Check official Muse before manually sending anything again. |
| **Sent · open Muse for reply** | Muse accepted it, but reply capture was interrupted. Open the iPhone companion to listen if the turn is still running; check official Muse if it already finished. |

Voice notes try an immediate transfer in small verified chunks, with a scheduled file transfer as fallback. The phone acknowledges only after saving the complete recording. Duplicate deliveries share a request ID and do not create another Muse post. An accepted or potentially submitted message is never automatically resent.

iOS allows finite background execution, not an unlimited live Muse connection. Short background exchanges are physically verified; long replies remain conditional on available execution time. Force-quitting the companion can prevent background wake-up. After restarting the iPhone, unlock it once before expecting background access to its saved credentials.

## Troubleshooting — lessons from the actual setup

| Problem | Fix / lesson learned |
|---|---|
| `xcrun` cannot find `simctl`, or tools use Command Line Tools | Set `DEVELOPER_DIR` to the full Xcode app’s `Contents/Developer`, as above. |
| Xcode sees only simulators | Connect the phone by USB, unlock it, accept Mac trust, and finish device preparation. Pair the Watch for development separately. |
| Developer Mode enabled but launch still blocked | Finish the restart confirmation. Developer Mode, Mac trust, and trusting the installed developer app are separate steps. |
| Watch Developer Mode is missing | Begin development pairing with Xcode’s device tools, then recheck the Watch’s Privacy & Security settings. |
| Developer Mode is on but Muse’s Add Device flow is unavailable | Apple’s device Developer Mode and **official Muse → Settings → Devices → Developer mode** are separate settings. Enable the Muse setting for gadget pairing too. |
| Mac says it is advertising, but Muse finds no gadget | This occurred here: an iPhone scan saw the service but no usable name or SDK manufacturer flag. Successful macOS advertising did not mean Muse could discover it. Use the verified Pi helper. |
| Pi pairing device is not visible | Keep it near the iPhone, unblock Bluetooth with `rfkill`, power the controller on, and confirm the helper is still running within the request window. SSH reachability alone does not establish Bluetooth proximity. |
| Python cannot import `dbus` or `gi` | Install the apt packages above and run `/usr/bin/python3`, rather than an isolated Python environment without those packages. |
| Setup expired, wrong recipient, or output already exists | Make a fresh request on the intended iPhone, transfer that exact request, pair again, and choose a fresh output filename. Old encrypted files cannot be reused for a new request. |
| AirDrop does not list the iPhone | Unlock it and temporarily enable **AirDrop → Everyone for 10 Minutes**. Import the encrypted file before its setup window expires. |
| Messages appear in official Muse but the Watch has no reply | Check the delivery label. Longer replies may have outlived iOS background time; read completed missed replies in official Muse. Do not resend just to fetch a reply. |
| Tapping Talk to Cal opens review instead of recording | There is an unsent draft. Send, keep, or discard it before starting a new recording. |
| Personal development build stops opening | Rebuild and reinstall with Xcode when its provisioning profile expires. This installation’s profile was recorded as expiring **24 October 2026**; check your own profile rather than treating that date as universal. |

## Authentication, updates, and data

The Pi exports an encrypted handoff bound to the iPhone request. Verified credentials stay in the **iPhone Keychain**; the Watch receives conversation data, never Muse tokens. The iPhone refreshes credentials when needed and uses the SDK’s encrypted Noise transport to connect to Muse. The Pi helper does not run remote shell/file commands or leave a messaging service behind.

For updates, install over the existing apps with the same signing identity and bundle identifiers to retain the existing pairing and local history. Do not uninstall or disconnect the account as a routine update step. This installation uses:

| Target | Bundle identifier |
|---|---|
| MusePhone | `dev.breno.musewatch.phone` |
| MuseWatch | `dev.breno.musewatch.phone.watchkitapp` |

Muse replies render native Markdown: headings, emphasis, lists, links, quotes, code, and tables. On Watch, tables become stacked label/value cards to fit the screen. User-written text stays literal. Remote images show their alt text rather than being downloaded.

Local data includes conversations, bookmarks, recordings, and recoverable drafts. The native apps contain no sample conversations or scripted replies. Setup request/envelope files and recordings are excluded by `.gitignore`; keep account data and private test captures out of commits too.

Reply audio is requested with the SDK’s voice modality and downloaded as bounded MP3 through the registered, encrypted iPhone connection (`/api/voice/tts-stream`, with the SDK’s legacy fallback). Complete files are decoded and saved before being transferred. Account/chat/message scope and SHA-256 are checked on Watch. Muse tokens and remote media URLs are never sent to Watch. A failed audio fetch leaves the reply text intact and cannot trigger a message resend.

## Current scope

- **History:** conversations captured by this companion, with a compact recent Watch mirror and fuller local history transferred on sync. Earlier iOS account history is not imported through an undocumented API.
- **Conversations:** Home has Voice note and Chats. Start independent chats on either device; previous conversations, including older Check-in/Ideas/Goals chats, remain in the chat list. Saved messages are local Watch bookmarks under Settings. The iOS section databases are not imported.
- **Avatar:** choose a picture manually on iPhone. Automatic account-avatar retrieval is not documented by the referenced SDK. The default Cal artwork is a personal reference asset from the installed Muse app, separate from the SDK license.
- **Connectivity:** this implementation requires the paired iPhone. It is not a standalone cellular Watch client.
- **Distribution:** a development-signed personal app, not an App Store/TestFlight distribution. Simulators and the browser preview do not prove real-device pairing or background behavior.

Agent guidance is in [AGENT.md](AGENT.md). Keep personal signing configuration, device captures, and recordings out of commits.

## Development and verification

From the repository root on Mac:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
./scripts/test.sh
```

`swift test` covers authentication/crypto fixtures, message correlation, WAV payloads, durable deduplication, recovery, bounded immediate audio assembly, first-message chat adoption, reply-audio integrity/bounds, GET framing, scoped topic metadata, and editable names. `scripts/test.sh` also checks offline audio caching, file/snapshot ordering, account isolation, chat creation, selected-chat persistence, draft destinations, sync races, and old archive compatibility. Neither command needs an SDK token or sends messages to Muse. The latest run passed **35 protocol tests** and the Watch model checks.

To compile both device targets without installing or signing:

```sh
xcodebuild -project MuseWatch.xcodeproj -scheme MusePhone \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/muse-watch-build \
  CODE_SIGNING_ALLOWED=NO build
```

Signing and physical installation still use Xcode as described above. If you add Swift source files, run `python3 scripts/generate_project.py`; it rebuilds the project’s file list and embedded Watch dependency while preserving the selected team in the ignored `Configuration/Local.xcconfig`. Bundle identifiers are defined in that script, so update it too if using your own identifiers. Debug arguments `--screen-chat`, `--screen-voice`, and `--screen-chats` select screens within the normal navigation hierarchy, so Back always leads to a real parent; the voice screen starts real recording when no draft exists. They do not fabricate replies or send messages by themselves. Install matching iPhone and Watch updates to enable Watch-created conversations.

Implementation lessons worth preserving:

- Save the request before acknowledging it, and save submission state before posting; interrupted delivery must not silently repost.
- Copy incoming WatchConnectivity files before their delegate returns, since the system removes the temporary file afterward.
- An SDK token is for provisioning, and the provisioned device identity must travel with its credentials.
- Subscribe to the correct conversation; when the first post creates a side chat, open its scoped stream before retiring the previous stream.
- Match the SDK’s empty-string handling: an empty `reply_to_message_id` must fall back to the parent ID or be treated as absent. This caused a real case of replies visible in official Muse but missing from our app.
- A successful local build, BLE advertisement, or message acknowledgement alone is insufficient: verify the real reply on both devices, including a phone-background test.

See [Verification/REPORT.md](Verification/REPORT.md) for the chronological evidence, [recording-experience-results.json](Verification/recording-experience-results.json) for the latest content-free device results, and [PiSetup/README.md](PiSetup/README.md) for helper details.

## Reference and attribution

Protocol reference: [facebookincubator/muse-gadget-sdk](https://github.com/facebookincubator/muse-gadget-sdk), pinned to `f60347aeb851a1fe9438cfc388721776aa24f275`. SDK notices and Apache-2.0 attribution are in [ThirdParty/NOTICE.md](ThirdParty/NOTICE.md) and [ThirdParty/MuseGadgetSDK-LICENSE](ThirdParty/MuseGadgetSDK-LICENSE). Avatar artwork and the Muse logo used in the personal companion icon are separate. Icon design provenance is in [Design/phone-icon.md](Design/phone-icon.md).

`Preview/` contains the original browser design demo. `MuseSetup/` retains the Mac feasibility helper; the Pi route above is the verified first-time pairing path.

## License

Project source code is licensed under the [Apache License 2.0](LICENSE). Third-party code retains its existing copyright and attribution notices. Muse branding and avatar artwork are excluded from this license grant; see [ThirdParty/NOTICE.md](ThirdParty/NOTICE.md) and [icon provenance](Design/phone-icon.md).
