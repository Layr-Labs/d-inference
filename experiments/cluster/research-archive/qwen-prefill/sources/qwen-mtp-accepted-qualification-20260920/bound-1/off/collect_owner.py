"""Read-only bounded collection; configured constants are filled by the binder."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

MODE = 'off'
REQUEST_ID = '9e6f732e-2be0-49eb-a01a-ef9ebebcb619'
DIRECTORY = Path('/Users/developer/DarkbloomDev/qwen-mtp-accepted-qualification-20260920/off')


def snapshot(path, cap, keep=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or before.st_nlink != 1 or not 0 <= before.st_size <= cap:
            raise ValueError('Unsafe bounded evidence file')
        identity = lambda s: [s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns]
        digest = hashlib.sha256(); chunks = []; remaining = before.st_size
        while remaining:
            raw = os.read(fd, min(65536, remaining))
            if not raw:
                raise ValueError('Evidence truncated')
            remaining -= len(raw); digest.update(raw)
            if keep:
                chunks.append(raw)
        after = os.fstat(fd); named = path.lstat()
        if os.read(fd, 1) or identity(before) != identity(after) or identity(after) != identity(named):
            raise ValueError('Evidence identity or bytes changed')
        return dict(bytes=before.st_size, sha256=digest.hexdigest(), identity=identity(after)), b''.join(chunks)
    finally:
        os.close(fd)


def observe(keep=False):
    process = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, check=True, timeout=5)
    if len(process.stdout) > 4*1024**2 or process.stderr:
        raise ValueError('Process observation differs')
    names = {'darkbloom', 'darkbloom-cluster-worker', 'darkbloom-owner-qualification', 'cluster-inference'}
    active = [line.strip() for line in process.stdout.decode().splitlines()
              if len(line.split(maxsplit=1)) == 2 and Path(line.split(maxsplit=1)[1]).name in names]
    journal, _ = snapshot(Path('/Users/developer/.darkbloom/cluster-device/native-device.lease'), 65536)
    result = dict(active=active, journalBytes=journal['bytes'], journalSHA256=journal['sha256'], journal=journal)
    file = DIRECTORY / 'evidence' / (REQUEST_ID + '.json'); raw = b''
    if not active and journal['bytes'] == 0 and file.exists():
        result['sidecar'], raw = snapshot(file, 16*1024**2, keep=keep)
    return result, raw


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {'observe', 'collect'}:
        raise ValueError('Explicit read-only action required')
    result, raw = observe(keep=sys.argv[1] == 'collect')
    if sys.argv[1] == 'observe':
        print(json.dumps(result, sort_keys=True)); return
    if result['active'] or result['journalBytes'] or not raw:
        raise ValueError('Collection requires retired owner and immutable sidecar')
    owner, _ = snapshot(DIRECTORY / 'owner.json', 65536)
    header = dict(schema='mtp_owned_evidence_collection_v1', mode=MODE, requestID=REQUEST_ID,
                  observation=result, ownerConfigurationSHA256=owner['sha256'])
    sys.stdout.buffer.write(json.dumps(header, sort_keys=True, separators=(',', ':')).encode() + b'\n')
    sys.stdout.buffer.write(raw); sys.stdout.buffer.flush()


if __name__ == '__main__':
    main()
