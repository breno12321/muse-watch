"""Public synthetic interop fixtures. Run with Python cryptography installed."""
import base64
import json
from pathlib import Path
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from handoff import seal, context

cases = []
for index, created in enumerate([810500000, 810500000.125, 810500000.1234567, 811234567.9999999, 813585600.000001]):
    private = bytes([index + 19]) * 32
    public = X25519PrivateKey.from_private_bytes(private).public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    request = {'version': 1, 'id': '12345678-1234-1234-1234-123456789ABC',
               'createdAt': created, 'expiresAt': created + 600, 'recipientPublicKey': base64.b64encode(public).decode()}
    credentials = {'identity': {'mac': '02:00:00:00:00:01'}, 'sdkToken': 'mgst_SYNTHETIC_TEST_ONLY',
                   'accessToken': 'synthetic-access', 'refreshToken': 'synthetic-refresh',
                   'username': 'synthetic', 'apiURL': '', 'noiseHost': '', 'savedAt': created}
    cases.append({'request': request, 'envelope': seal(credentials, request, now=created + 1),
                  'privateKey': base64.b64encode(private).decode(), 'context': base64.b64encode(context(request)).decode()})
Path(__file__).resolve().parents[1].joinpath('ProtocolTests/Fixtures/pi_handoff.json').write_text(json.dumps(cases, indent=2) + '\n')
