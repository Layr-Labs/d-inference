"""Read one closed four-request sidecar directory; no mutation or signals to peers."""
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import uuid

ROOT = Path('/Users/developer/DarkbloomDev/qwen9b-balanced-prefill-20260915')
JOURNAL = Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
LIMIT = 16 * 1024**2


def stamp(info):
    return [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def read_file(name, directory, limit, empty=False):
    fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        assert stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
        assert stat.S_IMODE(before.st_mode) == 0o600
        assert (0 if empty else 1) <= before.st_size <= limit
        raw = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
        named = os.stat(name, dir_fd=directory, follow_symlinks=False)
        assert len(raw) == before.st_size and stamp(before) == stamp(after) == stamp(named)
        return raw, stamp(after)


def main():
    signal.alarm(25)
    assert len(sys.argv) == 6 and sys.argv[1] in ('cut4-timing', 'cut16-timing')
    identifiers = sys.argv[2:]
    assert len(set(identifiers)) == 4 and all(str(uuid.UUID(x)) == x for x in identifiers)
    names = sorted(x + '.json' for x in identifiers)
    path = ROOT / sys.argv[1] / 'evidence'
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        assert before.st_uid == os.geteuid() and before.st_mode & 0o022 == 0
        observed_before = sorted(os.listdir(fd))
        assert observed_before == names, 'Extra or missing sidecars: ' + repr(observed_before)
        files = []
        for name in names:
            raw, identity = read_file(name, fd, LIMIT)
            files.append(dict(name=name, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
                              identity=identity, data=base64.b64encode(raw).decode()))
        observed_after = sorted(os.listdir(fd))
        assert observed_after == names and stamp(before) == stamp(os.fstat(fd)) == stamp(path.lstat())
    finally:
        os.close(fd)
    ps = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, timeout=3, check=True)
    assert not ps.stderr and len(ps.stdout) <= 1024**2
    active = []
    for line in ps.stdout.decode().splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2:
            name = Path(parts[1]).name.lower()
            if name.startswith(('darkbloom', 'qwen')) or name in {'cluster-inference', 'owner-controller'}:
                active.append(line.strip())
    fd = os.open(JOURNAL.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        journal, journal_identity = read_file(JOURNAL.name, fd, 65536, empty=True)
    finally:
        os.close(fd)
    print(json.dumps(dict(schema='balanced_timing_sidecar_collection_v1', directory=str(path),
        directoryIdentity=stamp(before), expectedNames=names, observedBefore=observed_before,
        observedAfter=observed_after, files=files, active=active, journalBytes=len(journal),
        journalSHA256=hashlib.sha256(journal).hexdigest(), journalIdentity=journal_identity),
        sort_keys=True, separators=(',', ':')), flush=True)
    signal.alarm(0)


if __name__ == '__main__':
    main()
