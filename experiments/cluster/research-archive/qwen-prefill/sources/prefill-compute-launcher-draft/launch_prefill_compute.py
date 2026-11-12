#!/usr/bin/env python3
"""Root-run single-native-process uncaptured prefill correctness; no throughput claim."""
import argparse
import json
from pathlib import Path
import re
import shutil
import signal
import sys
import uuid
from prefill_compute_archive import archive_launcher,archive_sources,digest,load_archived_runtime,verify_archive,write_json
from prefill_compute_contract import configuration,timeout
from prefill_compute_inputs import ARTIFACT,CONFIGURATION,archive_inputs
from prefill_compute_memory import MemoryGate,initial_free_screen,resource_preflight
from prefill_compute_supervision import supervise


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('release','runtime','output','model-dir','input-origin','expected-inventory'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--artifact-aggregate-sha256',required=True)
    parser.add_argument('--expected-native-sha256',required=True)
    parser.add_argument('--timeout-seconds',type=int,default=180)
    args=parser.parse_args(argv);timeout(args.timeout_seconds)
    if args.artifact_aggregate_sha256!=ARTIFACT or re.fullmatch('[0-9a-f]{64}',args.expected_native_sha256)is None:
        raise ValueError('Explicit approved artifact and native binary pins required')
    model=args.model_dir.expanduser().resolve(strict=True);runtime=args.runtime.resolve(strict=True)
    output=args.output.expanduser().resolve();repository=runtime.parents[2]
    if output.exists() or output.is_relative_to(repository) or output.is_relative_to(model):
        raise ValueError('Output must be new and outside repository/model')
    output.mkdir(parents=True,mode=0o700);run_id=uuid.uuid4().hex;memory=None;old_handlers={}
    receipt=dict(kind='qwen_layer_stage_prefill_launcher',schema_version=1,run_id=run_id,passed=False,
        native_execution_attempted=False,native_process_count=1,physical_two_machine_execution=False,
        throughput_qualification=False,independent_comparison_oracle_run=False,
        artifact_aggregate_sha256=ARTIFACT,configuration_sha256=CONFIGURATION,timeout_seconds=args.timeout_seconds)
    try:
        # This initial screen deliberately precedes snapshots and full hashing.
        # Artifact page-cache reads can reduce free pages before native launch.
        screen=initial_free_screen();receipt['initial_free_screen']=screen
        if not screen['passed']:raise ValueError('Initial actual-free screen refused before snapshot/artifact hashing')
        launcher=archive_launcher(output);sources=archive_sources(runtime,output)
        modules=load_archived_runtime(output,run_id)
        inputs=archive_inputs(args.input_origin.resolve(strict=True),args.expected_inventory.resolve(strict=True),output)
        bundle_hash=modules['bundle'].snapshot(args.release.resolve(strict=True),output/'bundle')
        if digest(output/'bundle/cluster-inference')!=args.expected_native_sha256:raise ValueError('Frozen native binary differs from expected pin')
        verify_archive(modules,output,sources,bundle_hash,launcher)
        if digest(model/'config.json')!=CONFIGURATION:raise ValueError('Original model configuration differs')
        receipt['model_before_aggregate_sha256']=modules['artifacts'].verify_model(model,ARTIFACT)
        for name in ('config.json','manifest.json'):shutil.copyfile(model/name,output/('model-'+name))
        metadata={name:digest(output/('model-'+name))for name in ('config.json','manifest.json')}
        receipt['model_metadata_sha256']=metadata
        preflight=resource_preflight(output);receipt['posthash_preflight']=preflight
        if not preflight['passed']:raise ValueError('Post-hash reclaimable/disk/descriptor screen refused')
        memory=MemoryGate()
        directory=output/'native';directory.mkdir(mode=0o700)
        config=configuration(output/'bundle',bundle_hash,model,inputs['prompt'],args.timeout_seconds)
        write_json(directory/'rank.json',config)
        rank=dict(rank=0,host=None,directory=str(directory),local=str(directory),bundle=str(output/'bundle'))
        receipt.update(source_manifest_sha256=digest(output/'source-manifest.json'),source_file_count=len(sources['files']),
            launcher_files=launcher,bundle_manifest_sha256=bundle_hash,inputs=inputs,rank_configuration_sha256=digest(directory/'rank.json'))
        def interrupted(signum,_frame):raise SystemExit(128+signum)
        for signum in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT):old_handlers[signum]=signal.signal(signum,interrupted)
        receipt['native_execution_attempted']=True;write_json(output/'receipt.json',receipt)
        receipt['execution']=supervise(rank,inputs['prompt'],args.timeout_seconds,
            modules['processes'].start,modules['processes'].stop_processes,memory.observe)
        memory.observe();verify_archive(modules,output,sources,bundle_hash,launcher)
        if digest(directory/'rank.json')!=receipt['rank_configuration_sha256']:raise ValueError('Rank configuration changed')
        if (directory/'prompt.json').read_bytes()!=json.dumps(inputs['prompt']).encode():raise ValueError('Staged prompt bytes changed')
        for entry in inputs['files']:
            if digest(output/entry['path'])!=entry['sha256']:raise ValueError('Retained input changed')
        receipt['model_after_aggregate_sha256']=modules['artifacts'].verify_model(model,ARTIFACT)
        for name,expected in metadata.items():
            if digest(model/name)!=expected or digest(output/('model-'+name))!=expected:raise ValueError('Original/copied metadata changed')
        memory.observe()
        receipt['source_bundle_runtime_inputs_model_unchanged_after_run']=True
        receipt['passed']=receipt['execution']['passed']
    except BaseException as caught:receipt['error']=type(caught).__name__+': '+str(caught);receipt['passed']=False
    finally:
        if memory is not None:receipt['memory_samples']=memory.samples
        receipt['resource_policy']='initial free>=6GiB before snapshots/hash; posthash reclaimable>=8GiB; pressure<=2 and zero new reported swap from posthash baseline'
        receipt['native_files']=[dict(path=p.relative_to(output).as_posix(),sha256=digest(p),size_bytes=p.stat().st_size)
            for p in sorted(output.glob('native/*'))if p.is_file()and p.stat().st_size<=64*1024**2]
        for signum,handler in old_handlers.items():signal.signal(signum,handler)
        write_json(output/'receipt.json',receipt)
    print(str(output/'receipt.json'));return 0 if receipt['passed']else 1


if __name__=='__main__':sys.exit(main())
