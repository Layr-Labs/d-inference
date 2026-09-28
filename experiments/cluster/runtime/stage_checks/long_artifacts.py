"""Bounded local run receipts and exact raw staged-file verification."""
from . import archive
from .common import require
from .long_stream import MAX_STDOUT, WARNING


def verify_files(output, records):
    for value in records:
        path = output / value['path']
        require(path.stat().st_size == value['size_bytes'] and archive.digest(path) == value['sha256'],
                'Staged local configuration/raw input changed: ' + value['path'])


def rank_files(output, paired):
    expected = range(2 if paired else 1)
    caps = {'rank.json':256 * 1024, 'prompt.json':65536, 'stdout.jsonl':MAX_STDOUT,
            'stderr.log':len(WARNING) if paired else 0}
    if paired: caps['hosts.json'] = 1024
    records = []
    for rank in expected:
        folder = output / ('rank-' + str(rank))
        for name, maximum in caps.items():
            path = folder / name
            if not path.exists(): continue
            size = path.stat().st_size
            require(size <= maximum, 'Retained long-check file exceeds bound: ' + name)
            records.append(dict(path=path.relative_to(output).as_posix(), rank=rank,
                size_bytes=size, maximum_bytes=maximum, sha256=archive.digest(path)))
    return records
