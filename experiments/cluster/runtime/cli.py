"""Command-line entry point for reproducible native inference rank runs."""

import argparse
import concurrent.futures
import datetime
import json
from pathlib import Path
import sys
import uuid

from .bundle import snapshot
from .configuration import loopback_addresses, validate
from .processes import collect_logits, run_cohort, stage
from .reports import reports


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--spec', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True,
                        help='Directory containing the release executable and its resources')
    parser.add_argument('--output', type=Path, required=True,
                        help='New private run directory outside the repository')
    args = parser.parse_args()
    try:
        spec = validate(json.loads(args.spec.read_text()))
        output = args.output.resolve()
        repository = Path(__file__).resolve().parents[3]
        if output.is_relative_to(repository):
            raise ValueError('Output must be outside the repository, including through symlinks')
        if output.exists():
            raise ValueError('Output directory must be new')
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.error(str(error))
    output.mkdir(parents=True, mode=0o700)
    run_id = uuid.uuid4().hex
    manifest = dict(schema_version=1, run_id=run_id, started_at=now(), spec=spec)
    manifest_path = output / 'run.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    exit_code = 1
    try:
        bundle_hash = snapshot(args.bundle.resolve(), output / 'bundle')
        manifest['bundle_manifest_sha256'] = bundle_hash
        hostfile = loopback_addresses() if spec['backend'] == 'loopback-test' else None
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(spec['ranks'])) as pool:
            ranks = list(pool.map(lambda index: stage(
                spec, index, output, bundle_hash, hostfile, run_id), range(len(spec['ranks']))))
        manifest['ranks'] = ranks
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        manifest.update(run_cohort(ranks, spec['timeout_seconds'] + 5))
        if all(code == 0 for code in manifest['exit_codes']):
            manifest['reports'] = reports(ranks, spec)
            if spec['capture_logits']:
                for rank in ranks:
                    collect_logits(rank)
            manifest['verified_execution'] = True
            # This flag never certifies a speedup or numerical parity by itself.
            manifest['hardware_throughput_candidate'] = (
                spec['backend'] != 'loopback-test'
                and not spec['workload'].get('synthetic')
                and not spec['capture_logits']
                and all(r.get('throughputMeasurementValid') for r in manifest['reports'])
            )
            exit_code = 0
    except Exception as error:
        manifest['error'] = str(error)
        print(f'Inference launcher: {error}', file=sys.stderr)
    finally:
        manifest['finished_at'] = now()
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(output=str(output), exit_code=exit_code)))
    return exit_code
