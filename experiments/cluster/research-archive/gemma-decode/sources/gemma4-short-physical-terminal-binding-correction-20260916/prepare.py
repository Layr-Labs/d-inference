"""Future root-granted small source composition only; no tests/binaries/remote."""
import argparse
import hashlib
import json
from pathlib import Path
import os

BASE=Path(__file__).resolve().parent
OLD=BASE.parent/'gemma4-short-physical-draft-20260916'
OLD_SHA='26fe8d9d4601e3211d2db8444a1af581c19ab61f26f623da918c5da0bc341aee'

def sha(raw):return hashlib.sha256(raw).hexdigest()
def encoded(value):return (json.dumps(value,sort_keys=True,indent=2)+'\n').encode()
def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    if not a.output.is_absolute() or a.output.parent.resolve()!=a.output.parent:raise ValueError('Canonical fresh output required')
    old_raw=(OLD/'manifest.json').read_bytes()
    if sha(old_raw)!=OLD_SHA:raise ValueError('Predecessor manifest changed')
    correction_raw=(BASE/'manifest.json').read_bytes();correction=json.loads(correction_raw)
    for row in correction['files']:
        raw=(BASE/row['path']).read_bytes()
        if len(raw)!=row['bytes'] or sha(raw)!=row['sha256']:raise ValueError('Correction member changed')
    members={}
    for row in json.loads(old_raw)['files']:
        raw=(OLD/row['path']).read_bytes()
        if len(raw)!=row['bytes'] or sha(raw)!=row['sha256']:raise ValueError('Predecessor member changed')
        members[row['path']]=raw
    for row in json.loads((BASE/'preimages.json').read_bytes())['files']:
        if sha(members[row['path']])!=row['sha256']:raise ValueError('Source preimage differs')
    for name in ('run_physical.py','validate_collected.py','terminal_binding.py'):members[name]=(BASE/'proposed'/name).read_bytes()
    members['Tests/test_terminal_binding.py']=(BASE/'Tests/test_terminal_binding.py').read_bytes()
    members['CORRECTION.md']=(BASE/'CORRECTION.md').read_bytes()
    members['terminal-binding-correction.json']=encoded(dict(predecessorManifestSHA256=OLD_SHA,correctionManifestSHA256=sha(correction_raw),
        sourceOnly=True,nativeOrFixtureExecuted=False))
    a.output.mkdir(mode=0o700);os.umask(0o077)
    for name,raw in sorted(members.items()):
        path=a.output/name;path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        with path.open('xb') as out:out.write(raw)
    manifest=encoded(dict(schema='gemma_short_physical_source_manifest_v1',files=[dict(path=name,bytes=len(raw),sha256=sha(raw)) for name,raw in sorted(members.items())]))
    with (a.output/'manifest.json').open('xb') as out:out.write(manifest)
    print(json.dumps(dict(output=str(a.output),members=len(members),manifestSHA256=sha(manifest),modelOrRemoteExecuted=False)))
if __name__=='__main__':main()
