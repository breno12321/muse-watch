"""Generate synthetic Noise vectors using the pinned upstream Python SDK.
Usage: uv run --no-project --with cryptography scripts/generate_noise_fixture.py /path/to/muse-gadget-sdk
Requires checkout f60347aeb851a1fe9438cfc388721776aa24f275. No network/account calls.
"""
import sys,json,subprocess
from pathlib import Path
sdk = Path(sys.argv[1]).resolve()
revision = subprocess.check_output(['git', '-C', str(sdk), 'rev-parse', 'HEAD'], text=True).strip()
if revision != 'f60347aeb851a1fe9438cfc388721776aa24f275':
 raise SystemExit('Use the pinned SDK revision.')
sys.path.insert(0,str(sdk/'linux/src'))
from musegadget.noise import noise_xx as n
from musegadget.noise.envelope import ServiceFrame,ApplicationResponse,ServiceResponse,encode_service_frame,encode_service_response
from musegadget.noise.framing import encode_noise_frames
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives import serialization
counter=0
def key():
 global counter
 counter+=1
 p=x25519.X25519PrivateKey.from_private_bytes(bytes([counter])*32)
 return n._X25519KeyPair(p,p.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw))
n._generate_x25519_key_pair=key
i=n.NoiseXXInitiator();r=n.NoiseXXResponder();i.initialize();r.initialize()
m1=i.write_message1();m2=r.read_message1_and_write_message2(m1);i.read_message2(m2);m3=i.write_message3();r.read_message3(m3)
a,b=i.split();c,d=r.split()
plain=b'sdk nonce compatibility'
v={'message1':m1.hex(),'message2':m2.hex(),'message3':m3.hex(),'client0':a.encrypt_with_ad(b'',plain).hex(),'client1':a.encrypt_with_ad(b'',plain).hex()}
f=ServiceFrame.response(7,ApplicationResponse(status=200,body=b'{"ok":true}',end_body=True))
env=encode_service_response(ServiceResponse(payload=encode_service_frame(f)))
v['server_response']=c.encrypt_with_ad(b'',encode_noise_frames(env,chunk_id=123)[0]).hex()
print(json.dumps(v,indent=2))
