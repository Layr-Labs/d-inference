"""Root-run binary-only replacement under the unchanged canonical empty device gate."""
from pathlib import Path
import base64
import fcntl
import hashlib
import json
import os
import stat
import subprocess
import sys

ROOT = Path('/Users/developer/DarkbloomDev/qwen27b-owner-validation-20260915')
JOURNAL = Path('/Users/developer/.darkbloom/cluster-device/native-device.lease')
NAME = 'darkbloom-owner-qualification'
OLD_SHA = '1138c19529d0bc04fe7faf4e20916622854864cc4a855138bcd7a1fadc9d3967'
NEW_SHA = 'da5542b115279db5f3f6e0794d96cdaa54cff1d193bee8c9d4bb24edc870c8a8'
OLD_BYTES, NEW_BYTES = 129792, 161440
OWNER_CONFIGS = ('847be33162022eccc43f7bdea8e8a7789b6eada0b2b2875bf096e9c387b34807',
                 'f726bd36656d99bf496ebec833543b3755bd1ac50b0f48f2dc1431da4ebd805f')
BACKUP = NAME + '.before-native-diagnostics-' + OLD_SHA
TEMPORARY = NAME + '.native-diagnostics-' + NEW_SHA + '.tmp'


def identity(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def directory(path):
    assert path.resolve() == path, 'Directory contains symlink'
    value = path.lstat()
    assert stat.S_ISDIR(value.st_mode) and stat.S_IMODE(value.st_mode) == 0o700
    assert value.st_uid == os.getuid()
    return value


def regular(fd, size, mode):
    value = os.fstat(fd)
    assert stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid() and value.st_nlink == 1
    assert stat.S_IMODE(value.st_mode) == mode and value.st_size == size
    return value


def bounded_read(fd, size, mode):
    before = regular(fd, size, mode)
    os.lseek(fd, 0, os.SEEK_SET)
    raw = bytearray()
    while len(raw) <= size:
        part = os.read(fd, min(65536, size + 1 - len(raw)))
        if not part:
            break
        raw.extend(part)
    assert len(raw) == size and identity(os.fstat(fd)) == identity(before)
    return bytes(raw), before


def no_live_processes():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True,
                            check=True, timeout=3)
    assert len(result.stdout.encode()) <= 1024 * 1024 and not result.stderr
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2:
            name = Path(fields[1]).name.lower()
            assert not name.startswith(('darkbloom', 'qwen')) and name not in {'cluster-inference', 'owner-controller'}, line


def install(packet, root=ROOT, journal=JOURNAL, observe=no_live_processes):
    assert set(packet) == {'schema', 'rank', 'binaryBase64'}
    assert packet['schema'] == 'qwen27b_native_diagnostic_owner_install_v1'
    assert type(packet['rank']) is int and packet['rank'] in (0, 1)
    raw = base64.b64decode(packet['binaryBase64'], validate=True)
    assert len(raw) == NEW_BYTES and hashlib.sha256(raw).hexdigest() == NEW_SHA
    root_stat = directory(root)
    directory(journal.parent)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    root_fd = os.open(root, flags | os.O_DIRECTORY)
    gate = None
    old_fd = None
    backup_fd = None
    temporary_fd = None
    try:
        assert (os.fstat(root_fd).st_dev, os.fstat(root_fd).st_ino) == (root_stat.st_dev, root_stat.st_ino)
        gate = os.open(journal, flags)
        fcntl.flock(gate, fcntl.LOCK_EX | fcntl.LOCK_NB)
        gate_stat = regular(gate, 0, 0o600)

        def check_gate():
            assert identity(regular(gate, 0, 0o600)) == identity(gate_stat)
            assert identity(journal.lstat()) == identity(gate_stat)
            current = directory(root)
            assert (current.st_dev, current.st_ino) == (root_stat.st_dev, root_stat.st_ino)
            directory(root / 'evidence')
            assert not list((root / 'evidence').iterdir())

        check_gate()
        observe()
        config_fd = os.open('owner.json', flags, dir_fd=root_fd)
        try:
            config, config_stat = bounded_read(config_fd, 2108, 0o600)
            assert hashlib.sha256(config).hexdigest() == OWNER_CONFIGS[packet['rank']]
            assert identity(os.stat('owner.json', dir_fd=root_fd, follow_symlinks=False)) == identity(config_stat)
        finally:
            os.close(config_fd)
        old_fd = os.open(NAME, flags, dir_fd=root_fd)
        before, before_stat = bounded_read(old_fd, OLD_BYTES, 0o755)
        assert hashlib.sha256(before).hexdigest() == OLD_SHA

        def write_new(name, content, expected):
            fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o700, dir_fd=root_fd)
            try:
                with os.fdopen(os.dup(fd), 'wb') as stream:
                    stream.write(content)
                    stream.flush()
                os.fchmod(fd, 0o755)
                os.fsync(fd)
                saved, saved_stat = bounded_read(fd, len(content), 0o755)
                assert hashlib.sha256(saved).hexdigest() == expected
                os.fsync(root_fd)
                return fd, saved_stat
            except BaseException:
                os.close(fd)
                raise

        # Exclusive backup is fully written, synced, and verified before replacement.
        backup_fd, backup_stat = write_new(BACKUP, before, OLD_SHA)
        temporary_fd, temporary_stat = write_new(TEMPORARY, raw, NEW_SHA)
        observe()
        check_gate()
        assert identity(os.stat('owner.json', dir_fd=root_fd, follow_symlinks=False)) == identity(config_stat)
        again, again_stat = bounded_read(old_fd, OLD_BYTES, 0o755)
        assert again == before and identity(again_stat) == identity(before_stat)
        assert identity(os.stat(NAME, dir_fd=root_fd, follow_symlinks=False)) == identity(before_stat)
        for name, fd, saved_stat, content in [(BACKUP, backup_fd, backup_stat, before),
                                            (TEMPORARY, temporary_fd, temporary_stat, raw)]:
            retained, retained_stat = bounded_read(fd, len(content), 0o755)
            assert retained == content and identity(retained_stat) == identity(saved_stat)
            assert identity(os.stat(name, dir_fd=root_fd, follow_symlinks=False)) == identity(saved_stat)
        os.replace(TEMPORARY, NAME, src_dir_fd=root_fd, dst_dir_fd=root_fd)
        os.fsync(root_fd)
        new_fd = os.open(NAME, flags, dir_fd=root_fd)
        try:
            installed, installed_stat = bounded_read(new_fd, NEW_BYTES, 0o755)
            assert hashlib.sha256(installed).hexdigest() == NEW_SHA
            assert identity(os.stat(NAME, dir_fd=root_fd, follow_symlinks=False)) == identity(installed_stat)
        finally:
            os.close(new_fd)
        check_gate()
        return {'schema': 'qwen27b_native_diagnostic_owner_installed_v1', 'rank': packet['rank'],
                'beforeSHA256': OLD_SHA, 'afterSHA256': NEW_SHA, 'backup': str(root / BACKUP),
                'backupSHA256': OLD_SHA, 'journalBytes': 0, 'journalInode': gate_stat.st_ino,
                'ownerConfigurationSHA256': OWNER_CONFIGS[packet['rank']],
                'configurationChanged': False, 'nativeOrControllerChanged': False, 'modelExecuted': False}
    finally:
        if temporary_fd is not None:
            os.close(temporary_fd)
        if backup_fd is not None:
            os.close(backup_fd)
        if old_fd is not None:
            os.close(old_fd)
        if gate is not None:
            os.close(gate)
        os.close(root_fd)


if __name__ == '__main__':
    data = sys.stdin.buffer.read(256 * 1024 + 1)
    assert len(data) <= 256 * 1024
    print(json.dumps(install(json.loads(data)), sort_keys=True))
