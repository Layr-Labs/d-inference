#!/usr/bin/env python3
"""Guarded one-process registered-9B 8K full-model/stage comparison; root executes it."""
import argparse
import json
from pathlib import Path
import signal
import sys
import uuid
from prefill_compute_archive import archive_launcher, archive_sources, digest, load_archived_runtime, verify_archive, write_json
from long_reference_artifacts import native_file_receipts, verified_remote, verify_local
from long_reference_configuration import configuration, timeout, REQUIRED_ENVIRONMENT, NATIVE_TIMEOUT_SECONDS
from long_reference_inputs import ARTIFACT, CONFIGURATION, archive_inputs, is_sha256, require
from remote_prefill_client import RemoteControl, RemoteMemoryGate, collect_metadata, create_remote, prepare_controls, upload_new
from remote_prefill_paths import absolute_path, host_alias
from remote_prefill_supervision import supervise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('release', 'runtime', 'output', 'prompt-file', 'prompt-origin-file'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('long-prompt-sha256', 'prompt-origin-sha256', 'artifact-aggregate-sha256', 'expected-native-sha256'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--host', type=host_alias, required=True)
    parser.add_argument('--remote-model-dir', required=True)
    parser.add_argument('--remote-run-root')
    parser.add_argument('--parent-timeout-seconds', type=int, default=330)
    args = parser.parse_args(argv)
    timeout(args.parent_timeout_seconds)
    absolute_path(args.remote_model_dir)
    if args.remote_run_root:
        absolute_path(args.remote_run_root)
    require(args.artifact_aggregate_sha256 == ARTIFACT and is_sha256(args.expected_native_sha256),
            'Explicit registered artifact and native binary pins required')
    runtime = args.runtime.resolve(strict=True)
    output = args.output.expanduser().resolve()
    require(not output.exists() and not output.is_relative_to(runtime.parents[2]),
            'Output must be new and outside the repository')
    output.mkdir(parents=True, mode=0o700)
    run_id, gate, rank, modules = uuid.uuid4().hex, RemoteMemoryGate(), None, None
    children, handlers = [], {}
    receipt = dict(kind='remote_qwen_long_prefill_pair_launcher', schema_version=1, run_id=run_id,
        passed=False, execution_host=args.host, native_execution_attempted=False, native_process_count=1,
        physical_two_machine_execution=False, interprocess_model_transport=False, throughput_qualification=False,
        independent_reference_oracle_run=False, parent_timeout_seconds=args.parent_timeout_seconds,
        native_timeout_seconds=NATIVE_TIMEOUT_SECONDS, artifact_aggregate_sha256=ARTIFACT,
        configuration_sha256=CONFIGURATION, primary_failure=None, cleanup_errors=[], post_run_errors=[],
        full_reference_forward_requested=True, stage_model_forward_requested=True, timing_requested=False)
    try:
        launcher = archive_launcher(output)
        sources = archive_sources(runtime, output)
        modules = load_archived_runtime(output, run_id)
        inputs = archive_inputs(args.prompt_file, args.long_prompt_sha256,
                                args.prompt_origin_file, args.prompt_origin_sha256, output)
        receipt['inputs'] = inputs
        bundle_hash = modules['bundle'].snapshot(args.release.resolve(strict=True), output / 'bundle')
        require(digest(output / 'bundle/cluster-inference') == args.expected_native_sha256, 'Frozen native binary pin differs')
        verify_archive(modules, output, sources, bundle_hash, launcher)
        expected_files = {entry['path']: entry['sha256'] for entry in json.loads((output / 'bundle/bundle.json').read_text())['files']}
        layout = create_remote(modules['processes'], args.host, args.remote_model_dir, args.remote_run_root, run_id)
        receipt['remote_paths'] = layout
        local = output / 'native'
        local.mkdir(mode=0o700)
        write_json(local / 'rank.json', configuration(layout['bundle'], bundle_hash, layout['model'], args.long_prompt_sha256))
        config = dict(layout, run_id=run_id, bundle_sha256=bundle_hash, binary_sha256=args.expected_native_sha256,
            rank_sha256=digest(local / 'rank.json'), artifact_sha256=ARTIFACT, configuration_sha256=CONFIGURATION,
            prompt_sha256=args.long_prompt_sha256, prompt_size_bytes=(output / 'inputs/prompt.json').stat().st_size,
            required_environment=dict(REQUIRED_ENVIRONMENT))
        control_hash = prepare_controls(output, layout, config)
        upload_new(modules['processes'], args.host, output / 'controls', layout['controls'])
        control = RemoteControl(modules['processes'], args.host, layout, run_id, control_hash, output)
        receipt.update(control_manifest_sha256=control_hash, source_manifest_sha256=digest(output / 'source-manifest.json'),
            source_file_count=len(sources['files']), launcher_files=launcher, bundle_manifest_sha256=bundle_hash,
            expected_native_sha256=args.expected_native_sha256, rank_configuration_sha256=config['rank_sha256'])
        initial = control.call('initial', timeout=10)
        receipt['remote_initial_free_screen'] = initial
        require(initial.get('passed') is True and type(initial.get('actual_free_bytes')) is int
                and initial['actual_free_bytes'] >= 6 * 1024**3,
                'Initial actual-free screen refused before remote bundle/model reads')
        upload_new(modules['processes'], args.host, output / 'bundle', layout['bundle'])
        upload_new(modules['processes'], args.host, local / 'rank.json', layout['native'] + '/rank.json')
        upload_new(modules['processes'], args.host, output / 'inputs/prompt.json', layout['native'] + '/prompt.json')
        before = control.call('before')
        receipt['remote_before'] = before
        verified_remote(before, config, expected_files)
        gate.consume(before['memory'])
        require(before['posthash_preflight'].get('passed') is True,
                'Post-hash reclaimable/disk/descriptor screen refused')
        rank = dict(rank=0, host=args.host, directory=layout['native'], local=str(local), bundle=layout['bundle'])
        def interrupted(signum, _frame):
            raise SystemExit(128 + signum)
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            handlers[signum] = signal.signal(signum, interrupted)
        def start(value):
            child = modules['processes'].start(value)
            children.append(child)
            return child
        def observe(seconds):
            gate.consume(control.call('observe', timeout=seconds))
        receipt['native_execution_attempted'] = True
        write_json(output / 'receipt.json', receipt)
        receipt['execution'] = supervise(rank, inputs, args.parent_timeout_seconds, start,
            modules['processes'].stop_processes, observe)
        execution = receipt['execution']
        receipt['cleanup_errors'].extend(execution['cleanup_errors'])
        if not execution['passed']:
            receipt['primary_failure'] = dict(operation='native_supervision',
                reason=execution['cancellation_reason'], error=execution['error'])
        after = control.call('after')
        receipt['remote_after'] = after
        verified_remote(after, config, expected_files)
        gate.consume(after['memory'])
        require(not after['memory']['remote_pid_inventory']['observed_processes'],
                'Owned remote processes still observed after SSH completion')
        for name in ('config.json', 'manifest.json'):
            require(before['model_metadata'][name]['sha256'] == after['model_metadata'][name]['sha256'],
                    'Remote original model metadata changed')
        receipt['retrieved_remote_metadata'] = collect_metadata(modules['processes'], args.host, layout, before, after, output)
        verify_local(modules, output, sources, bundle_hash, launcher, inputs, config, control_hash)
        receipt['source_bundle_raw_inputs_and_remote_model_unchanged_after_run'] = True
        receipt['passed'] = execution['passed']
    except BaseException as error:
        receipt['passed'] = False
        failure = dict(operation='launcher', error=type(error).__name__ + ': ' + str(error))
        if receipt['primary_failure'] is None:
            receipt['primary_failure'] = failure
        else:
            receipt['post_run_errors'].append(failure)
    finally:
        if children and not receipt['passed']:
            try:
                modules['processes'].stop_processes([rank], children)
            except BaseException as error:
                receipt['cleanup_errors'].append(dict(operation='final_stop_owned_run', error=repr(error)))
        receipt['remote_memory_samples'] = gate.samples
        receipt['observed_remote_supervisor_pids'] = sorted({row['pid'] for sample in gate.samples
            for row in sample.get('remote_pid_inventory', {}).get('observed_processes', []) if row['kind'] == 'supervisor'})
        receipt['observed_remote_native_pids'] = sorted({row['pid'] for sample in gate.samples
            for row in sample.get('remote_pid_inventory', {}).get('observed_processes', []) if row['kind'] == 'native'})
        receipt['remote_pid_observations_are_not_reaping_proof'] = True
        receipt['resource_policy'] = 'initial actual free>=6GiB before remote bundle/model reads; posthash reclaimable>=8GiB; pressure<=2; zero reported swap; fixed native300s and parent<=330s'
        receipt['local_model_payload_verified'] = False
        try:
            receipt['native_files'] = native_file_receipts(output)
        except BaseException as error:
            receipt['passed'] = False
            failure = dict(operation='archive_native_outputs', error=type(error).__name__ + ': ' + str(error))
            if receipt['primary_failure'] is None:
                receipt['primary_failure'] = failure
            else:
                receipt['post_run_errors'].append(failure)
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
        write_json(output / 'receipt.json', receipt)
    print(str(output / 'receipt.json'))
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
