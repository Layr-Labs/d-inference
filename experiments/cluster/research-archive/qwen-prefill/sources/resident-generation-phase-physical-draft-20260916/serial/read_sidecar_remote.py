"""Read one fixed 27B sidecar and observe processes/journal. No mutation or signals."""
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess

SIDECAR = '/Users/developer/DarkbloomDev/qwen27b-phase-serial-validation-20260916/evidence/776f1c0c-1ece-4861-9307-f614aa1adeb8.json'
JOURNAL = '/Users/developer/.darkbloom/cluster-device/native-device.lease'


def read_fixed(path, limit, empty=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        assert stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
        assert (0 if empty else 1) <= before.st_size <= limit
        raw = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
    stamp = lambda s: [s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns]
    assert len(raw) == before.st_size and stamp(before) == stamp(after)
    return raw, stamp(after)


def main():
    raw, identity = read_fixed(SIDECAR, 256*1024)
    ps = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, timeout=3, check=True)
    assert not ps.stderr and len(ps.stdout) <= 1024**2
    active = []
    for line in ps.stdout.decode().splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2:
            name = Path(parts[1]).name.lower()
            if name.startswith(('darkbloom', 'qwen')) or name in {'cluster-inference', 'owner-controller'}:
                active.append(line.strip())
    journal, journal_identity = read_fixed(JOURNAL, 65536, empty=True)
    print(json.dumps({'schema': 'qwen27b_sidecar_collection_v1', 'path': SIDECAR,
        'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'identity': identity,
        'data': base64.b64encode(raw).decode(), 'active': active, 'journalBytes': len(journal),
        'journalSHA256': hashlib.sha256(journal).hexdigest(), 'journalIdentity': journal_identity},
        sort_keys=True, separators=(',', ':')))


if __name__ == '__main__':
    main()
