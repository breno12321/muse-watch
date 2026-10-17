"""Brief GATT/advertising permission test; no pairing or account credentials."""
import logging
from pathlib import Path
import sys
import threading
sys.path.insert(0, str(Path(__file__).resolve().parent / 'vendor'))
from musegadget.ble_server import BleServer
logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
server = BleServer('MuseSetupCheck', on_write=lambda value: None, on_disconnect=lambda: None)
timer = threading.Timer(3, server.stop); timer.daemon = True; timer.start()
try:
    server.run()
finally:
    timer.cancel()
