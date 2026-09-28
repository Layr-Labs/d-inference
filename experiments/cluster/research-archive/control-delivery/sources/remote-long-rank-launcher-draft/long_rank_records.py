"""Bounded two-line framing and one exact source-bound warning per rank."""
import json
import math
from pathlib import Path
from long_reference_inputs import require
from long_rank_contract import validate, peers
from long_rank_configuration import timeout, hostfile
from long_rank_warning import check_stderr, WARNING

MAX_STDOUT = MAX_LINE = 8 * 1024**2
MAX_STDERR = len(WARNING)


def parse(data):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'Duplicate JSON key'); result[key] = value
        return result
    def number(value):
        result = float(value); require(math.isfinite(result), 'Nonfinite JSON'); return result
    def invalid(value):
        raise ValueError('Nonfinite JSON constant')
    return json.loads(data, object_pairs_hook=pairs, parse_float=number, parse_constant=invalid,
        parse_int=lambda value: -0.0 if value == '-0' else int(value))


class Records:
    def __init__(self, directory, rank, epoch, scheduling, inputs):
        self.directory, self.rank, self.epoch = Path(directory), rank, epoch
        self.scheduling, self.inputs = scheduling, inputs
        self.offset, self.pending, self.rows = 0, b'', []

    def poll(self, final=False):
        check_stderr(self.directory / 'stderr.log', final)
        path = self.directory / 'stdout.jsonl'
        size = path.stat().st_size if path.exists() else 0
        require(self.offset <= size <= MAX_STDOUT, 'Rank stdout shrank/exceeded bound')
        if size > self.offset:
            with path.open('rb') as stream:
                stream.seek(self.offset); chunk = stream.read(MAX_STDOUT - self.offset + 1)
            self.offset += len(chunk); self.pending += chunk
            require(self.offset <= MAX_STDOUT, 'Growing stdout exceeded bound')
        while b'\n' in self.pending:
            raw, self.pending = self.pending.split(b'\n', 1)
            require(raw and len(raw) <= MAX_LINE and len(self.rows) < 2, 'Invalid record length/count')
            row = parse(raw)
            validate(row, len(self.rows), self.rank, self.epoch, self.scheduling, self.inputs, self.rows[0] if self.rows else None)
            self.rows.append(row)
        require(len(self.pending) <= MAX_LINE, 'Partial rank record exceeds bound')
        if final:
            require(not self.pending and len(self.rows) == 2, 'EOF without both complete rank records')
