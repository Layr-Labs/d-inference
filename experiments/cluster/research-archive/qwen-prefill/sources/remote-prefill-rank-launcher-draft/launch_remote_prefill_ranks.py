#!/usr/bin/env python3
"""Root-run two-rank prefill diagnostic on one remote loopback host."""
import argparse
import json
from pathlib import Path
import re
import signal
import sys
import uuid
from prefill_compute_archive import archive_launcher, archive_sources, digest, load_archived_runtime, verify_archive, write_json
from prefill_compute_inputs import ARTIFACT, CONFIGURATION, archive_inputs
from rank_prefill_client import RemoteControl, RemoteMemoryGate, collect_metadata, create_remote, prepare_controls, upload_new
from rank_prefill_contract import FLOW, policy, require, timeout
from rank_prefill_paths import absolute_path, host_alias
from rank_prefill_staging import prepare_ranks, verify_local_rank_inputs, verify_remote
from rank_prefill_supervision import supervise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('release', 'runtime', 'output', 'input-origin', 'expected-inventory'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--host', type=host_alias, required=True)
    parser.add_argument('--remote-model-dir', required=True)
    parser.add_argument('--remote-run-root')
    parser.add_argument('--artifact-aggregate-sha256', required=True)
    parser.add_argument('--expected-native-sha256', required=True)
    parser.add_argument('--stage-prefill-policy', type=policy, required=True)
    parser.add_argument('--timeout-seconds', type=int, default=180)
    args = parser.parse_args(argv)
    timeout(args.timeout_seconds); absolute_path(args.remote_model_dir)
    if args.remote_run_root: absolute_path(args.remote_run_root)
    require(args.artifact_aggregate_sha256 == ARTIFACT
            and re.fullmatch('[0-9a-f]{64}', args.expected_native_sha256) is not None, 'Explicit frozen artifact/native pins required')
    runtime, output = args.runtime.resolve(strict=True), args.output.expanduser().resolve()
    require(not output.exists() and not output.is_relative_to(runtime.parents[2]), 'Output must be new and outside repository')
    output.mkdir(parents=True, mode=0o700)
    epoch, gate, modules, ranks = uuid.uuid4().hex, RemoteMemoryGate(), None, []
    children, handlers = [], {}
    receipt = dict(kind='remote_qwen_layer_stage_prefill_rank_launcher', schema_version=1,
        epoch=epoch, execution_host=args.host, passed=False, native_execution_attempted=False,
        native_rank_count=2, transport='loopback-test', backend='ring', flow=FLOW, envelope_version=3,
        stage_prefill_policy=args.stage_prefill_policy, stage_logits_dtype='bfloat16',
        physical_two_machine_execution=False, throughput_qualification=False, independent_execution_oracle_run=False,
        timeout_seconds=args.timeout_seconds, artifact_aggregate_sha256=ARTIFACT, configuration_sha256=CONFIGURATION,
        model_payload_copies_created=False, final_cleanup_errors=[])
    try:
        launcher = archive_launcher(output); sources = archive_sources(runtime, output)
        modules = load_archived_runtime(output, epoch)
        inputs = archive_inputs(args.input_origin.resolve(strict=True), args.expected_inventory.resolve(strict=True), output)
        bundle_hash = modules['bundle'].snapshot(args.release.resolve(strict=True), output / 'bundle')
        require(digest(output / 'bundle/cluster-inference') == args.expected_native_sha256, 'Frozen native binary pin differs')
        verify_archive(modules, output, sources, bundle_hash, launcher)
        expected_files = {entry['path']: entry['sha256'] for entry in json.loads((output / 'bundle/bundle.json').read_text())['files']}
        layout, allocation = create_remote(modules['processes'], args.host, args.remote_model_dir, args.remote_run_root, epoch)
        receipt.update(remote_paths=layout, remote_port_reservation=allocation, hostfile=allocation['hostfile'])
        ranks, config = prepare_ranks(output, layout, args.host, bundle_hash, args.expected_native_sha256,
            inputs['prompt'], allocation['hostfile'], epoch, args.stage_prefill_policy, args.timeout_seconds)
        control_hash = prepare_controls(output, layout, config)
        upload_new(modules['processes'], args.host, output / 'controls', layout['controls'])
        control = RemoteControl(modules['processes'], args.host, layout, epoch, control_hash, output)
        receipt.update(control_manifest_sha256=control_hash, source_manifest_sha256=digest(output / 'source-manifest.json'),
            source_file_count=len(sources['files']), launcher_files=launcher, bundle_manifest_sha256=bundle_hash,
            rank_configuration_sha256=[rank['rank_sha256'] for rank in config['ranks']], inputs=inputs)
        initial = control.call('initial', timeout=10); receipt['remote_initial_free_screen'] = initial
        require(initial.get('passed') is True and type(initial.get('actual_free_bytes')) is int
                and initial['actual_free_bytes'] >= 6 * 1024**3, 'Remote initial actual-free screen refused before bundle/model reads')
        upload_new(modules['processes'], args.host, output / 'bundle', layout['bundle'])
        for rank in ranks:
            upload_new(modules['processes'], args.host, Path(rank['local']) / 'rank.json', rank['directory'] + '/rank.json')
        before = control.call('before'); receipt['remote_before'] = before
        verify_remote(before, config, expected_files, 'before'); gate.consume(before['memory'])
        require(before['posthash_preflight'].get('passed') is True, 'Remote posthash resource screen refused')
        def interrupted(signum, _frame): raise SystemExit(128 + signum)
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT): handlers[signum] = signal.signal(signum, interrupted)
        def start(rank):
            child = modules['processes'].start(rank); children.append(child); return child
        def observe(seconds): gate.consume(control.call('observe', timeout=seconds))
        receipt['native_execution_attempted'] = True; write_json(output / 'receipt.json', receipt)
        receipt['cohort'] = supervise(ranks, inputs['prompt'], epoch, args.stage_prefill_policy, args.timeout_seconds,
            start, modules['processes'].stop_processes, observe)
        after = control.call('after'); receipt['remote_after'] = after
        verify_remote(after, config, expected_files, 'after'); gate.consume(after['memory'])
        require(not after['memory']['remote_pid_inventory']['observed_processes'], 'Owned remote processes still observed after SSH completion')
        for name in ('config.json', 'manifest.json'):
            require(before['model_metadata'][name]['sha256'] == after['model_metadata'][name]['sha256'], 'Remote model metadata changed')
        receipt['retrieved_remote_metadata'] = collect_metadata(modules['processes'], args.host, layout, before, after, output)
        verify_archive(modules, output, sources, bundle_hash, launcher)
        verify_local_rank_inputs(output, config, inputs)
        require(digest(output / 'controls/control-manifest.json') == control_hash, 'Local control manifest changed')
        modules['artifacts'].verify_files(output / 'controls', json.loads((output / 'controls/control-manifest.json').read_text())['files'])
        receipt['source_bundle_inputs_and_remote_model_unchanged_after_run'] = True
        receipt['passed'] = receipt['cohort']['passed']
    except BaseException as error:
        # An outer verification error remains separate from any existing cohort
        # primary failure and from failures in final cancellation.
        receipt.update(passed=False, error=type(error).__name__ + ': ' + str(error))
    finally:
        if children and not receipt['passed']:
            try:
                modules['processes'].stop_processes(ranks, children)
            except BaseException as error:
                receipt['final_cleanup_errors'].append(type(error).__name__ + ': ' + str(error))
        receipt['remote_memory_samples'] = gate.samples
        receipt['observed_remote_processes'] = [dict(rank=i,
            native_pids=sorted({row['pid'] for sample in gate.samples for row in sample.get('remote_pid_inventory', {}).get('observed_processes', [])
                                if row['kind'] == 'native' and row['rank'] == i}),
            supervisor_pids=sorted({row['pid'] for sample in gate.samples for row in sample.get('remote_pid_inventory', {}).get('observed_processes', [])
                                    if row['kind'] == 'supervisor' and row['rank'] == i})) for i in range(2)]
        receipt['remote_pid_observations_are_not_reaping_proof'] = True
        receipt['resource_policy'] = 'remote initial free>=6GiB before bundle/model hashing; remote posthash reclaimable>=8GiB; pressure<=2 and zero new reported swap'
        receipt['local_model_payload_verified'] = False
        receipt['rank_files'] = [dict(path=path.relative_to(output).as_posix(), sha256=digest(path), size_bytes=path.stat().st_size)
            for path in sorted(output.glob('rank-*/*')) if path.is_file() and path.stat().st_size <= 64 * 1024**2]
        for signum, handler in handlers.items(): signal.signal(signum, handler)
        write_json(output / 'receipt.json', receipt)
    print(str(output / 'receipt.json')); return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
