"""Explicit bounded snapshots and streamed member hashes, with postflight recheck."""
import hashlib
import os
from pathlib import Path
import stat
from binding_common import fields, parse, pin, require

CORE_LIMITS = dict(stdout=64*1024**2, stderr=65536, prompt=4096, teacher=4096,
                   parent=4*1024**2, numerical=1024**2, source_manifest=4*1024**2,
                   bundle_manifest=1024**2, retained_metadata=4*1024**2)


def snapshot(path, maximum, keep=True, empty=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and (0 if empty else 1) <= before.st_size <= maximum,
                'Expected bounded regular input file')
        digest, parts, size = hashlib.sha256(), [], 0
        while True:
            block = stream.read(min(1024**2, maximum + 1 - size))
            if not block:
                break
            size += len(block)
            require(size <= maximum, 'Input grew beyond its bound')
            digest.update(block)
            if keep:
                parts.append(block)
        after = os.fstat(stream.fileno())
    stamp = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    require(size == before.st_size and stamp(before) == stamp(after), 'Input changed during snapshot')
    return dict(raw=b''.join(parts) if keep else None, sha256=digest.hexdigest(),
                size_bytes=size, identity=stamp(before))


class Inputs:
    def __init__(self, path):
        self.packet_path = Path(path).absolute()
        self.saved = []
        self.packet_snapshot = self.read(self.packet_path, 2*1024**2)
        self.packet = parse(self.packet_snapshot['raw'])
        fields(self.packet, 'schema profile files source_files bundle_files private_files', 'execution packet')
        require(self.packet['schema'] == 'private_short_execution_binding_packet_v1', 'Wrong packet schema')
        refs = fields(self.packet['files'], ' '.join(CORE_LIMITS), 'core file references')
        self.core = {}
        identities = {self.packet_snapshot['identity'][:2]}
        for role, maximum in CORE_LIMITS.items():
            ref = fields(refs[role], 'path sha256', role)
            wanted = pin(ref['sha256'])
            item = self.read(self.path(ref['path']), maximum, empty=role == 'stderr')
            require(item['sha256'] == wanted, 'Raw input pin differs: ' + role)
            require(item['identity'][:2] not in identities, 'Core inputs must be distinct files')
            identities.add(item['identity'][:2])
            self.core[role] = item

    def path(self, value):
        require(type(value) is str and 0 < len(value) <= 4096 and '\x00' not in value, 'Invalid explicit input path')
        path = Path(value)
        return path if path.is_absolute() else self.packet_path.parent / path

    def read(self, path, maximum, keep=True, empty=False):
        item = snapshot(path, maximum, keep, empty)
        self.saved.append((path, maximum, empty, {k:v for k,v in item.items() if k != 'raw'}))
        return item

    def members(self, role, expected):
        references = self.packet[role + '_files']
        require(type(references) is list and len(references) == len(expected), 'Explicit member coverage differs')
        maximum = 1024**3 if role == 'bundle' else 8*1024**2
        total_limit = 2*1024**3 if role == 'bundle' else 128*1024**2
        require(sum(row['size_bytes'] for row in expected.values()) <= total_limit, 'Total retained member bytes exceed bound')
        seen = set()
        for ref in references:
            fields(ref, 'member path', role + ' member reference')
            member = ref['member']
            require(type(member) is str and member in expected and member not in seen, 'Unknown or repeated retained member')
            seen.add(member)
            row = expected[member]
            item = self.read(self.path(ref['path']), maximum, keep=False, empty=True)
            require(item['size_bytes'] == row['size_bytes'] and item['sha256'] == row['sha256'],
                    'Retained ' + role + ' member bytes differ: ' + member)
        return len(seen)

    def recheck(self):
        for path, maximum, empty, previous in self.saved:
            current = snapshot(path, maximum, keep=False, empty=empty)
            require({k:v for k,v in current.items() if k != 'raw'} == previous,
                    'Input changed during audit')

    def metadata(self):
        return {role:{k:item[k] for k in ('sha256', 'size_bytes')} for role,item in self.core.items()}
