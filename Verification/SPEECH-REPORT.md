# English local speech — 17 October 2026

## Implemented

Completed Watch replies offer Generate audio, progress/recovery states, and
explicit Play/Pause with duration. Kokoro `af_heart` runs locally on iPhone.
Unrecognized English names are spelled, and original reply text is retained.
Requests, cache identity and files are account/chat/message/text scoped. The
feature does not send another Muse message, fetch Muse audio, or autoplay.

## Automated and build results

- 57 protocol tests passed, including speech identity, completion, compact
  snapshot hashes, legacy decoding and transfer validation.
- All nine Watch-store check groups passed, including durable speech requests,
  duplicate taps, file-before-status delivery, relaunch/replay, stale text,
  rejection, account isolation and failed-write rollback.
- Six English speech tests passed, including actual seven-stage synthesis and
  cache replay, the previously failing name, numbers/currency, chunk bounds,
  Markdown cleanup and unsupported input. Actual synthesis used synthetic text.
- Signed Release iPhone and Watch builds passed and the final apps were installed on both devices, preserving their existing application identities. The iPhone bundle contains all
  seven compiled models; Watch contains none. No eSpeak/ucd or Portuguese assets
  are bundled. Measured bundles were approximately 100 MiB and 4.6 MiB.

## Physical checks and limits

The isolated Speech Check bundles used the production relay, speech
coordinator, Watch store and controls with synthetic initialization. They have
separate application identities and no production account/container access.
No live Muse messages were sent.

- Observed Generate audio and Waiting/Generating states on Apple Watch Ultra 2.
  Chat navigation and vertical drag scrolling worked with a real parent screen.
- The first cold request with iPhone 17 Pro backgrounded/locked paused after
  approximately 26.6 seconds when background time expired. This is a failed
  readiness trial, not a background reliability pass.
- Opening the synthetic iPhone app resumed the saved job; generation completed
  in approximately 1.64 seconds and its state became ready.
- A fresh foreground generation after the final rebuild took approximately
  21.90 seconds, including model initialization. It was separate from the
  measured background batch below.
- After foreground initialization, a fresh 20-request batch passed with iPhone
  locked and no debugger: **20/20 ready on Watch within 20 seconds**. End-to-end
  readiness ranged from **5.68 to 14.50 seconds**, with a **7.20-second median**.
  Joined phone/Watch reports confirm background state at both ends of all 20
  syntheses, unique message/cache identities and no duplicate generations.
- Watch Play/Pause and advancing playback progress were observed. This confirms
  player operation; speaker audibility and voice quality require listening on
  the physical device.
- Relaunched the Watch verification app with its connectivity client disabled.
  Cached replies remained available, Play entered playback, Pause showed Resume
  with retained progress, and Resume returned to playback. No phone request was
  possible in this isolated replay configuration. This is app-transport offline
  replay, not a radio-disconnection test.
- Starting voice input stopped generated playback. The automated UI test selected
  Don't Allow for the isolated app's microphone, and the existing actionable permission error appeared;
  no recording was made or submitted. Successful recording interruption still
  needs a microphone-authorized physical check. Production microphone permissions
  were not changed.
- Device inspection also motivated a final fix: the expiration handler now
  saves the pause and ends its assertion synchronously; Watch offers recovery
  after 45 seconds even if a status update is lost. These changes were included
  in the successful 20-request batch.

First-use model initialization may need the iPhone app foregrounded. Long-idle,
radio-disconnection, actual OS memory-pressure recovery and sustained battery
impact remain unverified. Existing experiment reports remain historical evidence,
not a claim that this integration has passed all device gates. Reproduction steps
are summarized in [TESTING.md](../TESTING.md#local-english-speech-verification).

## Cleanup after validation

At the user's request, Kokoro Lab and Speech Check were removed from both devices,
leaving the production Muse Watch app on iPhone and Watch. Their source/generated
projects, test-app generator, private captures, sample audio and build outputs
were removed from the project. Historical content-free results and upstream
notices remain as documentation. Production speech preparation now uses its own
pinned conversion tooling and no longer depends on the removed experiment.
Post-cleanup device inventories confirmed only the production app identity on
each device. The repository contains only MuseWatch.xcodeproj and no nested Git
repositories. Both signed Release targets rebuilt successfully, and all six
speech tests passed using production-only assets, including actual synthesis and
cache replay. The conversion toolchain was retained; the expensive upstream
Python conversion was not repeated during cleanup.
