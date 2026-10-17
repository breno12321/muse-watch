#!/usr/bin/env python3
"""One-time BLE pairing only. No Muse command executor or background service."""
import argparse
import getpass
import json
import logging
import os
from pathlib import Path
import signal
import sys
import threading
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent / 'vendor'))
from musegadget.identity import Identity, generate_mac
from musegadget.pairing import PairingSession
from musegadget.ble_server import BleServer
from musegadget.ble_setup import SetupController, ProvisionFailed
from handoff import validate_request, seal, REFERENCE_EPOCH


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def validate_credentials(credentials):
    if credentials.api_url_v2 not in ('', 'https://api.muse.ai', 'https://api.muse.ai/'):
        raise ProvisionFailed('auth_failed')
    if credentials.noise_host not in ('', 'hatch.metaaivm.com'):
        raise ProvisionFailed('auth_failed')
    if not credentials.access_token or not credentials.refresh_token:
        raise ProvisionFailed('auth_failed')
    if max(len(credentials.access_token), len(credentials.refresh_token)) > 32768:
        raise ProvisionFailed('auth_failed')
    request = urllib.request.Request('https://api.muse.ai/fetch_vms', headers={
        'Authorization': 'Bearer ' + credentials.access_token, 'X-API-Version': '1.0.0',
        'User-Agent': 'MuseWatchSetup/1.0'})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=15) as response:
            data = response.read(131073)
            if len(data) > 131072:
                raise ValueError('Response too large')
            result = json.loads(data)
        if not isinstance(result, dict) or not result.get('vm_list') or result.get('error_title') or result.get('backend_error_code'):
            raise ValueError('No available VM')
    except Exception:
        raise ProvisionFailed('auth_failed') from None


class Network:
    def is_online(self):
        # The Pi is provisioned over SSH on an existing network. Real account
        # reachability is verified in validate_credentials before auth_ok.
        return True

    def current_connection_entry(self):
        return {'ssid': 'Pi internet (already connected)', 'rssi': -40, 'secure': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('MuseWatch.musepair'))
    parser.add_argument('--token-stdin', action='store_true', help='Receive the token over a private SSH stdin pipe.')
    args = parser.parse_args()
    os.umask(0o077)
    if args.output.exists() or args.output.is_symlink():
        raise ValueError('Output file already exists. Choose a new --output filename.')
    if args.request.stat().st_size > 131072:
        raise ValueError('Setup request is too large.')
    request = validate_request(json.loads(args.request.read_bytes()))
    token = (sys.stdin.readline(2050) if args.token_stdin else getpass.getpass('Muse SDK token (mgst_…; hidden): ')).strip()
    if not token.startswith('mgst_') or not 5 < len(token) <= 2048:
        raise ValueError('Enter a valid SDK token beginning with mgst_.')
    # The password/token never appears in argv, environment, files, or logs.
    request = validate_request(request)
    identity = Identity(generate_mac())
    pairing = PairingSession(node_id=identity.node_id, device_id=identity.device_id, mac=identity.mac,
                             firmware_version='0.1.0', sdk_token=token)
    complete = threading.Event()
    controller = None
    server = BleServer(identity.ble_name, on_write=lambda packet: controller.on_write(packet),
                       on_disconnect=lambda: controller.on_disconnect())
    logging.getLogger('musegadget').setLevel(logging.CRITICAL)

    def provision(credentials, commit):
        print('Checking the provisioned Muse credentials…', flush=True)
        validate_credentials(credentials)
        value = {'identity': {'mac': identity.mac}, 'sdkToken': token,
                 'accessToken': credentials.access_token, 'refreshToken': credentials.refresh_token,
                 'username': credentials.username, 'apiURL': credentials.api_url_v2,
                 'noiseHost': credentials.noise_host, 'savedAt': time.time() - REFERENCE_EPOCH}
        try:
            envelope = seal(value, request)
            encoded = json.dumps(envelope, separators=(',', ':')).encode()
            def save():
                descriptor = os.open(args.output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(descriptor, 'wb') as file:
                    file.write(encoded); file.flush(); os.fsync(file.fileno())
                return True
            if not commit(save):
                raise ProvisionFailed('auth_failed')
        except Exception:
            raise ProvisionFailed('auth_failed') from None

    def on_complete():
        complete.set()
        print('Paired. Encrypted setup saved. Bluetooth setup will close now.', flush=True)
        delay = threading.Timer(2, server.stop); delay.daemon = True; delay.start()

    controller = SetupController(pairing=pairing, identity=identity, version='0.1.0',
                                 transport=server, network=Network(), provision=provision, on_complete=on_complete)
    remaining = request['expiresAt'] - (time.time() - REFERENCE_EPOCH)
    if remaining <= 0:
        raise ValueError('Setup request expired. Create a fresh one on your iPhone.')
    expiry = threading.Timer(remaining, server.stop); expiry.daemon = True
    controller.start(); expiry.start()
    print('Opening pairing as ' + identity.ble_name + '.', flush=True)
    print('In official Muse: Settings → Devices → Developer mode → Add Device.', flush=True)
    print('Select this name. Choose “Pi internet (already connected)” if asked for Wi-Fi.', flush=True)
    print('This window expires with the iPhone request. Ctrl-C cancels.', flush=True)
    try:
        server.run()
    finally:
        expiry.cancel(); controller.stop(); pairing.reset()
    if complete.is_set():
        print('Ready for transfer: ' + str(args.output.resolve()), flush=True)
        return 0
    print('Pairing ended without an exported setup. No credentials saved.', flush=True)
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nPairing cancelled.', file=sys.stderr); sys.exit(130)
    except Exception as error:
        # Never print remote response bodies or provisioned tokens.
        if isinstance(error, (ValueError, FileNotFoundError)):
            print(str(error), file=sys.stderr)
        else:
            print('Setup failed. Check Bluetooth is powered on and D-Bus permits GATT advertising.', file=sys.stderr)
        sys.exit(1)
