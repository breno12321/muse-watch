# Local English speech

Personal device integration of the Kokoro experiment. This feature uses only the
Swift English pronunciation package and `af_heart`; eSpeak, ucd-tools, Portuguese
voices and the upstream MLX runtime are not linked or bundled.

- The adapted seven-stage engine is from laishere/kokoro-coreml revision
  `484907db6a8347a6afb6e7b86850ea2878c6a3fb`, Apache-2.0. See LICENSE-CoreML.
- Model weights and voice are hexgrad/Kokoro-82M revision
  `f3ff3571791e39611d31c381e3a41a3af07b4987`, declared Apache-2.0 by its model card.
- Swift Misaki and dictionaries come from mweinbach/kokoro-swift revision
  `20bf04c506e913ff129d7d2229398180ba24c690`, under the repository's Apache-2.0
  license. The preparation script bundles its license with the phone resources.

The experiment's dependency findings and unresolved dictionary/voice provenance
review still apply before distribution. This change does not authorize TestFlight
or public binary distribution or change the repository license. See
[historical dependency findings](../Verification/Kokoro-history/NOTICE.md) and
[experiment results](../Verification/Kokoro-history/RESULTS.md).

Source preparation: follow the [production asset instructions](../scripts/speech/README.md),
then run `python3 scripts/prepare_speech.py` from the repository root. Compiled
models, packages and voice tensors stay in ignored .local directories. Xcode
compiles the model packages separately for its destination; Mac-compiled assets
are never copied into the iPhone app.
