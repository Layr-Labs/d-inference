#!/usr/bin/env python3
"""Retrieve four sidecars of a passed cut12 rank-owner run; root executes actual SSH."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
from rank_sidecar_admission import admit_run
from owner_sidecar_response import decode_response
from sidecar_files import bounded_bytes, file_record, require, write_json, write_new
from sidecar_ssh import SSHReadFailure, read_over_ssh


def retrieve(run, launcher_receipt_sha256, output, *, reader=read_over_ssh):
    output = Path(output).expanduser().absolute()
    output.mkdir(mode=0o700, parents=False)
    receipt = dict(kind='qwen_prefill_rank_cut_owner_sidecar_retrieval', schema_version=1, passed=False,
        created_at_utc=datetime.now(timezone.utc).isoformat(), primary_failure=None,
        cleanup_errors=[], sidecars=[], model_or_native_executed=False, remote_file_modified=False,
        numerical_or_timing_semantics_audited=False, remote_process_reaping_verified=False,
        cross_process_clock_comparison_performed=False)
    active_name, active_rank = None, None
    try:
        context = admit_run(run, launcher_receipt_sha256)
        receipt['admitted_run'] = context
        receipt['fixed_remote_readers'] = []
        for sidecar in context['sidecars']:
            active_name, active_rank = sidecar['name'], sidecar['rank']
            relative = 'rank-' + str(active_rank) + '/' + active_name
            if active_name == 'phase':
                (output / ('rank-' + str(active_rank))).mkdir(mode=0o700)
            directory = output / relative
            directory.mkdir(mode=0o700)
            source = Path(__file__).parent / (active_name + '_sidecar_remote_reader.py')
            payload = bounded_bytes(source, 64 * 1024)
            write_new(directory / 'remote-reader.py', payload)
            receipt['fixed_remote_readers'].append(file_record(relative + '/remote-reader.py', payload))
            result = dict(rank=active_rank, name=active_name, passed=False)
            receipt['sidecars'].append(result)
            try:
                stdout, stderr, observation = reader(sidecar['host'], sidecar['remote_path'], payload.decode('utf-8'))
            except SSHReadFailure as error:
                result['ssh'] = error.observation
                receipt['primary_failure'] = dict(error.primary, rank=active_rank, sidecar=active_name)
                receipt['cleanup_errors'] = [dict(item, rank=active_rank, sidecar=active_name) for item in error.cleanup]
                write_new(directory / 'ssh.stdout.bin', error.stdout)
                write_new(directory / 'ssh.stderr.log', error.stderr)
                raise
            result['ssh'] = observation
            write_new(directory / 'ssh.stdout.bin', stdout)
            write_new(directory / 'ssh.stderr.log', stderr)
            require(observation.get('local_reader_ssh_client_reaped') is True and not stderr,
                    'Reader SSH client not successfully reaped')
            raw, metadata, correlation = decode_response(stdout, sidecar)
            filename = active_name + '-trace.json'
            write_new(directory / filename, raw)
            result['sidecar'] = dict(file_record(relative + '/' + filename, raw), mode='0600',
                                    remote_observation=metadata, request_correlation=correlation)
            require(admit_run(run, launcher_receipt_sha256) == context,
                    'Local admission evidence changed during retrieval')
            result['passed'] = True
        require([(row['rank'], row['name']) for row in receipt['sidecars']]
                == [(0, 'phase'), (0, 'owner'), (1, 'phase'), (1, 'owner')]
                and all(row['passed'] for row in receipt['sidecars']), 'All four sidecars are required')
        receipt['passed'] = True
    except BaseException as error:
        if receipt['primary_failure'] is None:
            receipt['primary_failure'] = dict(operation='rank_cut_owner_sidecar_retrieval', rank=active_rank, sidecar=active_name,
                error=type(error).__name__ + ': ' + str(error))
    receipt['helper_sources'] = [file_record(path.name, bounded_bytes(path, 256 * 1024))
        for path in sorted(Path(__file__).parent.glob('*.py')) if not path.name.startswith('test_')]
    write_json(output / 'receipt.json', receipt)
    return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--launcher-receipt-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    result = retrieve(args.run, args.launcher_receipt_sha256, args.output)
    print(str(args.output / 'receipt.json'))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
