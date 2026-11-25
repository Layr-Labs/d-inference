#!/usr/bin/env python3
"""Run the unchanged bounded driver from an immutable, portable staged package.

Only source/bundle/input/model locations are adapted. Default workload remains
six real one-host loopback correctness runs; no JACCL, build or Git checkout use.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import platform
import shutil
import signal
import sys

sys.dont_write_bytecode=True
from qwen9_staged_package import require,sha,read,write,contained,verify_package


def import_driver(package):
    sys.path.insert(0,str(package/'drivers'))
    spec=importlib.util.spec_from_file_location('frozen_qwen9_driver',package/'drivers/validate-qwen9-local-tp.py')
    driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(driver)
    return driver


def configure(driver,package,model,manifest):
    # These are location/archival hooks only. The native arithmetic, admission,
    # generated workload, timers, memory gates and cleanup functions are unchanged.
    driver.REPO=package
    driver.CLUSTER=package/'source/experiments/cluster'
    driver.RELEASE=package/'bundle'
    driver.MODEL=model
    driver.INPUT=package/'input'
    entries=read(package/'source-manifest.json')
    require(sha(package/'source-manifest.json')==manifest['origin']['source_manifest_sha256'],'Source manifest identity differs')

    def verify_sources(output,expected):
        require(expected==entries,'Source inventory changed')
        for entry in entries:
            path=entry['path']
            require(sha(contained(package/'source',path))==entry['sha256'],'Staged source changed: '+path)
            require(sha(contained(output/'source',path))==entry['sha256'],'Run source changed: '+path)

    def snapshot_sources(output):
        shutil.copytree(package/'source',output/'source')
        shutil.copyfile(package/'source-manifest.json',output/'source-manifest.json')
        verify_sources(output,entries)
        return entries,manifest['origin']['dependencies']

    driver.previous.snapshot_sources=snapshot_sources
    driver.previous.verify_sources=verify_sources
    return entries


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package',required=True,type=Path)
    parser.add_argument('--manifest-sha256',required=True)
    parser.add_argument('--model-dir',required=True,type=Path)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--plans',choices=('all','full'),default='all')
    parser.add_argument('--prepare-only',action='store_true')
    parser.add_argument('--check-only',action='store_true',help='Read-only package/metadata/spec/resource checks; no output/native execution')
    args=parser.parse_args()
    require(sys.version_info>=(3,10),'Python3.10+ required; use the inspected Python3.12 executable')
    require(platform.machine()=='arm64' and sys.platform=='darwin','Native bundle requires Apple Silicon macOS')
    package=args.package.resolve(strict=True);model=args.model_dir.resolve(strict=True)
    manifest=verify_package(package,args.manifest_sha256)
    require(Path(__file__).resolve()==package/'drivers/run-qwen9-staged-local-tp.py','Run the manifest-bound staged wrapper')
    driver=import_driver(package)
    require(manifest['pins']['aggregate_sha256']==driver.AGGREGATE and manifest['pins']['config_sha256']==driver.CONFIG,'Model pins differ')
    require(sha(model/'config.json')==driver.CONFIG and read(model/'manifest.json')['aggregate_sha256']==driver.AGGREGATE,'Peer model metadata differs')
    configure(driver,package,model,manifest)
    # Full artifact hashes are checked by the unchanged driver and rank workers
    # before any native work. This optional check-only pass reads small metadata.
    sys.path.insert(0,str(package/'source/experiments/cluster'))
    from runtime.configuration import validate
    from qwen9_local_tp_support import preflight,process_table
    partitions=('solo','ffn','full') if args.plans=='all' else ('solo','full')
    specs=driver.make_specs(read(package/'input/prompt-96.json'),partitions,validate)
    probes=[p for p in process_table().values() if os.path.basename(p['command'].split()[0])=='cluster-inference'
            or 'rank_worker.py' in p['command']]
    require(not probes,'An existing native probe/supervisor is active; refusing concurrent GPU work')
    context=dict(schema_version=1,package_manifest_sha256=args.manifest_sha256,
        wrapper_sha256=sha(Path(__file__)),origin=manifest['origin'],model_directory=str(model),
        selected_plans=args.plans,planned_logical_runs=len(specs),python_version=sys.version,
        python_executable=sys.executable,python_executable_sha256=sha(Path(sys.executable).resolve()),
        platform=platform.platform(),architecture=platform.machine(),git_checkout_used=False,
        remote_transport='one-host loopback-test; no SSH transport between ranks',
        preflight=preflight('ffn' if 'ffn' in partitions else 'full',package.parent),
        full_artifact_payload_verified_in_check_only=False)
    if args.check_only:
        require(args.output is None and not args.prepare_only,'check-only does not accept output or prepare-only')
        print(__import__('json').dumps(context,indent=2));return 0 if context['preflight']['passed'] else 2
    require(args.output is not None,'--output is required for prepare/run')
    output=args.output.resolve()
    require(not output.exists() and not output.is_relative_to(package) and not output.is_relative_to(model),'Output must be new and outside package/model')
    require(not any((parent/'.git').exists() for parent in (output,*output.parents)),'Output must be outside Git')
    argv=[str(package/'drivers/validate-qwen9-local-tp.py'),str(output),'--plans',args.plans]
    if args.prepare_only:argv.append('--prepare-only')
    previous_argv=sys.argv;sys.argv=argv
    for signum in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT):signal.signal(signum,driver.interrupted)
    result=None
    try:
        result=driver.main();return result
    finally:
        sys.argv=previous_argv
        if output.is_dir():
            context['driver_return_code']=result
            context['driver_receipt_sha256']=sha(output/'receipt.json') if (output/'receipt.json').is_file() else None
            try:
                verify_package(package,args.manifest_sha256);context['package_unchanged_after']=True
            except BaseException as error:
                context['package_unchanged_after']=False;context['package_error']=repr(error)
                write(output/'portable-execution.json',context);raise
            shutil.copyfile(Path(__file__),output/'run-qwen9-staged-local-tp.py')
            shutil.copyfile(package/'drivers/qwen9_staged_package.py',output/'qwen9_staged_package.py')
            write(output/'portable-execution.json',context)


if __name__=='__main__':sys.exit(main())
