"""Bounded output receipts and post-run source/control/input pin checks."""
import json
from prefill_compute_archive import digest, verify_archive
from long_reference_inputs import require
from long_rank_staging import verify_local_rank_inputs
from long_rank_warning import source_warning
from long_rank_records import MAX_STDOUT, MAX_STDERR


def verify_local(modules, output, sources, bundle_hash, launcher, inputs, config, controls_hash, scheduling, warning):
    verify_archive(modules, output, sources, bundle_hash, launcher)
    verify_local_rank_inputs(output, config, inputs, scheduling)
    require(source_warning(output) == warning, 'Archived stderr source identity changed')
    path = output / 'controls/control-manifest.json'
    require(digest(path) == controls_hash, 'Local control manifest changed')
    modules['artifacts'].verify_files(output / 'controls', json.loads(path.read_text())['files'])


def rank_file_receipts(output):
    records = []
    caps = [('rank.json',256 * 1024),('prompt.json',65536),('hosts.json',1024),
            ('stdout.jsonl',MAX_STDOUT),('stderr.log',MAX_STDERR)]
    for rank in range(2):
        for name, maximum in caps:
            path = output / ('rank-' + str(rank)) / name
            if not path.is_file(): continue
            size = path.stat().st_size
            records.append(dict(path=path.relative_to(output).as_posix(),rank=rank,size_bytes=size,
                sha256=digest(path) if size <= maximum else None,
                hash_omitted_because_oversized=size > maximum,maximum_bytes=maximum))
    return records
