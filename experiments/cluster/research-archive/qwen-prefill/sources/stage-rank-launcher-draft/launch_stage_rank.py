#!/usr/bin/env python3
"""Draft root-run only: verified real9B two-process sequential stage correctness."""

import argparse
import json
from pathlib import Path
import shutil
import signal
import sys
import uuid

from stage_rank_archive import archive_launcher,archive_sources,digest,load_archived_runtime,verify_archive,write_json
from stage_rank_contract import rank_configuration,require_timeout
from stage_rank_inputs import ARTIFACT,CONFIGURATION,archive_inputs
from stage_rank_memory import MemoryGate,resource_preflight
from stage_rank_supervision import supervise


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('release','runtime','output','model-dir','input-origin','expected-inventory'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--artifact-aggregate-sha256',required=True)
    parser.add_argument('--expected-native-sha256',required=True)
    parser.add_argument('--timeout-seconds',type=int,default=180)
    args=parser.parse_args();require_timeout(args.timeout_seconds)
    if args.artifact_aggregate_sha256!=ARTIFACT: raise ValueError('Only the approved dense9B artifact is admitted')
    model=args.model_dir.expanduser().resolve(strict=True);runtime=args.runtime.resolve(strict=True)
    output=args.output.expanduser().resolve();repository=runtime.parents[2]
    if output.exists() or output.is_relative_to(repository) or output.is_relative_to(model):
        raise ValueError('Output must be new and outside repository/model')
    output.mkdir(parents=True,mode=0o700)
    epoch=uuid.uuid4().hex;memory=None;old_handlers={}
    receipt=dict(kind='qwen_layer_stage_rank_launcher',schema_version=1,epoch=epoch,passed=False,
        native_execution_attempted=False,physical_two_machine_execution=False,throughput_qualification=False,
        baseline_comparison_performed_by_launcher=False,artifact_aggregate_sha256=ARTIFACT,
        configuration_sha256=CONFIGURATION,model_directory=str(model),timeout_seconds=args.timeout_seconds)
    try:
        launcher=archive_launcher(output);sources=archive_sources(runtime,output)
        modules=load_archived_runtime(output,epoch)
        inputs=archive_inputs(args.input_origin.resolve(strict=True),args.expected_inventory.resolve(strict=True),output)
        bundle_hash=modules['bundle'].snapshot(args.release.resolve(strict=True),output/'bundle')
        if digest(output/'bundle/cluster-inference')!=args.expected_native_sha256:
            raise ValueError('Frozen native executable differs from root pin')
        verify_archive(modules,output,sources,bundle_hash,launcher)
        if digest(model/'config.json')!=CONFIGURATION: raise ValueError('Original model configuration differs')
        receipt['model_before_aggregate_sha256']=modules['artifacts'].verify_model(model,ARTIFACT)
        for name in ('config.json','manifest.json'):
            shutil.copyfile(model/name,output/('model-'+name))
        receipt['model_metadata_sha256']={name:digest(output/('model-'+name)) for name in ('config.json','manifest.json')}
        preflight=resource_preflight(output);receipt['preflight']=preflight
        if not preflight['passed']: raise ValueError('Stage pair resource preflight refused')
        memory=MemoryGate();hosts=modules['configuration'].loopback_addresses();ranks=[]
        for i in range(2):
            directory=output/f'rank-{i}';directory.mkdir(mode=0o700)
            config=rank_configuration(output/'bundle',bundle_hash,i,epoch,args.timeout_seconds,hosts,model,
                                      inputs['prompt'],inputs['teacher'])
            write_json(directory/'rank.json',config)
            ranks.append(dict(rank=i,host=None,directory=str(directory),local=str(directory),
                              bundle=str(output/'bundle'),inputs=inputs))
        receipt.update(source_manifest_sha256=digest(output/'source-manifest.json'),source_file_count=len(sources['files']),
            launcher_files=launcher,bundle_manifest_sha256=bundle_hash,inputs=inputs,hostfile=hosts,
            rank_configuration_sha256=[digest(output/f'rank-{i}/rank.json') for i in range(2)])
        def interrupted(signum,_frame): raise SystemExit(128+signum)
        for signum in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT): old_handlers[signum]=signal.signal(signum,interrupted)
        receipt['native_execution_attempted']=True;write_json(output/'receipt.json',receipt)
        result=supervise(ranks,epoch,args.timeout_seconds,modules['processes'].start,modules['processes'].stop_processes,memory.observe)
        receipt['cohort']=result
        memory.observe()
        verify_archive(modules,output,sources,bundle_hash,launcher)
        for i,expected in enumerate(receipt['rank_configuration_sha256']):
            if digest(output/f'rank-{i}/rank.json')!=expected: raise ValueError('Rank configuration changed')
            for name,values in [('hosts.json',hosts),('prompt.json',inputs['prompt']),('teacher.json',inputs['teacher'])]:
                if (output/f'rank-{i}'/name).read_bytes()!=json.dumps(values).encode():
                    raise ValueError('Staged rank input bytes changed')
        for entry in inputs['files']:
            if digest(output/entry['path'])!=entry['sha256']: raise ValueError('Retained input changed')
        receipt['model_after_aggregate_sha256']=modules['artifacts'].verify_model(model,ARTIFACT)
        for name,expected in receipt['model_metadata_sha256'].items():
            if digest(model/name)!=expected or digest(output/('model-'+name))!=expected:
                raise ValueError('Original/copied model metadata changed')
        receipt['source_bundle_runtime_inputs_model_unchanged_after_run']=True
        receipt['passed']=result['passed']
    except BaseException as caught:
        receipt['error']=type(caught).__name__+': '+str(caught);receipt['passed']=False
    finally:
        if memory is not None: receipt['memory_samples']=memory.samples
        receipt['memory_gate']='preflight >=8GiB estimated reclaimable; pressure<=2; zero increase in reported swap'
        receipt['rank_files']=[]
        for path in sorted(output.glob('rank-*/*')):
            if path.is_file() and path.stat().st_size<=64*1024**2:
                receipt['rank_files'].append(dict(path=path.relative_to(output).as_posix(),sha256=digest(path),size_bytes=path.stat().st_size))
        for signum,handler in old_handlers.items(): signal.signal(signum,handler)
        write_json(output/'receipt.json',receipt)
    print(str(output/'receipt.json'))
    return 0 if receipt['passed'] else 1


if __name__=='__main__': sys.exit(main())
