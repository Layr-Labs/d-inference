"""Fresh benchmark installation; create-only outputs, no model loading."""
import json
import os
from pathlib import Path

REMOTE = Path('/Users/developer/DarkbloomDev/gemma4-local-mtp-20260920-v1')
PRODUCT = 'GemmaResidentBenchmark'

def write_json(path, value):
    raw = json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()+b'\n'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
