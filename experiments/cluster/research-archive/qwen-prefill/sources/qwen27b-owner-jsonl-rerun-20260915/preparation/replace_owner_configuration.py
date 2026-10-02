"""Replace this run's owner configuration under the existing empty device gate."""
from pathlib import Path
import base64
import fcntl
import hashlib
import json
import os
import stat
import subprocess
import sys

packet = json.loads(sys.stdin.buffer.read(65537))
root = Path('/Users/developer/DarkbloomDev/qwen27b-owner-validation-20260915')
assert root.resolve() == root
raw = base64.b64decode(packet['configurationBase64'], validate=True)
assert len(raw) < 16384 and raw.count(b'\n') == 1 and raw.endswith(b'\n')
assert hashlib.sha256(raw).hexdigest() == packet['afterSHA256']
assert json.loads(raw)['clusterID'] == 'qwen27b-native-validation-1c7b2bc6-744b-41c1-b621-ddef0e9eb31e'
journal = Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
gate = os.open(journal, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
try:
    fcntl.flock(gate, fcntl.LOCK_EX | fcntl.LOCK_NB)
    info = os.fstat(gate)
    assert stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
    assert stat.S_IMODE(info.st_mode) == 0o600 and info.st_size == 0
    assert (info.st_dev, info.st_ino) == (journal.lstat().st_dev, journal.lstat().st_ino)
    processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
    for line in processes.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2:
            name = Path(fields[1]).name.lower()
            assert not name.startswith(('darkbloom', 'qwen')) and name not in {'cluster-inference', 'owner-controller'}, line
    assert not list((root / 'evidence').iterdir())
    path = root / 'owner.json'
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before_stat = os.fstat(fd)
        assert stat.S_ISREG(before_stat.st_mode) and before_stat.st_uid == os.getuid()
        assert before_stat.st_nlink == 1 and stat.S_IMODE(before_stat.st_mode) == 0o600
        before = os.read(fd, 16385)
    finally:
        os.close(fd)
    assert len(before) <= 16384 and hashlib.sha256(before).hexdigest() == packet['beforeSHA256']
    old, new = json.loads(before), json.loads(raw)
    old['clusterID'] = new['clusterID']
    assert old == new
    backup = root / ('owner.before-jsonl-' + packet['beforeSHA256'] + '.json')
    temporary = root / 'owner.jsonl-replacement.tmp'
    for destination, content in ((backup, before), (temporary, raw)):
        with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
    current = path.lstat()
    assert (current.st_dev, current.st_ino, current.st_size) == (before_stat.st_dev, before_stat.st_ino, before_stat.st_size)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == packet['beforeSHA256']
    os.replace(temporary, path)
    assert path.read_bytes() == raw
    assert os.fstat(gate).st_size == 0
    print(json.dumps({'replaced': True, 'beforeSHA256': packet['beforeSHA256'], 'afterSHA256': packet['afterSHA256'], 'backup': str(backup), 'journalBytes': 0, 'modelExecuted': False}))
finally:
    os.close(gate)
