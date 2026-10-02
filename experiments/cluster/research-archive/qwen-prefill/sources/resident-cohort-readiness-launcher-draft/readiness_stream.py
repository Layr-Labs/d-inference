"""One bounded JSONL success record; negative cases retain raw empty stdout."""
import json
import math
import stat
from pathlib import Path
from readiness_config import require

LIMIT = 64 * 1024
WARNING = b'Using loopback-test transport for correctness only; timings are not cluster-performance evidence\n'
MISMATCH = b'cluster-inference: Resident ranks disagree on ordered requests, warmups, source or policy before stage load\n'


def strict_json(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    def finite(value):
        number = float(value)
        require(math.isfinite(number), 'Nonfinite JSON number')
        return number
    def invalid(_):
        raise ValueError('Nonfinite JSON constant')
    return json.loads(raw, object_pairs_hook=pairs, parse_float=finite, parse_constant=invalid)


class Streams:
    def __init__(self, directory, rank, epoch, scenario, validate):
        self.directory, self.rank, self.epoch = Path(directory), rank, epoch
        self.scenario, self.validate = scenario, validate
        self.identities, self.sizes, self.raw = {}, {}, {}
        self.record = None

    def _read(self, name):
        path = self.directory / name
        if not path.exists():
            require(name not in self.identities, 'Native stream disappeared')
            return b''
        require(not path.is_symlink(), 'Native stream is a symlink')
        with path.open('rb') as handle:
            import os
            observed = os.fstat(handle.fileno())
            require(stat.S_ISREG(observed.st_mode) and observed.st_size <= LIMIT,
                    'Native stream is nonregular or too large')
            identity = (observed.st_dev, observed.st_ino)
            require(name not in self.identities or self.identities[name] == identity,
                    'Native stream identity changed')
            data = handle.read(LIMIT + 1)
        require(len(data) <= LIMIT and len(data) >= self.sizes.get(name, 0), 'Native stream shrank or exceeded its bound')
        require(data.startswith(self.raw.get(name, b'')), 'Already observed native bytes changed')
        self.identities[name], self.sizes[name], self.raw[name] = identity, len(data), data
        return data

    def poll(self):
        stdout, stderr = self._read('stdout.jsonl'), self._read('stderr.log')
        expected = WARNING + MISMATCH if self.scenario == 'warmup-mismatch' and self.rank == 1 else WARNING
        require(expected.startswith(stderr), 'Unexpected native stderr')
        lines = stdout.split(b'\n')
        require(len(lines) <= 2 and (len(lines) < 2 or lines[-1] == b''), 'Native stdout must contain one complete line')
        if len(lines) == 2:
            require(lines[0], 'Empty native JSONL record')
            record = strict_json(lines[0].decode('utf-8'))
            self.validate(record, self.rank, self.epoch, self.scenario)
            if self.record is not None:
                require(record == self.record, 'Native success record changed')
            self.record = record

    def success(self):
        self.poll()
        require(self.record is not None and self.raw.get('stderr.log') == WARNING,
                'Success requires one complete record and the exact warning')

    def negative(self, mismatch=False):
        self.poll()
        require(not self.raw.get('stdout.jsonl', b''), 'Negative case emitted post-agreement output')
        expected = WARNING + MISMATCH if mismatch else WARNING
        require(self.raw.get('stderr.log', b'') == expected, 'Negative case lacks its exact diagnostic')
