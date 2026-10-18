# Production English speech assets

These are build inputs for MusePhone, not a separate app or test project. Only
the seven Kokoro model packages, English `af_heart` voice, vocabulary and pinned
Swift Misaki pronunciation package are staged. Downloaded files remain ignored.

An existing prepared checkout needs only:

```sh
python3 scripts/prepare_speech.py
python3 scripts/generate_project.py
```

For a fresh checkout, use an Apple Silicon Mac, full Xcode, Python 3 and `uv`:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 scripts/convert_speech.py sources
python3 scripts/convert_speech.py convert
python3 scripts/prepare_speech.py
python3 scripts/generate_project.py
```

The source and model revisions are fixed in `convert_speech.py`. The conversion
environment is locked in `conversion.uv.lock`; the config, weights and single
voice are SHA-256 checked against `download-checksums.json`. Public model downloads
disable implicit credentials. No eSpeak native library, Portuguese voice or
standalone app target is prepared. Python conversion dependencies are build-time
only and are not shipped in MusePhone or MuseWatch.

Conversion can consume several GB and takes longer than a normal build. The pinned
upstream converter previously wrote all seven packages and then failed its final
Python chain validation. If that happens, inspect the failure and packages before
explicitly running `python3 scripts/convert_speech.py collect-models`. This seals
local artifacts; it does not turn the failed Python validation into a pass.
Validate the resulting models with the Swift synthesis test and device build.

Prepared assets live in `.local/speech`; conversion scratch files live in
`.local/speech-conversion`. `prepare_speech.py` verifies existing resources without
reconverting them. After intentionally rebuilding conversion inputs, use
`python3 scripts/prepare_speech.py --replace` to stage them. Local manifests detect
later modifications; they do not promise byte-identical Core ML conversion across
toolchains. Xcode compiles packages for the destination platform.

To run the real synthesis/cache test on Mac without another app or repository:

```sh
python3 scripts/prepare_speech.py --compile-mac
KOKORO_TEST_ASSETS="$PWD/.local/speech/mac" swift test --package-path LocalSpeech
```

See [speech notices](../../LocalSpeech/NOTICE.md), the
[integration results](../../Verification/SPEECH-REPORT.md) and the retained
[historical findings](../../Verification/Kokoro-history/RESULTS.md). The research
apps, their generated projects and their private sample files have been removed.
