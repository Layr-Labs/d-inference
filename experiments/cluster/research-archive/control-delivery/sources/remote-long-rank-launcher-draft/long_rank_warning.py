"""Admit only the one warning emitted by the archived loopback source path."""
from pathlib import Path
from prefill_compute_archive import digest
from long_reference_inputs import require

WARNING = b'Using loopback-test transport for correctness only; timings are not cluster-performance evidence\n'


def source_warning(output):
    base = Path(output) / 'source/experiments/cluster/inference/Sources/ClusterInference'
    collective, options = base / 'Collective.swift', base / 'Options.swift'
    text, logger = collective.read_text(), options.read_text()
    literal = 'log("' + WARNING.decode().rstrip('\n') + '")'
    require(text.count(literal) == 1 and 'if transport == .loopbackTest {\n            ' + literal in text,
            'Archived Collective loopback warning source differs')
    require('func log(_ message: String) {\n    FileHandle.standardError.write(Data((message + "\\n").utf8))\n}' in logger,
            'Archived warning encoding differs')
    return dict(expected_utf8=WARNING.decode(), exact_one_line_required=True,
        source_sha256={'Collective.swift': digest(collective), 'Options.swift': digest(options)})


def check_stderr(path, final=False):
    path = Path(path)
    size = path.stat().st_size if path.exists() else 0
    require(size <= len(WARNING), 'Unexpected additional rank stderr bytes')
    data = path.read_bytes() if path.exists() else b''
    require(WARNING.startswith(data), 'Rank stderr differs from exact loopback warning')
    if final:
        require(data == WARNING, 'Successful rank omitted its exact loopback warning')
