"""No-follow, same-inode private files and durable backups; never replaces the canonical lease."""
import fcntl
import os
from pathlib import Path
import stat
import uuid


class RecoveryRefusal(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise RecoveryRefusal(message)


def identity(value):
    return dict(device=value.st_dev, inode=value.st_ino, uid=value.st_uid,
                mode=stat.S_IMODE(value.st_mode), links=value.st_nlink)


def directory_identity(value):
    require(stat.S_ISDIR(value.st_mode) and value.st_nlink > 0, 'Directory is not live')
    return {k:v for k,v in identity(value).items() if k != 'links'}


def open_directory(path):
    path = str(path)
    pieces = path.split('/')
    require(path.startswith('/') and len(path.encode()) <= 4096
            and all(p and p not in ('.', '..') for p in pieces[1:])
            and all(ord(c) >= 32 and ord(c) != 127 for c in path), 'Invalid absolute directory')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for piece in pieces[1:]:
            new = os.open(piece, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd); fd = new
        value = os.fstat(fd)
        require(stat.S_ISDIR(value.st_mode) and value.st_uid == os.geteuid()
                and stat.S_IMODE(value.st_mode) == 0o700 and value.st_nlink > 0, 'Directory must be owned mode0700')
        return fd
    except BaseException:
        os.close(fd)
        raise


def regular(fd, maximum):
    value = os.fstat(fd)
    require(stat.S_ISREG(value.st_mode) and value.st_uid == os.geteuid() and value.st_nlink == 1
            and stat.S_IMODE(value.st_mode) == 0o600 and 0 <= value.st_size <= maximum,
            'File must be bounded, owned mode0600 and single-linked')
    return value


def contents(fd, maximum):
    before = regular(fd, maximum)
    raw = os.pread(fd, before.st_size + 1, 0)
    after = regular(fd, maximum)
    require(len(raw) == before.st_size and identity(before) == identity(after)
            and before.st_size == after.st_size and before.st_mtime_ns == after.st_mtime_ns
            and before.st_ctime_ns == after.st_ctime_ns, 'File changed during bounded read')
    return raw


def read_private_file(path, maximum):
    directory = open_directory(path.parent)
    fd = None
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
        value = regular(fd, maximum)
        named = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
        require(identity(value) == identity(named), 'Private evidence file replaced')
        return contents(fd, maximum)
    finally:
        if fd is not None: os.close(fd)
        os.close(directory)


class HeldJournal:
    def __init__(self, path):
        self.path = Path(path)
        self.directory = open_directory(self.path)
        self.fd = None
        try:
            self.directory_id = directory_identity(os.fstat(self.directory))
            self.fd = os.open('native-device.lease', os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                              dir_fd=self.directory)
            self.file_id = identity(regular(self.fd, 16384))
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.same_path()
        except BaseException:
            self.close()
            raise

    def same_path(self):
        reopened = open_directory(self.path)
        try:
            require(directory_identity(os.fstat(reopened)) == self.directory_id
                    and directory_identity(os.fstat(self.directory)) == self.directory_id, 'Canonical directory replaced')
        finally: os.close(reopened)
        named = os.stat('native-device.lease', dir_fd=self.directory, follow_symlinks=False)
        require(identity(regular(self.fd, 16384)) == self.file_id and identity(named) == self.file_id,
                'Canonical file replaced or permissions changed')

    def require_bytes(self, expected):
        self.same_path()
        require(contents(self.fd, 16384) == expected, 'Canonical journal bytes changed')
        self.same_path()

    def close(self):
        if self.fd is not None: os.close(self.fd); self.fd = None
        if self.directory is not None: os.close(self.directory); self.directory = None


class DurableBackup:
    def __init__(self, held, lease_id):
        self.held = held
        self.name = 'administrative-recovery-' + lease_id + '-' + str(uuid.uuid4())
        self.directory = None
        self.files = []
        os.mkdir(self.name, 0o700, dir_fd=held.directory)
        try:
            self.directory = os.open(self.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                     dir_fd=held.directory)
            self.directory_id = directory_identity(os.fstat(self.directory))
            require(self.directory_id['mode'] == 0o700 and self.directory_id['uid'] == os.geteuid(),
                    'Backup directory ownership differs')
            os.fsync(held.directory)
        except BaseException:
            self.close()
            raise

    def add(self, name, raw):
        require(name and '/' not in name and name not in ('.', '..') and len(raw) <= 65536, 'Backup member bound')
        fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600,
                     dir_fd=self.directory)
        try:
            value = identity(regular(fd, 65536))
        except BaseException:
            os.close(fd)
            raise
        self.files.append((name, fd, raw, value))
        offset = 0
        while offset < len(raw):
            count = os.pwrite(fd, raw[offset:], offset)
            require(count > 0, 'Backup write made no progress')
            offset += count
        os.fsync(fd)
        os.fsync(self.directory)

    def verify(self):
        self.held.same_path()
        named = os.stat(self.name, dir_fd=self.held.directory, follow_symlinks=False)
        require(directory_identity(named) == self.directory_id and directory_identity(os.fstat(self.directory)) == self.directory_id,
                'Backup directory replaced')
        for name, fd, raw, expected in self.files:
            named = os.stat(name, dir_fd=self.directory, follow_symlinks=False)
            require(identity(named) == expected and identity(regular(fd, 65536)) == expected
                    and contents(fd, 65536) == raw, 'Durable backup changed')
        os.fsync(self.directory)
        os.fsync(self.held.directory)

    def close(self):
        for _, fd, _, _ in self.files: os.close(fd)
        self.files = []
        if self.directory is not None: os.close(self.directory); self.directory = None
