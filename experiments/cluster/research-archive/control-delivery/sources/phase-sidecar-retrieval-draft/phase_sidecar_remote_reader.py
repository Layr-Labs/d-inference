"""Fixed read-only SSH payload. Opens no-follow components; emits metadata LF raw bytes."""
import hashlib
import json
import os
from pathlib import PurePosixPath
import stat
import sys

MAXIMUM_BYTES = 512 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def signature(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def read_sidecar(path):
    components = PurePosixPath(path).parts
    require(path.startswith('/') and str(PurePosixPath(path)) == path
            and all(part not in ('.', '..') for part in components)
            and components[-1] == 'phase-trace.json', 'Expected canonical phase sidecar path')
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    directory = os.open('/', flags | os.O_DIRECTORY)
    descriptor = None
    try:
        for component in components[1:-1]:
            next_directory = os.open(component, flags | os.O_DIRECTORY, dir_fd=directory)
            os.close(directory)
            directory = next_directory
        descriptor = os.open(components[-1], flags, dir_fd=directory)
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and stat.S_IMODE(before.st_mode) == 0o600,
                'Sidecar must be a regular file with exact mode0600')
        require(before.st_uid == os.geteuid() and before.st_nlink == 1,
                'Sidecar owner or link count differs from an exclusively created file')
        require(0 < before.st_size <= MAXIMUM_BYTES, 'Sidecar size exceeds bound or is empty')
        chunks, count = [], 0
        while count <= MAXIMUM_BYTES:
            chunk = os.read(descriptor, min(65536, MAXIMUM_BYTES + 1 - count))
            if not chunk:
                break
            chunks.append(chunk)
            count += len(chunk)
        require(count == before.st_size and signature(before) == signature(os.fstat(descriptor)),
                'Sidecar changed during its bounded descriptor read')
        raw = b''.join(chunks)
        metadata = dict(kind='qwen_prefill_phase_sidecar_read', schema_version=1,
            path=path, sha256=hashlib.sha256(raw).hexdigest(), size_bytes=len(raw),
            mode=stat.S_IMODE(before.st_mode), uid=before.st_uid, gid=before.st_gid,
            device=before.st_dev, inode=before.st_ino, link_count=before.st_nlink,
            mtime_ns=before.st_mtime_ns, ctime_ns=before.st_ctime_ns,
            stable_descriptor_read=True, followed_symlinks=False, remote_file_modified=False)
        return metadata, raw
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory)


def main():
    require(len(sys.argv) == 2, 'Exactly one owned sidecar path is required')
    metadata, raw = read_sidecar(sys.argv[1])
    encoded = json.dumps(metadata, sort_keys=True, separators=(',', ':')).encode()
    require(len(encoded) <= 4096, 'Remote metadata bound')
    sys.stdout.buffer.write(encoded + b'\n' + raw)
    sys.stdout.buffer.flush()


if __name__ == '__main__':
    main()
