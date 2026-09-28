"""Two bounded records and exact mode-specific stderr; no timing interpretation."""
from pathlib import Path
from .common import parse, require
from . import archive, long_rank_contract, long_solo_contract

MAX_STDOUT = MAX_LINE = 8 * 1024**2
WARNING = b'Using loopback-test transport for correctness only; timings are not cluster-performance evidence\n'


def source_stderr_contract(output, paired):
    if not paired: return dict(expected_utf8='', empty_required=True)
    base = output / 'source/experiments/cluster/inference/Sources/ClusterInference'
    paths = {name: base / name for name in ('Collective.swift','Options.swift')}
    for path in paths.values(): require(path.stat().st_size <= 1024**2, 'Warning source exceeds bound')
    text = paths['Collective.swift'].read_text(); logger = paths['Options.swift'].read_text()
    literal = 'log("' + WARNING.decode().rstrip('\n') + '")'
    require(text.count(literal) == 1 and 'if transport == .loopbackTest {\n            ' + literal in text,
            'Archived loopback warning branch differs')
    require('func log(_ message: String) {\n    FileHandle.standardError.write(Data((message + "\\n").utf8))\n}' in logger,
            'Archived warning encoding differs')
    return dict(expected_utf8=WARNING.decode(), exact_one_line_required=True,
                source_sha256={name: archive.digest(path) for name, path in paths.items()})


class Records:
    def __init__(self, directory, rank, context):
        self.directory, self.rank, self.context = Path(directory), rank, context
        self.offset, self.pending, self.rows = 0, b'', []
        self.paired = context['mode'] == 'long-prefill-ranks'

    def poll(self, final=False):
        expected = WARNING if self.paired else b''
        stderr = self.directory / 'stderr.log'
        if stderr.exists():
            require(stderr.stat().st_size <= len(expected), 'Unexpected long-check stderr')
            error = stderr.read_bytes()
        else: error = b''
        require(expected.startswith(error) and (not final or error == expected), 'Long-check stderr differs from source contract')
        path = self.directory / 'stdout.jsonl'; size = path.stat().st_size if path.exists() else 0
        require(self.offset <= size <= MAX_STDOUT, 'Long-check stdout shrank or exceeds8MiB')
        if size > self.offset:
            with path.open('rb') as stream:
                stream.seek(self.offset); chunk = stream.read(MAX_STDOUT - self.offset + 1)
            self.offset += len(chunk); self.pending += chunk
            require(self.offset <= MAX_STDOUT, 'Long-check stdout grew beyond bound')
        while b'\n' in self.pending:
            raw, self.pending = self.pending.split(b'\n', 1)
            require(raw and len(raw) <= MAX_LINE and len(self.rows) < 2, 'Unexpected long-check record count/size')
            value = parse(raw)
            if self.paired:
                long_rank_contract.validate(value, len(self.rows), self.rank, self.context['epoch'],
                    self.context['stage_prefill_policy'], self.context, self.rows[0] if self.rows else None)
            else:
                long_solo_contract.validate(value, len(self.rows), self.context, self.rows[0] if self.rows else None)
            self.rows.append(value)
        require(len(self.pending) <= MAX_LINE, 'Partial long record exceeds bound')
        if final: require(not self.pending and len(self.rows) == 2, 'EOF without two complete long-check records')
