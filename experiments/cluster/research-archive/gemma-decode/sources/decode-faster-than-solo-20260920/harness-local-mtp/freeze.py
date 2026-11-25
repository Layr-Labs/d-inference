"""Bind completed actual native build and final reviewed harness source."""
from pathlib import Path
import argparse
import ast
import hashlib
import json

ROOT=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--build-receipt',type=Path,required=True)
    p.add_argument('--sources',type=Path,required=True)
    a=p.parse_args();build=json.loads(a.build_receipt.read_bytes());source=json.loads(a.sources.read_bytes())
    assert build['exitCode']==0 and build['compilerReaped'] and build['groupAbsent'] and not build['gpuExecuted']
    assert build['sourcesSHA256']==sha(a.sources)
    required=json.loads((ROOT/'required-native-sources.template.json').read_bytes())
    required.update(actualBuildReceipt=dict(path=str(a.build_receipt),sha256=sha(a.build_receipt)),
        actualSources=dict(path=str(a.sources),sha256=sha(a.sources)),nativeSHA256=build['nativeSHA256'],
        nativeBytes=build['nativeBytes'],requiredFiles=source['files'])
    with (ROOT/'required-native-sources.json').open('x') as f:json.dump(required,f,indent=2);f.write('\n')
    members=[]
    for path in sorted(ROOT.rglob('*')):
        if path.is_file() and not any(x in ('__pycache__','preimages') for x in path.relative_to(ROOT).parts):
            assert path.suffix in ('.py','.json','.md','.patch'),str(path)
            if path.suffix=='.py':ast.parse(path.read_bytes(),str(path))
            members.append(dict(path=str(path.relative_to(ROOT)),bytes=path.stat().st_size,sha256=sha(path)))
    with (ROOT/'source-inputs.json').open('x') as f:json.dump(dict(schema='gemma4_local_mtp_harness_sources_v1',members=members),f,indent=2);f.write('\n')
    print(json.dumps(dict(sourceManifestSHA256=sha(ROOT/'source-inputs.json'),members=len(members),nativeSHA256=build['nativeSHA256'])))

if __name__=='__main__':main()
