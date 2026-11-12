"""Bind actual future source/build receipts; no runtime or remote launch."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'package'))
from binding_common import parse,require,pin,same

def read(path,wanted=None):
    path=Path(path)
    require(path.is_absolute() and path.resolve()==path and not path.is_symlink()
            and path.is_file() and 0<path.stat().st_size<=2_000_000,'Bounded canonical receipt')
    raw=path.read_bytes();digest=hashlib.sha256(raw).hexdigest()
    if wanted is not None:same(digest,pin(wanted),'Receipt hash')
    return parse(raw),dict(path=str(path),bytes=len(raw),sha256=digest)

def compose(build_ref,source_ref):
    inputs,_=read(ROOT/'binding-inputs.json')
    same(inputs['schema'],'gemma4_full_expert_future_build_v1','Binding schema')
    expected={}
    for reference in inputs['sourcePackages']:
        package,_=read(reference['path'],reference['sha256'])
        for row in package['overlays']:
            expected[row['destination']]=dict(path=row['destination'],bytes=row['bytes'],sha256=row['sha256'])
    source,source_pin=read(source_ref['path'],source_ref['sha256'])
    rows=source['files'];require(type(rows) is list and len(rows)<=256,'Applied file bounds')
    actual={row['path']:row for row in rows};require(len(actual)==len(rows),'Duplicate applied source')
    for name,row in expected.items():same(actual.get(name),row,'Actual composed full EP source')
    # Each source package is joined by its actual immutable source-input digest.
    same(source['fullExpertSourceInputsSHA256'],[x['sha256'] for x in inputs['sourcePackages']],
         'Applied receipt must explicitly identify both reviewed source packages')
    build,build_pin=read(build_ref['path'],build_ref['sha256'])
    require(build['product']==inputs['product'] and type(build['exitCode']) is int and build['exitCode']==0
            and build['compilerReaped'] is True and build['gpuExecuted'] is False,'Build did not retire successfully')
    same(build['sourcesSHA256'],source_pin['sha256'],'Actual build/source join')
    require(type(build['nativeBytes']) is int and 0<build['nativeBytes']<200_000_000,'Native bound')
    require(build['target'].startswith(inputs['binaryDirectory']+'/'+inputs['product']+':\n')
            and 'minos 26.2\n' in build['target'],'Actual target architecture/minimum')
    lineage,_=read(inputs['resourceLineage']['path'],inputs['resourceLineage']['sha256'])
    same(inputs['resources'],lineage['resources'],'Qualified unchanged metallib/matrix lineage')
    return dict(schema='gemma4_full_expert_actual_build_v1',product=inputs['product'],
        binaryDirectory=inputs['binaryDirectory'],nativeSHA256=pin(build['nativeSHA256']),nativeBytes=build['nativeBytes'],
        buildReceipt=build_pin,appliedSources=source_pin,sourcePackages=inputs['sourcePackages'],
        resources=inputs['resources'],resourceLineage=inputs['resourceLineage'],
        metadataAndPromptSources=inputs['metadataAndPromptSources'])

def verify():
    value,_=read(ROOT/'artifact-bindings.json')
    same(value,compose(value['buildReceipt'],value['appliedSources']),'Actual build binding')
    return value

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    for key in ['build','build-sha256','sources','sources-sha256']:parser.add_argument('--'+key,required=True)
    args=parser.parse_args()
    value=compose(dict(path=args.build,sha256=args.build_sha256),dict(path=args.sources,sha256=args.sources_sha256))
    raw=json.dumps(value,sort_keys=True,indent=2).encode()+b'\n'
    with (ROOT/'artifact-bindings.json').open('xb') as stream:stream.write(raw)
    print(json.dumps(dict(bound=True,sha256=hashlib.sha256(raw).hexdigest())))
if __name__=='__main__':main()
