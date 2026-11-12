"""Remote COPY/HASH only. Creates one exact NEW private owner tree; launches nothing."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tarfile

ROOTS = {'owner': Path('/Users/developer/DarkbloomDev/qwen27b-phase-memory-c256-serial-20260917')}

def require(value, message):
    if not value: raise RuntimeError(message)


def main():
    raw = sys.stdin.buffer.readline(1_048_577)
    require(len(raw) <= 1_048_576 and raw.endswith(b'\n'), 'Deployment manifest exceeded bound')
    manifest = json.loads(raw)
    require(manifest['schema'] == 'qwen27b_load_operands_copy_only_tree_v1', 'Wrong deployment schema')
    files = manifest['files']
    require(type(files) is dict and 10 <= len(files) <= 100, 'Wrong deployment member count')
    require(sum(x['bytes'] for x in files.values()) < 300_000_000, 'Deployment exceeded bound')
    for name, entry in files.items():
        bits = name.split('/')
        require(len(bits) >= 2 and bits[0] in ROOTS and all(x and x not in ('.', '..') for x in bits), 'Unsafe deployment member')
        require(type(entry['bytes']) is int and 0 <= entry['bytes'] <= 200_000_000, 'Invalid member size')
        require(entry['mode'] in (0o600, 0o700), 'Invalid private mode')
    # Observation only: do not create, truncate, lock, resolve or replace the live device gate.
    lease = Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
    fd = os.open(lease, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd); named = os.lstat(lease)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1
                and before.st_mode & 0o077 == 0 and before.st_size == 0
                and (before.st_dev, before.st_ino) == (named.st_dev, named.st_ino), 'Canonical device journal is unresolved or unsafe')
        journal = dict(path=str(lease), device=before.st_dev, inode=before.st_ino, bytes=before.st_size)
    finally: os.close(fd)
    for path in ROOTS.values():
        require(not os.path.lexists(path), 'Refuse an existing destination')
    for path in ROOTS.values(): path.mkdir(mode=0o700)
    seen = set()
    with tarfile.open(fileobj=sys.stdin.buffer, mode='r|') as archive:
        for member in archive:
            name = member.name
            require(name in files and name not in seen and member.isfile() and not member.issparse(), 'Unexpected archive member')
            entry = files[name]; require(member.size == entry['bytes'], 'Archive size differs')
            parts = name.split('/'); target = ROOTS[parts[0]].joinpath(*parts[1:])
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, entry['mode'])
            checksum = hashlib.sha256(); remaining = member.size
            try:
                source = archive.extractfile(member)
                while remaining:
                    block = source.read(min(remaining, 1_048_576)); require(bool(block), 'Truncated archive member')
                    checksum.update(block); remaining -= len(block)
                    view = memoryview(block)
                    while view:
                        count = os.write(fd, view); require(count > 0, 'Incomplete local write'); view = view[count:]
                os.fsync(fd)
            finally: os.close(fd)
            require(checksum.hexdigest() == entry['sha256'], 'Transferred member hash differs')
            seen.add(name)
    require(seen == set(files), 'Missing deployment members')
    verified = {}
    for label, root in ROOTS.items():
        for path in root.rglob('*'):
            info = path.lstat(); require(not stat.S_ISLNK(info.st_mode), 'Unexpected link')
            if not path.is_file(): continue
            name = label + '/' + str(path.relative_to(root))
            require(name in files, 'Unexpected installed file')
            checksum = hashlib.sha256()
            with path.open('rb') as source:
                for block in iter(lambda: source.read(1_048_576), b''): checksum.update(block)
            require(info.st_size == files[name]['bytes'] and checksum.hexdigest() == files[name]['sha256'], 'Installed full rehash differs')
            verified[name] = dict(bytes=info.st_size, sha256=checksum.hexdigest())
    require(set(verified) == set(files), 'Installed closure differs')
    (ROOTS['owner'] / 'evidence').mkdir(mode=0o700)
    print(json.dumps(dict(schema='qwen27b_load_operands_copy_only_verification_v1', manifestSHA256=hashlib.sha256(raw).hexdigest(),
        verified=verified, canonicalJournalObserved=journal, modelOrOwnerLaunched=False, existingInputsModified=False)), flush=True)

if __name__ == '__main__': main()
