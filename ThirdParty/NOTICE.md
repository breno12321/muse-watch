# Muse gadget protocol reference

The pairing, Noise transport, framing and chat protocol implementations in Shared are adapted from Meta Platforms, Inc. and affiliates' muse-gadget-sdk, revision f60347aeb851a1fe9438cfc388721776aa24f275 (Apache-2.0).

Source: https://github.com/facebookincubator/muse-gadget-sdk

The public synthetic pairing fixtures retain their upstream contents. See MuseGadgetSDK-LICENSE. Character artwork in the existing prototype is separate and is not covered by this license.

`PiSetup/vendor/musegadget` contains unchanged pairing, BLE, identity and configuration source files from the same pinned revision. Its source copyright headers are retained; `PiSetup/vendor/LICENSE` is the upstream Apache-2.0 license. `PiSetup/handoff.py`, `pair.py`, and the diagnostic scripts implement this project's one-time encrypted iPhone handoff.
