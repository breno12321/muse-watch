"""Encrypted Pi-to-iPhone handoff, interoperable with Shared/SetupEnvelope.swift."""
import base64
import json
import math
import time
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
import os

REFERENCE_EPOCH = 978307200


def validate_request(request, now=None):
    now = time.time() - REFERENCE_EPOCH if now is None else now
    if not isinstance(request, dict) or type(request.get('version')) is not int or request['version'] != 1:
        raise ValueError('Unsupported setup request.')
    public_key = base64.b64decode(request['recipientPublicKey'], validate=True)
    created, expires = request['createdAt'], request['expiresAt']
    if any(type(n) not in (int, float) or not math.isfinite(n) for n in (created, expires)):
        raise ValueError('Invalid setup dates.')
    if len(public_key) != 32 or created > now + 30 or not 0 < expires - created <= 600:
        raise ValueError('Invalid setup request.')
    if now >= expires:
        raise ValueError('Setup request expired. Create a fresh request on your iPhone.')
    identifier = str(uuid.UUID(request['id'])).upper()
    return {'version': 1, 'id': identifier, 'createdAt': created, 'expiresAt': expires,
            'recipientPublicKey': base64.b64encode(public_key).decode()}


def context(request):
    # Foundation JSONEncoder uses sorted keys and escapes slashes. Its date
    # values are seconds since 2001, and whole numbers have no decimal suffix.
    value = dict(request)
    for key in ('createdAt', 'expiresAt'):
        if float(value[key]).is_integer():
            value[key] = int(value[key])
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).replace('/', '\\/').encode()


def seal(credentials, request, now=None):
    request = validate_request(request, now)
    sender = X25519PrivateKey.generate()
    shared = sender.exchange(X25519PublicKey.from_public_bytes(base64.b64decode(request['recipientPublicKey'])))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=request['id'].encode(), info=b'Muse Watch setup v1').derive(shared)
    nonce = os.urandom(12)
    ciphertext = AESGCM(key).encrypt(nonce, json.dumps(credentials, separators=(',', ':')).encode(), context(request))
    return {'version': 1, 'requestID': request['id'], 'expiresAt': request['expiresAt'],
            'senderPublicKey': base64.b64encode(sender.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode(),
            'sealedCredentials': base64.b64encode(nonce + ciphertext).decode()}
