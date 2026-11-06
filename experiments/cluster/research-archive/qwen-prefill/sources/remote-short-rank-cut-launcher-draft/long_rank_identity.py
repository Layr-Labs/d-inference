"""Short cut12 request/source pins; no numerical row, state or Plan reconstruction."""
import hashlib
import json
import re
import uuid
from long_reference_inputs import require
from short_cut_request import recorded_request as short_request, equal


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def request_id(epoch):
    require(type(epoch) is str and re.fullmatch('[0-9a-f]{32}',epoch), 'Invalid rank epoch')
    return str(uuid.UUID(hex=epoch))


def request_fingerprint(epoch):
    return sha(('qwen-stage-request-v1|' + request_id(epoch) + '|65|32|4').encode())


def recorded_request(epoch,inputs):
    return short_request(request_id(epoch),inputs)


def validate_request(value,epoch,inputs):
    require(type(value) is dict and type(value.get('request')) is dict, 'Missing short recorded request')
    request=value['request'];native_id=request.get('requestID')
    require(type(native_id) is str, 'Invalid native request ID type')
    normalized=dict(value,request=dict(request,requestID=native_id.lower()))
    equal(normalized,recorded_request(epoch,inputs),'Native request differs from epoch/prompt/teacher/timeline')
