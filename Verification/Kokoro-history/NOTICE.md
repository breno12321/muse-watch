# Kokoro research dependency findings

Historical notice retained after removal of the experiment apps and project.
The current English-only integration is described in [LocalSpeech/NOTICE.md](../../LocalSpeech/NOTICE.md).

This directory is an isolated personal-development experiment. It does not change the repository license. Do not distribute the combined native-pronunciation app, add it to the production app, or upload it to TestFlight until the dependency gate has been resolved. No upstream source tree or model binary is checked in here.

| Component | Pinned input | Findings |
| --- | --- | --- |
| Seven-stage conversion and adapted Swift engine | [laishere/kokoro-coreml](https://github.com/laishere/kokoro-coreml/tree/484907db6a8347a6afb6e7b86850ea2878c6a3fb) | Apache-2.0; retained [license](../../LocalSpeech/LICENSE-CoreML). The adapted engine uses CPU/ANE-only loading, cancellation, scalar tokenization, corrected voice indexing, shape bounds, and stride-safe extraction. |
| Weights and voice vectors | [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M/tree/f3ff3571791e39611d31c381e3a41a3af07b4987) | Model card declares Apache-2.0. Four voice tensors and weights/config are pinned and SHA-256 checked by `download-checksums.json`. Full training-data/voice provenance is not independently audited. No voice cloning. |
| Swift Misaki and its bundled dictionaries | [mweinbach/kokoro-swift](https://github.com/mweinbach/kokoro-swift/tree/20bf04c506e913ff129d7d2229398180ba24c690/Packages/Misaki) | Repository has Apache-2.0 license. The embedded package has no separate license file. Dictionary provenance and required notices need independent confirmation before distribution. Only this local package is linked; the parent MLX runtime is not used. |
| Native Portuguese pronunciation | [eSpeak NG](https://github.com/espeak-ng/espeak-ng/tree/ba90c8e9f440ad544f674a790bb5f53878b6ffc5) | GPL-3.0-or-later notices in source; COPYING is GPLv3. Static library and pronunciation data remain in ignored `.local/`. This is a distribution gate, not a reason to silently relicense Muse Watch. |
| Unicode helper linked by eSpeak | Same eSpeak checkout, `src/ucd-tools` | GPL-3.0-or-later code; Unicode data has its own notice in COPYING.UCD. eSpeak also includes BSD-2 and Apache notice files. Preserve the entire upstream notice set with any permitted distribution. |
| Python conversion environment | `conversion.pyproject.toml`, `conversion.uv.lock` | Versions and registry hashes locked. Build-time only; not shipped in either app. The full transitive license audit is pending. |
| Apple frameworks | Core ML, NaturalLanguage, AVFoundation, WatchConnectivity | System frameworks. Core ML configuration uses `.cpuAndNeuralEngine`, then explicit `.cpuOnly` if a stage throws. No `.all` or GPU fallback. This does not grant unrestricted background execution. |

The Portuguese IPA substitutions follow the Kokoro mapping in the installed `misaki==0.9.4` Python package (`misaki/espeak.py`), rather than treating arbitrary eSpeak phonemes as Kokoro tokens. Unknown tokens fail explicitly. Generated Swift audio is not asserted to be numerically equivalent to upstream Python; the stochastic noise stage and toolchain differences need separate fidelity checks.

Source references: [upstream voice catalog](https://huggingface.co/hexgrad/Kokoro-82M/blob/f3ff3571791e39611d31c381e3a41a3af07b4987/VOICES.md), [Apple compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine), [finite background tasks](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)), [WatchConnectivity sendMessage](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)).

## Gate result

**Personal research only. No production/distribution approval.** Portuguese cannot be declared ready solely because voice files exist or synthesis succeeds. Pronunciation quality, listening assessment, background reliability and dependency clearance are independent requirements. English also fails the names coverage test with the current Swift Misaki dictionaries. The main app remains text-only until both languages pass.
