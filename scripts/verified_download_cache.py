"""A content-addressed cache of pinned downloads for the fixture scripts.

`cached(fetch, cache, pin)` wraps `fetch(name)`. An entry is named by the
SHA-256 that `pin(name)` returns and is used only when its bytes still have
that digest; otherwise `fetch` runs and its bytes replace the entry only when
they have the digest. The caller still checks every result it receives.

`restore_file` and `store_file` do the same for a script that streams each
download to a file: an entry is copied out only when it is a regular file
whose size and digest are the pinned ones, and only a verified file is stored.
"""

import contextlib
import hashlib
import os
import shutil
import stat
import sys

COPY_CHUNK_BYTES = 1 << 20


def cached(fetch, cache, pin):
    def fetch_cached(name):
        digest = pin(name)
        entry = cache / digest
        if entry.is_file() and not entry.is_symlink():
            data = entry.read_bytes()
            if hashlib.sha256(data).hexdigest() == digest:
                return data
        data = fetch(name)
        if hashlib.sha256(data).hexdigest() == digest:
            cache.mkdir(parents=True, exist_ok=True)
            temporary = cache / f".{digest}.{os.getpid()}"
            temporary.write_bytes(data)
            temporary.replace(entry)
        return data
    return fetch_cached


def restore_file(cache, digest, size, output):
    """Copy entry `digest` to the new file `output`; return whether it did.

    A missing, linked or special entry, or one whose size or SHA-256 is not
    the pinned one, is not used: `output` is then absent and the caller
    downloads. An existing `output` raises FileExistsError and is kept.
    """
    try:
        fd = os.open(cache / digest, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return False
    # Check the opened file itself: a directory or FIFO opens too.
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_size != size:
        os.close(fd)
        return False
    with os.fdopen(fd, "rb") as source:
        hasher, count = hashlib.sha256(), 0
        with output.open("xb") as target:
            try:
                while count <= size:
                    chunk = source.read(min(COPY_CHUNK_BYTES, size + 1 - count))
                    if not chunk:
                        break
                    count += len(chunk)
                    hasher.update(chunk)
                    target.write(chunk)
            except OSError:
                count = -1
    if count != size or hasher.hexdigest() != digest:
        output.unlink()
        return False
    return True


def store_file(cache, digest, source):
    """Copy the verified file `source` into the cache as entry `digest`.

    The cache only saves time: a failure to store is reported and ignored.
    """
    temporary = cache / f".{digest}.{os.getpid()}"
    try:
        cache.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, temporary)
        temporary.replace(cache / digest)
    except OSError as error:
        print(f"download cache: entry {digest} not stored: {error}", file=sys.stderr)
        with contextlib.suppress(OSError):
            temporary.unlink(missing_ok=True)
