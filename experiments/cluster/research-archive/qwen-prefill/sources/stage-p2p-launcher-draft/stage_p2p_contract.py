"""Small closed identity contract for the no-model stage transport check."""

import json
import math
import re
from pathlib import Path

MAX_STDOUT_BYTES = 4 * 1024 * 1024
MAX_STDERR_BYTES = 4 * 1024 * 1024
MAX_LINE_BYTES = 2 * 1024 * 1024


def require_timeout(value):
    if type(value) is not int or not 1 <= value <= 60:
        raise ValueError('timeout_seconds must be an integer between 1 and 60')
    return value


def require_epoch(value):
    if not isinstance(value, str) or re.fullmatch(r'[0-9a-f]{32}', value) is None:
        raise ValueError('epoch must be 32 lowercase hex digits')
    return value


def rank_configuration(bundle, bundle_hash, rank, epoch, timeout, hosts):
    require_timeout(timeout)
    require_epoch(epoch)
    if type(rank) is not int or rank not in (0, 1):
        raise ValueError('Only local ranks 0 and 1 are admitted')
    if not isinstance(hosts, list) or len(hosts) != 2:
        raise ValueError('Exactly two loopback endpoints are required')
    ports = set()
    for row in hosts:
        if not isinstance(row, list) or len(row) != 1 or not isinstance(row[0], str):
            raise ValueError('One endpoint per rank is required')
        match = re.fullmatch(r'127\.0\.0\.1:([0-9]{1,5})', row[0])
        if match is None or not 1 <= int(match[1]) <= 65535 or int(match[1]) in ports:
            raise ValueError('Only two distinct IPv4 loopback ports are admitted')
        ports.add(int(match[1]))
    return dict(bundle=str(bundle), bundle_sha256=bundle_hash, rank=rank,
                arguments=['--mode', 'stage-p2p-check', '--synthetic', '--transport',
                           'loopback-test', '--timeout-seconds', str(timeout), '--epoch', epoch],
                environment={'MLX_RANK': str(rank)},
                environment_files={'MLX_HOSTFILE': 'hosts.json'}, input_files={'hosts.json': hosts},
                timeout_seconds=timeout, persistent=False)


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate JSON key')
            result[key] = value
        return result
    def invalid_constant(value):
        raise ValueError('Nonfinite JSON constant: ' + value)
    def finite_float(value):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError('Nonfinite JSON number')
        return number
    return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid_constant, parse_float=finite_float)


def validate_record(record, rank, epoch):
    if not isinstance(record, dict):
        raise ValueError('Native record must be an object')
    for key, expected in [('schemaVersion', 1), ('rank', rank), ('worldSize', 2)]:
        if type(record.get(key)) is not int or record[key] != expected:
            raise ValueError('Native integer identity mismatch: ' + key)
    for key, expected in [('epoch', epoch), ('transport', 'loopback-test'), ('backend', 'ring')]:
        if record.get(key) != expected:
            raise ValueError('Native identity mismatch: ' + key)
    kind = record.get('kind')
    if kind not in ('stage_p2p_ready', 'stage_p2p_check'):
        raise ValueError('Unexpected native record kind')
    if kind == 'stage_p2p_check':
        for key, expected in [('passed', True), ('correctnessOnly', True),
                              ('throughputMeasurementValid', False)]:
            if type(record.get(key)) is not bool or record[key] is not expected:
                raise ValueError('Native terminal classification mismatch: ' + key)
        digest = record.get('fixtureFingerprint')
        if not isinstance(digest, str) or re.fullmatch(r'[0-9a-f]{64}', digest) is None:
            raise ValueError('Native terminal fixture fingerprint is missing or malformed')
        cases = record.get('cases')
        if not isinstance(cases, list) or not 1 <= len(cases) <= 256 or any(not isinstance(c, dict) for c in cases):
            raise ValueError('Native terminal cases must be a bounded nonempty object array')
    return kind


class RankRecords:
    """Incremental file reader; two bounded JSONL records, no pipe backpressure."""
    def __init__(self, directory, rank, epoch):
        self.directory, self.rank, self.epoch = Path(directory), rank, epoch
        self.offset, self.pending, self.records = 0, b'', []
        self.terminal = None

    def poll(self, final=False):
        stderr = self.directory / 'stderr.log'
        if stderr.exists() and stderr.stat().st_size > MAX_STDERR_BYTES:
            raise ValueError('Native stderr exceeded its bound')
        path = self.directory / 'stdout.jsonl'
        size = path.stat().st_size if path.exists() else 0
        if size < self.offset or size > MAX_STDOUT_BYTES:
            raise ValueError('Native stdout shrank or exceeded its bound')
        if size > self.offset:
            with path.open('rb') as stream:
                stream.seek(self.offset)
                data = stream.read(MAX_STDOUT_BYTES - self.offset + 1)
            self.offset += len(data)
            if self.offset > MAX_STDOUT_BYTES:
                raise ValueError('Native stdout exceeded its bound while reading')
            self.pending += data
        while b'\n' in self.pending:
            line, self.pending = self.pending.split(b'\n', 1)
            if not line or len(line) > MAX_LINE_BYTES or len(self.records) >= 2 or self.terminal is not None:
                raise ValueError('Invalid native JSONL record count, order or size')
            record = strict_json(line.decode('utf-8'))
            kind = validate_record(record, self.rank, self.epoch)
            if self.records and kind != 'stage_p2p_check':
                raise ValueError('Only one optional ready record may precede the terminal record')
            self.records.append(record)
            if kind == 'stage_p2p_check':
                self.terminal = record
        if len(self.pending) > MAX_LINE_BYTES:
            raise ValueError('Native partial JSONL record exceeded its bound')
        if final and (self.pending or self.terminal is None):
            raise ValueError('Native EOF arrived without exactly one complete terminal record')


def validate_pair(readers):
    if len(readers) != 2 or any(reader.terminal is None for reader in readers):
        raise ValueError('Both ranks must complete')
    a, b = (reader.terminal for reader in readers)
    if a['fixtureFingerprint'] != b['fixtureFingerprint']:
        raise ValueError('Peer fixture fingerprints differ')
    if len(a['cases']) != len(b['cases']):
        raise ValueError('Peer native case counts differ')
    return dict(terminal_records=2, fixture_fingerprint=a['fixtureFingerprint'],
                case_counts=[len(a['cases']), len(b['cases'])], native_assertions_passed=True,
                payloads_independently_rederived_by_launcher=False)
