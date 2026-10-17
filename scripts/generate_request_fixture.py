"""Generate synthetic outgoing frames with the pinned Muse SDK checkout. Pass its path."""
import sys,json
from pathlib import Path
sdk=Path(sys.argv[1]).resolve()
sys.path.insert(0,str(sdk/'linux/src'))
from musegadget.noise.envelope import ServiceRequest,ServiceFrame,ApplicationRequest,Header,Reset,ResetCode,encode_service_request,encode_service_frame
values={
 'reset':ServiceFrame.reset(2,Reset(code=ResetCode.CANCELLED)),
 'subscribe':ServiceFrame.request(1,ApplicationRequest(verb='POST',path='/chat/subscribe',headers=[Header('Content-Type','application/json'),Header('Accept','application/x-ndjson')],body=b'{"session_id":"side"}',end_body=True))
}
Path('ProtocolTests/Fixtures/request_reference.json').write_text(json.dumps({k:encode_service_request(ServiceRequest(payload=encode_service_frame(v))).hex() for k,v in values.items()},indent=2)+'\n')
