"""Bounded immutable-in-call input snapshots; no native or network operations."""

import os
from pathlib import Path
import stat

from runtime.stage_checks.common import digest, parse
from ..costs import fields, require, sha


LIMITS = dict(prompt=65536, rank0_stdout=16 * 1024**2, rank1_stdout=16 * 1024**2,
              rank0_trace=512 * 1024, rank1_trace=512 * 1024)


def read_regular(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum,
                'Input must be a nonempty bounded regular file')
        raw = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
    identity = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                             info.st_mtime_ns, info.st_ctime_ns)
    require(len(raw) == before.st_size and identity(before) == identity(after),
            'Input changed during snapshot')
    return raw, identity(before)


class PacketInputs:
    def __init__(self, path):
        self.packet_path = Path(path).absolute()
        self.packet_raw, self.packet_identity = read_regular(self.packet_path, 65536)
        self.packet = parse(self.packet_raw)
        fields(self.packet, 'schema stage_cut files provenance', 'measurement packet')
        require(self.packet['schema'] == 'cluster_qwen_prefill_measurement_packet_v1',
                'Unsupported measurement packet schema')
        references = fields(self.packet['files'], ' '.join(LIMITS), 'packet files')
        self.raw, self.snapshots, self.metadata = {}, {}, {}
        identities = {self.packet_identity[:2]}
        for name, maximum in LIMITS.items():
            reference = fields(references[name], 'path sha256', name)
            value = reference['path']
            require(type(value) is str and 0 < len(value) <= 4096 and '\x00' not in value,
                    'Invalid input path')
            expected = sha(reference['sha256'], name)
            file_path = Path(value)
            if not file_path.is_absolute():
                file_path = self.packet_path.parent / file_path
            raw, identity = read_regular(file_path, maximum)
            require(identity[:2] not in identities, 'Packet inputs must be distinct files')
            identities.add(identity[:2])
            require(digest(raw) == expected, 'Pinned input bytes differ: ' + name)
            self.raw[name] = raw
            self.snapshots[name] = (file_path, identity)
            self.metadata[name] = dict(sha256=expected, byte_count=len(raw))

    def recheck(self):
        require(read_regular(self.packet_path, 65536) == (self.packet_raw, self.packet_identity),
                'Packet changed during extraction')
        for name, (path, identity) in self.snapshots.items():
            require(read_regular(path, LIMITS[name]) == (self.raw[name], identity),
                    'Input changed during extraction: ' + name)

    @property
    def sha256(self):
        return digest(self.packet_raw)


def stdout_rows(raw):
    rows = raw.split(b'\n')
    require(len(rows) == 3 and rows[-1] == b'' and all(rows[:2]),
            'Exactly two LF-terminated ready and final JSONL records required')
    return [parse(row) for row in rows[:2]]
