#!/usr/bin/env python3
"""Build a portable package locally from completed, frozen evidence; never SSHs."""
import argparse
import json
from pathlib import Path
import shutil
import sys
import tarfile

sys.dont_write_bytecode=True
from qwen9_staged_package import require,sha,read,write,contained,verify_package
HERE=Path(__file__).resolve().parent
ORIGIN=HERE/'runs/qwen9-local-tp-full-20260913'
INPUT=HERE/'runs/qwen9-output-boundaries-20260913'
BINARY='26fe9543a617d97309c581bfdf80fc929b85fb2c652d9cd560f61191d1794770'
CONFIG='c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
AGGREGATE='127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'


def copy_exact(source,target,expected=None):
    require(source.is_file() and not source.is_symlink(),'Missing/symlink package source')
    if expected:require(sha(source)==expected,'Original evidence changed: '+str(source))
    target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    shutil.copyfile(source,target)
    require(sha(source)==sha(target),'Copy verification failed')
    target.chmod(0o500 if target.name=='cluster-inference' else 0o400)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('destination',type=Path)
    args=parser.parse_args();dest=args.destination.resolve()
    require(not dest.exists() and not any((p/'.git').exists() for p in (dest,*dest.parents)),'New package must be outside Git')
    archive=dest.with_suffix('.tar')
    require(not archive.exists(),'Archive already exists')
    origin=read(ORIGIN/'receipt.json')
    require(origin['status']=='completed' and origin['binary_sha256']==BINARY,'Origin bundle is not the reviewed completed run')
    require(origin['model_before_aggregate_sha256']==AGGREGATE,'Origin artifact pin differs')
    dest.mkdir(mode=0o700,parents=True)
    copy_exact(ORIGIN/'receipt.json',dest/'origin/receipt.json')
    copy_exact(ORIGIN/'source-manifest.json',dest/'source-manifest.json',origin['source_manifest_sha256'])
    sources=read(ORIGIN/'source-manifest.json')
    for entry in sources:copy_exact(contained(ORIGIN/'source',entry['path']),dest/'source'/entry['path'],entry['sha256'])
    bundle=read(ORIGIN/'bundle/bundle.json')
    copy_exact(ORIGIN/'bundle/bundle.json',dest/'bundle/bundle.json',origin['bundle_manifest_sha256'])
    for entry in bundle['files']:copy_exact(contained(ORIGIN/'bundle',entry['path']),dest/'bundle'/entry['path'],entry['sha256'])
    for name,digest in origin['driver_files_sha256'].items():copy_exact(ORIGIN/name,dest/'drivers'/name,digest)
    for name in ('run-qwen9-staged-local-tp.py','qwen9_staged_package.py'):copy_exact(HERE/name,dest/'drivers'/name)
    for name,digest in origin['input_files_sha256'].items():copy_exact(INPUT/name,dest/'input'/name,digest)
    copy_exact(INPUT/'receipt.json',dest/'input/receipt.json',origin['input_receipt_sha256'])
    files=[dict(path=p.relative_to(dest).as_posix(),size_bytes=p.stat().st_size,sha256=sha(p))
           for p in sorted(dest.rglob('*')) if p.is_file()]
    manifest=dict(schema_version=1,kind='qwen9-local-loopback-correctness',
        origin=dict(receipt_sha256=sha(ORIGIN/'receipt.json'),binary_sha256=BINARY,
            source_manifest_sha256=origin['source_manifest_sha256'],bundle_manifest_sha256=origin['bundle_manifest_sha256'],
            dependencies=origin['dependencies'],input_receipt_sha256=origin['input_receipt_sha256'],
            preparation_script_sha256=sha(Path(__file__))),
        pins=dict(aggregate_sha256=AGGREGATE,config_sha256=CONFIG,prompt_tokens=96,output_tokens=4,
            chunk_size=32,teacher_tokens=[4087,13,271],execution_path='cbv2-contiguous',
            default_plans=['solo','ffn','full'],policies=['native','both-wide']),files=files)
    write(dest/'package-manifest.json',manifest);(dest/'package-manifest.json').chmod(0o400)
    fingerprint=sha(dest/'package-manifest.json');verify_package(dest,fingerprint)
    with tarfile.open(archive,'w') as output:
        for name in sorted([e['path'] for e in files]+['package-manifest.json']):
            output.add(dest/name,arcname=name,recursive=False)
    result=dict(package=str(dest),package_manifest_sha256=fingerprint,files=len(files),
        package_payload_bytes=sum(e['size_bytes'] for e in files),tar=str(archive),tar_sha256=sha(archive),
        binary_sha256=BINARY,remote_actions=0,native_runs=0)
    write(dest.with_name(dest.name+'-preparation.json'),result)
    print(json.dumps(result,indent=2));return 0


if __name__=='__main__':sys.exit(main())
