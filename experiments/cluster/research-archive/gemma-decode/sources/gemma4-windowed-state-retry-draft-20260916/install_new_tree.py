"""Remote COPY/HASH only. Creates one exact NEW private native-check tree; launches nothing."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tarfile

ROOTS = {'check': Path('/Users/developer/DarkbloomDev/gemma-window-state-check-20260916/operations-retry-20260916')}

def require(value, message):
    if not value: raise RuntimeError(message)


def main():
    raw = sys.stdin.buffer.readline(1_048_577)
    require(len(raw) <= 1_048_576 and raw.endswith(b'\n'), 'Deployment manifest exceeded bound')
    manifest = json.loads(raw)
    require(manifest['schema'] == 'window_state_attempt_entry_copy_v1', 'Wrong deployment schema')
    files = manifest['files']
    require(type(files) is dict and set(files) == {'check/run_target.py'}, 'Wrong deployment member')
    require(sum(x['bytes'] for x in files.values()) <= 65_536, 'Deployment exceeded bound')
    for name, entry in files.items():
        bits = name.split('/')
        require(len(bits) >= 2 and bits[0] in ROOTS and all(x and x not in ('.', '..') for x in bits), 'Unsafe deployment member')
        require(type(entry['bytes']) is int and 0 <= entry['bytes'] <= 65_536, 'Invalid member size')
        require(entry['mode'] == 0o600, 'Invalid private mode')
    existing = ROOTS['check'].parent
    mode = existing.lstat()
    require(existing.resolve() == existing and stat.S_ISDIR(mode.st_mode) and mode.st_uid == os.geteuid()
            and mode.st_mode & 0o777 == 0o700, 'Original installation root is unsafe')
    source_manifest = existing / 'package.json'
    prior_fd = os.open(source_manifest, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        prior = os.fstat(prior_fd)
        require(stat.S_ISREG(prior.st_mode) and prior.st_uid == os.geteuid() and prior.st_nlink == 1
                and prior.st_mode & 0o077 == 0 and 0 < prior.st_size <= 1_048_576, 'Original package metadata is unsafe')
        original = bytearray()
        while len(original) <= prior.st_size:
            block = os.read(prior_fd, min(65536, prior.st_size + 1 - len(original)))
            if not block: break
            original.extend(block)
        after = os.fstat(prior_fd); named = source_manifest.lstat()
        identity = lambda x:(x.st_dev,x.st_ino,x.st_size,x.st_mtime_ns,x.st_ctime_ns)
        require(identity(prior) == identity(after) == identity(named) and len(original) == prior.st_size
                and hashlib.sha256(original).hexdigest() == '23d85130dec2bc15294f74a35e1f108c31641c1a895b93caff56df8819550822',
                'Original package metadata differs')
    finally: os.close(prior_fd)
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
    (ROOTS['check'] / 'evidence').mkdir(mode=0o700)
    print(json.dumps(dict(schema='window_state_attempt_entry_copy_verification_v1', manifestSHA256=hashlib.sha256(raw).hexdigest(),
        verified=verified, canonicalJournalObserved=journal, modelOrOwnerLaunched=False, existingInputsModified=False)), flush=True)

if __name__ == '__main__': main()
