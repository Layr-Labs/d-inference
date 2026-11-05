"""A content-addressed cache of pinned downloads for the fixture scripts.

`cached(fetch, cache, pin)` wraps `fetch(name)`. An entry is named by the
SHA-256 that `pin(name)` returns and is used only when its bytes still have
that digest; otherwise `fetch` runs and its bytes replace the entry only when
they have the digest. The caller still checks every result it receives.
"""

import hashlib
import os


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
