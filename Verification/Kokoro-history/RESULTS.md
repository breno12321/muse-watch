# Kokoro feasibility results — 2026-10-17

Historical report from before the English production integration. The experiment
apps and project were removed after validation at the user's request. Statements
below describe that earlier trial, not the current release; see the
[integration results](../SPEECH-REPORT.md) for current behavior. Only this report
and its content-free measurements are retained.

**Decision: continue private research; no production rollout for either language yet.** The main Muse Watch experience stays text-only. The prototype is installed as **Kokoro Lab** on the test iPhone and Watch. This is the explicitly gated outcome from the implementation plan, not a claim that the production Listen feature is complete.

## Generation baseline

Physical iPhone 17 Pro, iOS 27.0, Release build with Xcode 27, launched with `devicectl` without a debugger. The corpus is synthetic; no Muse messages or account data were used. Foreground baseline has 40 attempts, ten texts per language in both requested voices. [Raw content-free results](foreground-results.json) retain stage timings and failures.

| Measurement | Observed |
| --- | --- |
| English generation | 18/20; both voices fail the same proper-name sample containing “Breno” |
| Brazilian Portuguese generation | 20/20; successful encoding is **not** pronunciation approval |
| First cold run, including model/dictionary load | 8.97 s total, 7.91 s loading |
| Warm English, median / maximum | 1.35 s / 5.22 s |
| Warm Portuguese, median / maximum | 1.32 s / 5.67 s |
| Longer prose, four voices | 4.58 / 5.22 / 5.46 / 5.67 s |
| Peak process resident memory | Approximately 759 MiB; a substantial optimization concern |
| Reported thermal state | Nominal throughout this batch |
| Largest generated M4A | 214,210 bytes; below the existing 3 MiB transfer cap |
| Stage policy | CPU + Neural Engine throughout; `postAlbert` fell back to CPU-only for the final two `pm_alex` cases |
| Energy / sustained thermal impact | Not measured; nominal thermal state is not an energy benchmark |

Cold model loading here is a fresh app worker with compiled assets already prepared. It does not measure first-ever device compilation. Baseline `elapsedMS` includes pronunciation and encoding; baseline `generationMS` predates the adjustment to include pronunciation, so use `elapsedMS` for end-to-end comparisons. CPU/ANE configuration allows CPU execution and is not proof that each operator ran on the Neural Engine.

The first upstream Python conversion attempt crashed during a GPU benchmark. Restricting the converter to CPU/ANE produced all seven packages, but Python's final chain hit a `PostAlbert` BNNS shape error. The adapted Swift pipeline successfully exercised all seven packages on the device; it records explicit CPU-only fallback where needed. Numerical equivalence to Python is not established.

## Background and Watch

The dedicated 20-trial batch uses fresh synthetic request identities, ten short English and ten short Portuguese replies, so cached audio does not make generation look faster. iPhone was initially returned Home and locked through Device Hub; no debugger was attached. Foreground/background logs were checked afterward rather than assuming the devices stayed in that state. The trial runner requires the Watch research app to remain foreground. Every transferred file is bounded and SHA-256 checked, copied before the callback returns, and never automatically played.

The first batch had 20/20 successful transfers, but only 12 jobs were backgrounded at both start and finish; 8 saw the iPhone app foregrounded. The 12 entirely backgrounded jobs reached Watch in 2.67–13.25 seconds (median 8.75 seconds). It is not a valid 20-trial locked-phone pass. A controlled repeat uses v2 of the pronunciation adapter. The controlled repeat was interrupted: 4 successful transfers, only 1 entirely backgrounded, followed by 16 rapid connection errors. The Watch was observed outside the test app. This is not a valid locked-phone pass either. [Repeat raw results](background-repeat-results.json) retain the failure. The runner now stops after its first connection error instead of immediately exhausting the batch. [First-batch raw results](background-results.json) are retained rather than discarded. Do not infer long-idle reliability from consecutive requests. Watch readiness includes synthesis and file transfer; the 45-second failure deadline is separate from the 20-second performance target.

## Quality and language gates

- **English: no-go for production.** Swift Misaki fails unknown names rather than silently omitting them. A broader native pronunciation strategy or verified dictionary coverage is required. User assessment of the initial English sample was positive; full corpus/name coverage remains incomplete.
- **Portuguese: no-go for production pending assessment and dependency clearance.** All corpus samples generated with native `pt-br` pronunciation, including combining nasal phonemes. The user assessed English as good and Portuguese as needing work. Review found missing punctuation in the native adapter; v2 preserves punctuation and uses explicit phoneme tie markers. The corrected version needs a new listening assessment. eSpeak NG plus ucd-tools introduces GPL obligations; the combined build stays private and isolated.
- Voice auditions are under ignored `.local/report/audition.html` when generated with `summarize.py`. The failed English name cases are shown explicitly. Samples are Kokoro, never labeled as Muse's original voice.

## Acceptance coverage

| Check | Status |
| --- | --- |
| Arbitrary text → phonemes → seven stages → mono AAC | Exercised on Mac and physical iPhone; English unknown-name limitation remains |
| Voice row indexing / nasal scalars / strict unknown rejection | Five focused tests pass, including Markdown cleanup and cache identity |
| Markdown prose/link labels; code/raw URL omission | Tested; unfinished fenced blocks omitted too |
| Changed text, account, language, voice, model identity | Cache-key test passes; real account-change integration is deferred |
| CPU/ANE execution without GPU | Enforced; stage fallback recorded |
| Durable request/chunk checkpointing | Implemented in research harness; interruption/resume device matrix not fully exercised |
| Background Watch batch | Not passed: first batch mixed foreground/background; repeat interrupted |
| Long idle, disconnection, interrupted transfer, force-quit, reboot before first unlock | Not validated; must pass before integration |
| Explicit playback / no automatic playback | Controls implemented; audible Watch playback and offline replay need user confirmation |
| Model memory release under pressure | Cancellation + release implemented; real memory-pressure recovery not validated |
| Existing messaging, recordings, ordering, refresh, pins, archives | Production code untouched; 53 protocol tests and all eight Watch model check groups pass |
| Licensing | Source findings documented; distribution gate remains closed |
| Energy, sustained battery impact | Not measured |

Production integration stays deferred: resolving completed replies inside the current account, giving delivery/transcription priority, settings, backward-compatible audio metadata, lifecycle/deduplication tests, cache eviction and recovery UI. Do not merge the experiment into the production target to bypass these gates. No cloud TTS or automatic Apple-voice fallback was added.

## Portuguese correction (v2)

After the first listening assessment, the native adapter was changed to preserve punctuation and use explicit IPA tie markers before Kokoro substitutions, matching the reference approach. Numeric separators stay inside the phrase so eSpeak can expand dates/currency. The cache generation version changed, preventing reuse of v1 speech. Five focused tests and the physical-device Release build pass. A fresh Mac corpus run again generated 38/40 samples (the same two English-name failures); all 20 Portuguese files generated. [Mac v2 metrics](mac-v2-results.json) are separate from the original iPhone measurements. Revised Portuguese voice quality is not yet approved.
