from pathlib import Path
import hashlib

BASE = Path(__file__).resolve().parent


def pin(path):
    raw = path.read_bytes()
    return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())

