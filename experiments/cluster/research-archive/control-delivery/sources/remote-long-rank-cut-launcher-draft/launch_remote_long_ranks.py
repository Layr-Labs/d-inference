#!/usr/bin/env python3
"""Root-run registered9B 8K cut12 v4 ranks requesting separate phase and selected-owner sidecars."""
import argparse
import json
from pathlib import Path
import signal
import sys
import uuid
from prefill_compute_archive import archive_launcher, archive_sources, digest, load_archived_runtime, verify_archive, write_json
from long_reference_inputs import ARTIFACT, CONFIGURATION, archive_inputs, is_sha256, require
from long_rank_artifacts import rank_file_receipts, verify_local
from long_rank_client import RemoteControl, RemoteMemoryGate, collect_metadata, create_remote, prepare_controls, upload_new
from long_rank_configuration import NATIVE_TIMEOUT_SECONDS, policy, timeout
from long_rank_identity import FLOW
from long_rank_paths import absolute_path, host_alias
from long_rank_staging import prepare_ranks, verify_remote
from long_rank_supervision import supervise
from long_pair_cut import selection_receipt
from long_rank_warning import source_warning


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('release','runtime','output','prompt-file','prompt-origin-file'):
        parser.add_argument('--' + name,type=Path,required=True)
    for name in ('long-prompt-sha256','prompt-origin-sha256','artifact-aggregate-sha256','expected-native-sha256'):
        parser.add_argument('--' + name,required=True)
    parser.add_argument('--host',type=host_alias,required=True)
    parser.add_argument('--remote-model-dir',required=True)
    parser.add_argument('--remote-run-root')
    parser.add_argument('--stage-prefill-policy',type=policy,required=True)
    parser.add_argument('--stage-logits-dtype',choices=['bfloat16'],required=True)
    parser.add_argument('--parent-timeout-seconds',type=int,default=330)
    args = parser.parse_args(argv)
    timeout(args.parent_timeout_seconds); absolute_path(args.remote_model_dir)
    if args.remote_run_root: absolute_path(args.remote_run_root)
    require(args.artifact_aggregate_sha256 == ARTIFACT and is_sha256(args.expected_native_sha256), 'Explicit registered artifact/native pins required')
    runtime, output = args.runtime.resolve(strict=True), args.output.expanduser().resolve()
    require(not output.exists() and not output.is_relative_to(runtime.parents[2]), 'Output must be new and outside repository')
    output.mkdir(parents=True,mode=0o700)
    epoch, gate, modules, ranks = uuid.uuid4().hex, RemoteMemoryGate(), None, []
    children, handlers = [], {}
    receipt = dict(kind='remote_qwen_long_prefill_rank_cut_owner_launcher',schema_version=1,run_id=epoch,epoch=epoch,
        execution_host=args.host,passed=False,native_execution_attempted=False,native_rank_count=2,
        transport='loopback-test',backend='ring',flow=FLOW,envelope_version=4,
        stage_prefill_policy=args.stage_prefill_policy,stage_logits_dtype=args.stage_logits_dtype,
        physical_two_machine_execution=False,throughput_qualification=False,independent_execution_oracle_run=False,
        full_reference_forward_requested=False,stage_model_forward_requested=True,timing_requested=True,timing_diagnostic_only=True,
        phase_timing_requested=True,owner_timing_requested=True,selected_layer_plan=selection_receipt(),
        native_timeout_seconds=NATIVE_TIMEOUT_SECONDS,parent_timeout_seconds=args.parent_timeout_seconds,
        expected_native_sha256=args.expected_native_sha256,artifact_aggregate_sha256=ARTIFACT,configuration_sha256=CONFIGURATION,
        model_payload_copies_created=False,primary_failure=None,cleanup_errors=[],post_run_errors=[])
    try:
        launcher = archive_launcher(output); sources = archive_sources(runtime,output)
        modules = load_archived_runtime(output,epoch)
        inputs = archive_inputs(args.prompt_file,args.long_prompt_sha256,args.prompt_origin_file,args.prompt_origin_sha256,output)
        receipt['inputs'] = inputs
        warning = source_warning(output); receipt['stderr_contract'] = warning
        bundle_hash = modules['bundle'].snapshot(args.release.resolve(strict=True),output / 'bundle')
        require(digest(output / 'bundle/cluster-inference') == args.expected_native_sha256, 'Frozen native binary pin differs')
        verify_archive(modules,output,sources,bundle_hash,launcher)
        expected_files = {row['path']:row['sha256'] for row in json.loads((output / 'bundle/bundle.json').read_text())['files']}
        layout, allocation = create_remote(modules['processes'],args.host,args.remote_model_dir,args.remote_run_root,epoch)
        receipt.update(remote_paths=layout,remote_port_reservation=allocation,hostfile=allocation['hostfile'])
        ranks, config = prepare_ranks(output,layout,args.host,bundle_hash,args.expected_native_sha256,
            inputs,allocation['hostfile'],epoch,args.stage_prefill_policy)
        control_hash = prepare_controls(output,layout,config)
        upload_new(modules['processes'],args.host,output / 'controls',layout['controls'])
        control = RemoteControl(modules['processes'],args.host,layout,epoch,control_hash,output)
        receipt.update(control_manifest_sha256=control_hash,source_manifest_sha256=digest(output / 'source-manifest.json'),
            source_file_count=len(sources['files']),launcher_files=launcher,bundle_manifest_sha256=bundle_hash,
            rank_configuration_sha256=[row['rank_sha256'] for row in config['ranks']])
        initial = control.call('initial',timeout=10); receipt['remote_initial_free_screen'] = initial
        require(initial.get('passed') is True and type(initial.get('actual_free_bytes')) is int
            and initial['actual_free_bytes'] >= 6 * 1024**3, 'Initial actual-free screen refused before remote bundle/model reads')
        upload_new(modules['processes'],args.host,output / 'bundle',layout['bundle'])
        for rank in ranks:
            for name in ('rank.json','prompt.json','hosts.json'):
                upload_new(modules['processes'],args.host,Path(rank['local']) / name,rank['directory'] + '/' + name)
        before = control.call('before'); receipt['remote_before'] = before
        verify_remote(before,config,expected_files); gate.consume(before['memory'])
        require(before['posthash_preflight'].get('passed') is True, 'Post-hash reclaimable/disk/descriptor screen refused')
        def interrupted(signum,_frame): raise SystemExit(128 + signum)
        for signum in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT): handlers[signum] = signal.signal(signum,interrupted)
        def start(rank):
            child = modules['processes'].start(rank); children.append(child); return child
        def observe(seconds): gate.consume(control.call('observe',timeout=seconds))
        receipt['native_execution_attempted'] = True; write_json(output / 'receipt.json',receipt)
        receipt['cohort'] = supervise(ranks,inputs,epoch,args.stage_prefill_policy,args.parent_timeout_seconds,
            start,modules['processes'].stop_processes,observe)
        cohort = receipt['cohort']; receipt['cleanup_errors'].extend(cohort['cleanup_errors'])
        if not cohort['passed']:
            receipt['primary_failure'] = dict(operation='native_cohort',reason=cohort['cancellation_reason'],error=cohort['error'])
        after = control.call('after'); receipt['remote_after'] = after
        verify_remote(after,config,expected_files); gate.consume(after['memory'])
        require(not after['memory']['remote_pid_inventory']['observed_processes'], 'Owned remote processes remain after SSH completion')
        for name in ('config.json','manifest.json'):
            require(before['model_metadata'][name]['sha256'] == after['model_metadata'][name]['sha256'], 'Remote original model metadata changed')
        receipt['retrieved_remote_metadata'] = collect_metadata(modules['processes'],args.host,layout,before,after,output)
        verify_local(modules,output,sources,bundle_hash,launcher,inputs,config,control_hash,args.stage_prefill_policy,warning)
        receipt['source_bundle_raw_inputs_and_remote_model_unchanged_after_run'] = True
        receipt['passed'] = cohort['passed']
    except BaseException as error:
        receipt['passed'] = False
        failure = dict(operation='launcher',error=type(error).__name__ + ': ' + str(error))
        if receipt['primary_failure'] is None: receipt['primary_failure'] = failure
        else: receipt['post_run_errors'].append(failure)
    finally:
        if children and not receipt['passed']:
            try: modules['processes'].stop_processes(ranks,children)
            except BaseException as error: receipt['cleanup_errors'].append(dict(operation='final_stop_owned_cohort',error=repr(error)))
        receipt['remote_memory_samples'] = gate.samples
        receipt['observed_remote_processes'] = [dict(rank=i,
            native_pids=sorted({row['pid'] for sample in gate.samples for row in sample.get('remote_pid_inventory',{}).get('observed_processes',[])
                               if row['kind'] == 'native' and row['rank'] == i}),
            supervisor_pids=sorted({row['pid'] for sample in gate.samples for row in sample.get('remote_pid_inventory',{}).get('observed_processes',[])
                                   if row['kind'] == 'supervisor' and row['rank'] == i})) for i in range(2)]
        receipt['remote_pid_observations_are_not_reaping_proof'] = True
        receipt['local_model_payload_verified'] = False
        receipt['resource_policy'] = 'remote initial actual free>=6GiB before bundle/model reads; posthash reclaimable>=8GiB; pressure<=2; zero reported swap; native300s and parent<=330s'
        try: receipt['rank_files'] = rank_file_receipts(output)
        except BaseException as error:
            receipt['passed'] = False
            failure = dict(operation='archive_rank_outputs',error=type(error).__name__ + ': ' + str(error))
            if receipt['primary_failure'] is None: receipt['primary_failure'] = failure
            else: receipt['post_run_errors'].append(failure)
        for signum, handler in handlers.items(): signal.signal(signum,handler)
        write_json(output / 'receipt.json',receipt)
    print(str(output / 'receipt.json')); return 0 if receipt['passed'] else 1


if __name__ == '__main__': sys.exit(main())
