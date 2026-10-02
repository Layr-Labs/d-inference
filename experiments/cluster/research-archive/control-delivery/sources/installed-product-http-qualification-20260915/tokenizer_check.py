"""Compare installed Swift tokenizer IDs before the timed generation request."""
import hashlib
import http.client
import json
from client_timeout import absolute_timeout


def verify(rendered, expected_file, token, output):
    text = rendered.read_text()
    expected = json.loads(expected_file.read_bytes())
    assert isinstance(expected, list) and 1 <= len(expected) <= 8192
    assert all(type(value) is int and 0 <= value < 248320 for value in expected)
    assert len(text.encode()) <= 131072
    body = json.dumps({'model': 'Qwen3.5-9B', 'prompt': text,
                       'add_special_tokens': False}, separators=(',', ':')).encode()
    connection = http.client.HTTPConnection('192.0.2.250', 18081, timeout=5)
    response = None
    try:
        with absolute_timeout(15):
            connection.request('POST', '/tokenize', body=body,
                headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
            response = connection.getresponse()
            raw = response.read(1048577)
        assert response.status == 200 and len(raw) <= 1048576, 'Token utility refused'
        value = json.loads(raw)
        assert isinstance(value, dict) and set(value) == {'tokens'}
        assert isinstance(value['tokens'], list)
        assert all(type(item) is int and 0 <= item < 248320 for item in value['tokens'])
        assert value['tokens'] == expected, 'Installed Swift tokenizer IDs differ'
    finally:
        try:
            if response is not None:
                response.close()
        finally:
            connection.close()
    (output / 'tokenizer-response.json').write_bytes(raw)
    return {'tokenCount': len(expected), 'everyTokenIDMatched': True,
            'responseSHA256': hashlib.sha256(raw).hexdigest(),
            'renderedPromptSHA256': hashlib.sha256(rendered.read_bytes()).hexdigest(),
            'scope': 'Pre-rendered thinking-disabled prompt; no model generation; outside timed request'}
