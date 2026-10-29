#!/usr/bin/env python3
"""Pinned, bounded CPU-only comparison. No imports of native launchers or process creation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from audit_common import (REFERENCE_SHA, PROMPT_SHA, REQUEST_ID, fields, exact, sha,
                          parse, request_context, agreement)
from audit_reference import check_reference
from audit_candidate import compare
from recorded_math import canonical, require
from snapshot import snapshot

LIMITS = dict(prompt=256*1024, reference_stdout=32*1024**2,
              rank0_evidence=16*1024**2, rank1_evidence=16*1024**2)


class PinnedInputs:
    def __init__(self, packet_path, packet_sha):
        self.packet_path = Path(packet_path).absolute()
        self.saved = []
        self.metadata = {}
        packet_item = self.read(self.packet_path, 64*1024, sha(packet_sha))
        packet = fields(parse(packet_item['raw']), 'schema request_id expected_agreement files', 'audit packet')
        exact(packet['schema'], 'private_generation128_comparison_packet_v1', 'packet schema')
        exact(packet['request_id'], REQUEST_ID, 'declared matched request')
        refs = fields(packet['files'], ' '.join(LIMITS), 'input references')
        self.raw = {}
        identities = {packet_item['identity'][:2]}
        for role, limit in LIMITS.items():
            ref = fields(refs[role], 'path sha256', role)
            label = ref['path']
            require(type(label) is str and 0 < len(label) <= 4096 and '\x00' not in label, 'Invalid input path')
            path = Path(label)
            if not path.is_absolute():
                path = self.packet_path.parent / path
            item = self.read(path, limit, sha(ref['sha256']))
            require(item['identity'][:2] not in identities, 'Distinct input files required')
            identities.add(item['identity'][:2])
            self.raw[role] = item['raw']
            self.metadata[role] = dict(sha256=item['sha256'], size_bytes=item['size_bytes'])
        exact(self.metadata['reference_stdout']['sha256'], REFERENCE_SHA, 'frozen actual reference pin')
        exact(self.metadata['prompt']['sha256'], PROMPT_SHA, 'matched prompt raw pin')
        self.context = request_context(self.raw['prompt'], packet['request_id'])
        agreement(packet['expected_agreement'], self.context)
        self.expected_agreement = packet['expected_agreement']
        self.packet_sha = packet_item['sha256']

    def read(self, path, limit, expected):
        item = snapshot(path, limit)
        require(item['sha256'] == expected, 'Pinned input bytes differ')
        self.saved.append((path, limit, {k:v for k,v in item.items() if k != 'raw'}))
        return item

    def recheck(self):
        for path, limit, saved in self.saved:
            item = snapshot(path, limit, keep=False)
            require({k:v for k,v in item.items() if k != 'raw'} == saved, 'Input changed during CPU comparison')


def audit(packet_path, packet_sha):
    inputs = PinnedInputs(packet_path, packet_sha)
    reference = check_reference(inputs.raw['reference_stdout'], inputs.context)
    candidates = [parse(inputs.raw['rank0_evidence']), parse(inputs.raw['rank1_evidence'])]
    result = compare(reference, candidates, inputs.expected_agreement, inputs.context)
    inputs.recheck()
    result.update(packetSHA256=inputs.packet_sha, rawInputs=inputs.metadata, rawInputSnapshotsRechecked=True)
    return result


def write_result(path, value):
    data = canonical(value) + b'\n'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--packet', required=True)
    parser.add_argument('--packet-sha256', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    status = 0
    try:
        result = audit(args.packet, args.packet_sha256)
    except Exception as error:
        status = 1
        result = dict(schema='private_generation128_numerical_comparison_v1', status='failed',
                      error=(type(error).__name__ + ': ' + str(error))[:2048],
                      numericalComparisonPassed=False, physicalTransferQualified=False,
                      performanceQualification=False, throughputMeasurementValid=False)
    write_result(args.output, result)
    print(json.dumps(dict(status=result['status'], outputSHA256=hashlib.sha256(canonical(result) + b'\n').hexdigest()),
                     sort_keys=True, separators=(',', ':')))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
