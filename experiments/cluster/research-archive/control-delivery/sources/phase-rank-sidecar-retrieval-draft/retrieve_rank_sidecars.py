#!/usr/bin/env python3
"""Read both completed rank-phase sidecars; root owns actual SSH execution."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
from rank_sidecar_admission import admit_run
from rank_sidecar_response import decode_response
from sidecar_files import bounded_bytes, file_record, require, write_json, write_new
from sidecar_ssh import SSHReadFailure, read_over_ssh


def retrieve(run, launcher_receipt_sha256, output, *, reader=read_over_ssh):
    output = Path(output).expanduser().absolute()
    output.mkdir(mode=0o700, parents=False)
    receipt = dict(kind='qwen_prefill_rank_phase_sidecar_retrieval', schema_version=1, passed=False,
        created_at_utc=datetime.now(timezone.utc).isoformat(), primary_failure=None, cleanup_errors=[], ranks=[],
        model_or_native_executed=False, remote_file_modified=False, remote_process_reaping_verified=False,
        numerical_or_timing_semantics_audited=False, cross_process_clock_comparison_performed=False)
    try:
        context = admit_run(run, launcher_receipt_sha256)
        receipt['admitted_run'] = context
        source = Path(__file__).parent / 'phase_sidecar_remote_reader.py'
        payload = bounded_bytes(source, 64 * 1024)
        write_new(output / 'remote-reader.py', payload)
        receipt['fixed_remote_reader'] = file_record('remote-reader.py', payload)
        for rank in context['ranks']:
            directory = output / ('rank-' + str(rank['rank']))
            directory.mkdir(mode=0o700)
            result = dict(rank=rank['rank'], passed=False)
            receipt['ranks'].append(result)
            try:
                stdout, stderr, observation = reader(rank['host'], rank['remote_path'], payload.decode('utf-8'))
            except SSHReadFailure as error:
                result['ssh'] = error.observation
                receipt['primary_failure'] = dict(error.primary, rank=rank['rank'])
                receipt['cleanup_errors'] = [dict(item, rank=rank['rank']) for item in error.cleanup]
                write_new(directory / 'ssh.stdout.bin', error.stdout)
                write_new(directory / 'ssh.stderr.log', error.stderr)
                raise
            result['ssh'] = observation
            require(observation.get('local_reader_ssh_client_reaped') is True and not stderr, 'Reader SSH client not reaped')
            write_new(directory / 'ssh.stdout.bin', stdout)
            write_new(directory / 'ssh.stderr.log', stderr)
            raw, metadata, correlation = decode_response(stdout, rank)
            write_new(directory / 'phase-trace.json', raw)
            result['sidecar'] = dict(file_record('rank-' + str(rank['rank']) + '/phase-trace.json', raw), mode='0600',
                                     remote_observation=metadata, request_correlation=correlation)
            require(admit_run(run, launcher_receipt_sha256) == context, 'Local admission evidence changed during retrieval')
            result['passed'] = True
        require(len(receipt['ranks']) == 2 and all(rank['passed'] for rank in receipt['ranks']), 'Both sidecars required')
        receipt['passed'] = True
    except BaseException as error:
        if receipt['primary_failure'] is None:
            receipt['primary_failure'] = dict(operation='rank_sidecar_retrieval', error=type(error).__name__ + ': ' + str(error))
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
    receipt = retrieve(args.run, args.launcher_receipt_sha256, args.output)
    print(str(args.output / 'receipt.json'))
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
