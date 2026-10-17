# Raspberry Pi pairing helper

Uses the unchanged BLE/GATT and community-pairing modules from Muse Gadget SDK revision `f60347aeb851a1fe9438cfc388721776aa24f275`. Included source retains its Apache-2.0 notices; see `vendor/LICENSE`.

The helper only provisions a gadget and exports credentials encrypted to the iPhone's setup request. It does not install the full SDK service, expose shell/file commands to Muse, or save plaintext tokens. The SDK token is entered with a hidden terminal prompt. A successful pairing validates the device access token against the fixed Muse API before exporting. The Pi's device identity travels inside the encrypted file and must be retained when the iPhone connects.

Requirements: Linux/BlueZ with a BLE peripheral controller, Python 3.10+, `cryptography`, `dbus`, and `gi`. Use the system Python with the apt-installed modules; the Pi 4 used here already has these dependencies. Run as the normal SSH user; no persistent administrator policy changes are needed if BlueZ permits advertising. Bluetooth must be unblocked and powered on.

From this directory on the Pi:

```sh
/usr/bin/python3 pair.py --request request.muserequest --output MuseWatch.musepair
```

Enter the `mgst_…` token at the hidden prompt. In official Muse on the nearby iPhone, enable Devices → Developer mode, add the printed `MuseGadgetXXXXXX`, confirm community pairing, and choose `Pi internet (already connected)` if asked for a network. The Pi ignores Wi-Fi fields and does not store a Wi-Fi password.

The request expires after 10 minutes from creation on the iPhone. Create and transfer a new one if necessary. Output uses exclusive creation with mode 0600 and never overwrites an existing file. Choose a new output filename for another attempt. Ctrl-C stops the helper and restores the previous Bluetooth alias/pairable setting. It also closes automatically on expiry or shortly after successful provisioning. The Pi can remain powered on for transferring the encrypted file; it need not run a Muse service.

Copy the encrypted `.musepair` back to the Mac, AirDrop to the same iPhone, and import in **Muse Watch** before the original request expires. Stop the Pi helper before testing the real iPhone reply and token refresh. Pi pairing, encrypted iPhone import, credential refresh, real Watch audio/replies, and a short background exchange have passed physical-device testing. No Pi service is needed afterward. See the [project quickstart](../README.md#first-time-setup) for dependency installation, file-transfer commands, Xcode/device setup, and troubleshooting.

`check_bluetooth.py` briefly publishes a diagnostic GATT service and advertisement, without pairing or credentials, and restores the adapter afterward. `generate_handoff_fixture.py` generates public synthetic fixtures for the Swift interoperation test; it must only be run in this repository, never with account credentials.
