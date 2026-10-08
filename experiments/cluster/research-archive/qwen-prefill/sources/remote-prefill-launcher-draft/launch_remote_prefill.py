#!/usr/bin/env python3
"""Root-run remote-host adaptation of the frozen one-process prefill check."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import signal
import sys
import uuid
from prefill_compute_archive import archive_launcher, archive_sources, digest, load_archived_runtime, verify_archive, write_json
from prefill_compute_contract import configuration, require, timeout
from prefill_compute_inputs import ARTIFACT, CONFIGURATION, archive_inputs
from remote_prefill_client import RemoteControl, RemoteMemoryGate, collect_metadata, create_remote, prepare_controls, upload_new
from remote_prefill_paths import absolute_path, host_alias
from remote_prefill_supervision import supervise


def verified_remote(record, config, expected_files):
    require(record.get('artifact_aggregate_sha256') == ARTIFACT
            and record.get('bundle_manifest_sha256') == config['bundle_sha256']
            and record.get('bundle_file_sha256') == expected_files
            and record.get('rank_configuration_sha256') == config['rank_sha256'], 'Remote artifact/bundle/rank identity differs')
    require(record['model_metadata']['config.json']['sha256'] == CONFIGURATION, 'Remote configuration pin differs')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('release', 'runtime', 'output', 'input-origin', 'expected-inventory'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--host', type=host_alias, required=True)
    parser.add_argument('--remote-model-dir', required=True)
    parser.add_argument('--remote-run-root')
    parser.add_argument('--artifact-aggregate-sha256', required=True)
    parser.add_argument('--expected-native-sha256', required=True)
    parser.add_argument('--timeout-seconds', type=int, default=180)
    args = parser.parse_args(argv)
    timeout(args.timeout_seconds)
    absolute_path(args.remote_model_dir)
    if args.remote_run_root:
        absolute_path(args.remote_run_root)
    require(args.artifact_aggregate_sha256 == ARTIFACT
            and re.fullmatch('[0-9a-f]{64}', args.expected_native_sha256) is not None, 'Explicit frozen artifact/native pins required')
    runtime = args.runtime.resolve(strict=True)
    output = args.output.expanduser().resolve()
    require(not output.exists() and not output.is_relative_to(runtime.parents[2]), 'Output must be new and outside repository')
    output.mkdir(parents=True, mode=0o700)
    run_id, gate, control, rank, modules = uuid.uuid4().hex, RemoteMemoryGate(), None, None, None
    children, handlers = [], {}
    receipt = dict(kind='remote_qwen_layer_stage_prefill_launcher', schema_version=1, run_id=run_id,
                   passed=False, execution_host=args.host, native_execution_attempted=False, native_process_count=1,
                   physical_two_machine_execution=False, interprocess_model_transport=False, throughput_qualification=False,
                   independent_comparison_oracle_run=False, timeout_seconds=args.timeout_seconds,
                   artifact_aggregate_sha256=ARTIFACT, configuration_sha256=CONFIGURATION)
    try:
        # These are local build-provenance copies. No local model payload is read.
        launcher = archive_launcher(output)
        sources = archive_sources(runtime, output)
        modules = load_archived_runtime(output, run_id)
        inputs = archive_inputs(args.input_origin.resolve(strict=True), args.expected_inventory.resolve(strict=True), output)
        bundle_hash = modules['bundle'].snapshot(args.release.resolve(strict=True), output / 'bundle')
        require(digest(output / 'bundle/cluster-inference') == args.expected_native_sha256, 'Frozen native binary pin differs')
        verify_archive(modules, output, sources, bundle_hash, launcher)
        expected_files = {entry['path']: entry['sha256'] for entry in json.loads((output / 'bundle/bundle.json').read_text())['files']}
        layout = create_remote(modules['processes'], args.host, args.remote_model_dir, args.remote_run_root, run_id)
        receipt['remote_paths'] = layout
        local = output / 'native'
        local.mkdir(mode=0o700)
        rank_config = configuration(Path(layout['bundle']), bundle_hash, Path(layout['model']), inputs['prompt'], args.timeout_seconds)
        write_json(local / 'rank.json', rank_config)
        config = dict(layout, run_id=run_id, bundle_sha256=bundle_hash, binary_sha256=args.expected_native_sha256,
                      rank_sha256=digest(local / 'rank.json'), artifact_sha256=ARTIFACT, configuration_sha256=CONFIGURATION,
                      prompt_sha256=hashlib.sha256(json.dumps(inputs['prompt']).encode()).hexdigest())
        control_hash = prepare_controls(output, layout, config)
        upload_new(modules['processes'], args.host, output / 'controls', layout['controls'])
        control = RemoteControl(modules['processes'], args.host, layout, run_id, control_hash, output)
        receipt.update(control_manifest_sha256=control_hash, source_manifest_sha256=digest(output / 'source-manifest.json'),
                       source_file_count=len(sources['files']), launcher_files=launcher, bundle_manifest_sha256=bundle_hash,
                       rank_configuration_sha256=config['rank_sha256'], inputs=inputs)
        initial = control.call('initial', timeout=10)
        receipt['remote_initial_free_screen'] = initial
        require(initial.get('passed') is True and type(initial.get('actual_free_bytes')) is int
                and initial['actual_free_bytes'] >= 6 * 1024**3, 'Remote initial actual-free screen refused before bundle/model reads')
        upload_new(modules['processes'], args.host, output / 'bundle', layout['bundle'])
        upload_new(modules['processes'], args.host, local / 'rank.json', layout['native'] + '/rank.json')
        before = control.call('before')
        receipt['remote_before'] = before
        verified_remote(before, config, expected_files)
        gate.consume(before['memory'])
        require(before['posthash_preflight'].get('passed') is True, 'Remote posthash reclaimable/disk/descriptor screen refused')
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
        receipt['execution'] = supervise(rank, inputs['prompt'], args.timeout_seconds, start,
                                         modules['processes'].stop_processes, observe)
        after = control.call('after')
        receipt['remote_after'] = after
        verified_remote(after, config, expected_files)
        gate.consume(after['memory'])
        require(not after['memory']['remote_pid_inventory']['observed_processes'], 'Owned remote processes still observed after SSH completion')
        for name in ('config.json', 'manifest.json'):
            require(before['model_metadata'][name]['sha256'] == after['model_metadata'][name]['sha256'], 'Remote original model metadata changed')
        require(after['prompt_sha256'] == config['prompt_sha256'], 'Remote input bytes changed')
        receipt['retrieved_remote_metadata'] = collect_metadata(modules['processes'], args.host, layout, before, after, output)
        verify_archive(modules, output, sources, bundle_hash, launcher)
        require(digest(local / 'rank.json') == config['rank_sha256'], 'Local rank configuration changed')
        for entry in inputs['files']:
            require(digest(output / entry['path']) == entry['sha256'], 'Local retained input changed')
        require(digest(output / 'controls/control-manifest.json') == control_hash, 'Local controls manifest changed')
        modules['artifacts'].verify_files(output / 'controls', json.loads((output / 'controls/control-manifest.json').read_text())['files'])
        receipt['source_bundle_inputs_and_remote_model_unchanged_after_run'] = True
        receipt['passed'] = receipt['execution']['passed']
    except BaseException as error:
        receipt.update(passed=False, error=type(error).__name__ + ': ' + str(error))
    finally:
        if children and not receipt['passed']:
            try:
                modules['processes'].stop_processes([rank], children)
            except BaseException as error:
                receipt['final_cancellation_error'] = repr(error)
        receipt['remote_memory_samples'] = gate.samples
        receipt['observed_remote_supervisor_pids'] = sorted({row['pid'] for sample in gate.samples
            for row in sample.get('remote_pid_inventory', {}).get('observed_processes', []) if row['kind'] == 'supervisor'})
        receipt['observed_remote_native_pids'] = sorted({row['pid'] for sample in gate.samples
            for row in sample.get('remote_pid_inventory', {}).get('observed_processes', []) if row['kind'] == 'native'})
        receipt['remote_pid_observations_are_not_reaping_proof'] = True
        receipt['resource_policy'] = 'remote initial free>=6GiB before remote bundle staging/model hashing; remote posthash reclaimable>=8GiB; pressure<=2 and zero new reported swap from remote posthash baseline'
        receipt['local_model_payload_verified'] = False
        receipt['native_files'] = [dict(path=p.relative_to(output).as_posix(), sha256=digest(p), size_bytes=p.stat().st_size)
                                  for p in sorted(output.glob('native/*')) if p.is_file() and p.stat().st_size <= 64 * 1024**2]
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
        write_json(output / 'receipt.json', receipt)
    print(str(output / 'receipt.json'))
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
