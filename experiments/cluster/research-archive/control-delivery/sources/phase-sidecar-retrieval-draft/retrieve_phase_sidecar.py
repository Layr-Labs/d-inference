#!/usr/bin/env python3
"""Retrieve one successful phase launch's owned sidecar. Root executes actual SSH."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
from sidecar_contract import admit_run, decode_response
from sidecar_files import bounded_bytes, file_record, require, sha, write_json, write_new
from sidecar_ssh import SSHReadFailure, read_over_ssh


def retrieve(run, launcher_receipt_sha256, output, *, reader=read_over_ssh):
    output = Path(output).expanduser().absolute()
    # mkdir is the exclusive admission: an existing directory or symlink fails.
    output.mkdir(mode=0o700, parents=False)
    receipt = dict(kind='qwen_prefill_phase_sidecar_retrieval', schema_version=1, passed=False,
        created_at_utc=datetime.now(timezone.utc).isoformat(), primary_failure=None, cleanup_errors=[],
        model_or_native_executed=False, remote_file_modified=False,
        numerical_or_timing_semantics_audited=False, remote_process_reaping_verified=False)
    try:
        context = admit_run(run, launcher_receipt_sha256)
        receipt['admitted_run'] = context
        source = Path(__file__).parent / 'phase_sidecar_remote_reader.py'
        payload = bounded_bytes(source, 64 * 1024)
        write_new(output / 'remote-reader.py', payload)
        receipt['fixed_remote_reader'] = file_record('remote-reader.py', payload)
        try:
            stdout, stderr, observation = reader(context['host'], context['remote_path'], payload.decode('utf-8'))
        except SSHReadFailure as error:
            stdout, stderr, observation = error.stdout, error.stderr, error.observation
            receipt['ssh'] = observation
            receipt['primary_failure'], receipt['cleanup_errors'] = error.primary, error.cleanup
            write_new(output / 'ssh.stdout.bin', stdout)
            write_new(output / 'ssh.stderr.log', stderr)
            raise
        receipt['ssh'] = observation
        require(observation.get('local_reader_ssh_client_reaped') is True and not stderr,
                'Reader client was not successfully reaped')
        write_new(output / 'ssh.stdout.bin', stdout)
        write_new(output / 'ssh.stderr.log', stderr)
        raw, metadata, correlation = decode_response(stdout, context)
        write_new(output / 'phase-trace.json', raw)
        receipt['sidecar'] = dict(file_record('phase-trace.json', raw), mode='0600',
                                  remote_observation=metadata, request_correlation=correlation)
        # Bind the small controlling receipt/output/source archives again after SSH.
        require(admit_run(run, launcher_receipt_sha256) == context, 'Local admission evidence changed during retrieval')
        receipt['passed'] = True
    except BaseException as error:
        if receipt['primary_failure'] is None:
            receipt['primary_failure'] = dict(operation='sidecar_retrieval', error=type(error).__name__ + ': ' + str(error))
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
