"""Bounded local checks, explicitly separate from inference benchmarks/serving."""
import argparse
from pathlib import Path
import json
import signal
import uuid
from . import archive,baseline,configuration,inputs,p2p,prefill,ranks,supervision,long_cli,stage_ranges
from .prefill_resources import initial_free_screen
from .common import integer,require,sha
from .resources import MemoryGate,resource_preflight


class StageCutArgument(argparse.Action):
    def __call__(self, parser, namespace, value, option_string=None):
        if getattr(namespace, self.dest, None) is not None:parser.error('--stage-cut may be specified only once')
        setattr(namespace, self.dest, value)


def parser():
    root=argparse.ArgumentParser(description=__doc__);commands=root.add_subparsers(dest='command',required=True)
    for name in ('p2p','ranks','prefill-ranks'):
        command=commands.add_parser(name)
        for option in ('release','runtime','output'):command.add_argument('--'+option,type=Path,required=True)
        command.add_argument('--expected-binary-sha256',required=True)
        command.add_argument('--timeout-seconds',type=int,default=60 if name=='p2p' else 180)
        if name!='p2p':
            command.add_argument('--model-dir',type=Path,required=True)
            command.add_argument('--artifact-aggregate-sha256',required=True)
            command.add_argument('--tokens-file',type=Path,required=True)
            command.add_argument('--tokens-sha256')
            if name=='ranks':
                command.add_argument('--stage-cut',type=int,action=StageCutArgument)
                command.add_argument('--teacher-tokens-file',type=Path)
                command.add_argument('--teacher-tokens-sha256')
                command.add_argument('--chunk-size',type=int,default=32)
            else:
                command.set_defaults(teacher_tokens_file=None,teacher_tokens_sha256=None,chunk_size=32)
                command.add_argument('--stage-prefill-policy',choices=prefill.POLICIES,required=True)
                command.add_argument('--stage-logits-dtype',choices=('float16','bfloat16','float32'),required=True)
                command.add_argument('--baseline-evidence-sha256',required=True)
            command.add_argument('--minimum-reclaimable-gib',type=int,default=8)
            command.add_argument('--baseline-jsonl',type=Path,required=name=='prefill-ranks')
            command.add_argument('--baseline-sha256',required=name=='prefill-ranks')
    long_cli.add_parsers(commands, StageCutArgument)
    return root


def main(argv=None):
    args=parser().parse_args(argv)
    if args.command in long_cli.COMMANDS:return long_cli.run(args)
    stage_ranges.option(args.command,getattr(args,'stage_cut',None))
    sha(args.expected_binary_sha256)
    integer(args.timeout_seconds,1,60 if args.command=='p2p' else 180)
    runtime=args.runtime.resolve(strict=True);repository=runtime.parents[2];output=args.output.resolve()
    require(not output.exists() and not output.is_relative_to(repository),'Output must be new and outside repository')
    if args.command!='p2p':require(not output.is_relative_to(args.model_dir.resolve()),'Output must be outside model')
    if args.command=='prefill-ranks':
        sha(args.baseline_sha256);sha(args.baseline_evidence_sha256)
    output.mkdir(mode=0o700,parents=True);epoch=uuid.uuid4().hex;memory=None;old_handlers={};context=None;baseline_started=False
    receipt=dict(kind='stage_checks_run',schema_version=1,mode=args.command,epoch=epoch,passed=False,
        native_execution_attempted=False,throughput_qualification=False,physical_two_machine_execution=False,
        baseline_audit=dict(performed=False))
    try:
        if args.command=='prefill-ranks':
            initial=initial_free_screen();receipt['initial_free_screen']=initial
            require(initial['passed'],'Initial actual-free screen refused before artifact hashing')
            memory=MemoryGate()
        launcher=archive.archive_launcher(output);sources=archive.archive_sources(runtime,output)
        modules=archive.load_archived_runtime(output,epoch)
        bundle_hash=modules['bundle'].snapshot(args.release.resolve(strict=True),output/'bundle')
        require(archive.digest(output/'bundle/cluster-inference')==args.expected_binary_sha256,'Frozen binary differs from expected pin')
        archive.verify_archive(modules,output,sources,bundle_hash,launcher)
        context=inputs.prepare(args,output,epoch,modules['artifacts'])
        archive.write_json(output/'context.json',context)
        if args.command!='p2p':
            preflight=resource_preflight(output,args.minimum_reclaimable_gib);receipt['preflight']=preflight
            require(preflight['passed'],'Resource preflight refused; minimum screen is not a memory guarantee')
        if memory is None:memory=MemoryGate()
        else:memory.observe()
        hosts=modules['configuration'].loopback_addresses();cohort=[];configs=[]
        for rank in (0,1):
            directory=output/f'rank-{rank}';directory.mkdir(mode=0o700)
            config=configuration.build(rank,epoch,context,output/'bundle',bundle_hash,hosts,args.timeout_seconds)
            archive.write_json(directory/'rank.json',config);configs.append(config)
            cohort.append(dict(rank=rank,host=None,directory=str(directory),local=str(directory),bundle=str(output/'bundle')))
        files={path.relative_to(output).as_posix():archive.digest(path) for path in output.rglob('*') if path.is_file() and 'bundle' not in path.relative_to(output).parts and 'source' not in path.relative_to(output).parts}
        receipt.update(source_manifest_sha256=archive.digest(output/'source-manifest.json'),bundle_manifest_sha256=bundle_hash,
                       context_sha256=archive.digest(output/'context.json'),retained_metadata_sha256=files,timeout_seconds=args.timeout_seconds)
        def interrupted(signum,_frame):raise SystemExit(128+signum)
        for signum in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP):old_handlers[signum]=signal.signal(signum,interrupted)
        receipt['native_execution_attempted']=True;archive.write_json(output/'receipt.json',receipt)
        namespace={'p2p':p2p,'ranks':ranks,'prefill-ranks':prefill}[args.command]
        result,reports=supervision.run(cohort,epoch,context,namespace,args.timeout_seconds,
            modules['processes'].start,modules['processes'].stop_processes,memory.observe)
        receipt['cohort']=result;memory.observe()
        archive.verify_archive(modules,output,sources,bundle_hash,launcher);inputs.verify(context,output,modules['artifacts'])
        for path,digest in files.items():require(archive.digest(output/path)==digest,'Retained metadata changed: '+path)
        if result['passed']:
            for rank,config in enumerate(configs):
                for name,value in config['input_files'].items():
                    require((output/f'rank-{rank}'/name).read_bytes()==json.dumps(value).encode(),'Staged rank input bytes changed')
            if args.command=='ranks' and 'baseline_sha256'in context:
                baseline_started=True
                receipt['baseline_audit']=baseline.compare(output/'inputs/baseline.jsonl',reports,context)
        if args.command=='prefill-ranks':
            receipt['baseline_admission']=context['baseline_admission']
            receipt['independent_numerical_action_timing_audit']=dict(performed=False)
        receipt['passed']=result['passed'];receipt['frozen_inputs_artifact_bundle_source_rechecked']=True
    except BaseException as caught:
        receipt['error']=type(caught).__name__+': '+str(caught);receipt['passed']=False
        if baseline_started:
            receipt['baseline_audit']=dict(performed=True,passed=False,error=receipt['error'])
    finally:
        if memory is not None:receipt['memory_samples']=memory.samples
        receipt['rank_files']=[dict(path=path.relative_to(output).as_posix(),sha256=archive.digest(path),size_bytes=path.stat().st_size)
            for path in sorted(output.glob('rank-*/*')) if path.is_file() and path.stat().st_size<=64*1024**2]
        for signum,handler in old_handlers.items():signal.signal(signum,handler)
        archive.write_json(output/'receipt.json',receipt)
    print(str(output/'receipt.json'));return 0 if receipt['passed'] else 1
