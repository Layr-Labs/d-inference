"""Root-only small source successor; no payload, compiler, SSH, or tests."""
import argparse
import hashlib
import json
from pathlib import Path

BASE=Path(__file__).resolve().parent
ORIGINAL=BASE.parent/'gemma4-artifact-transfer-draft-20260917'
ORIGINAL_SHA='07c388917ec1f52fdb742f2942cfd04db539772b136e8585b29aa4b404b137c6'
def digest(raw):return hashlib.sha256(raw).hexdigest()
def encoded(value):return (json.dumps(value,indent=2,sort_keys=True)+'\n').encode()
def require(value,message):
    if not value:raise ValueError(message)
def checked(path,row):
    raw=path.read_bytes();require(len(raw)==row['bytes'] and digest(raw)==row['sha256'],'Changed source: '+str(path));return raw
def main():
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('--output',required=True,type=Path);args=parser.parse_args()
    require(args.output.is_absolute() and args.output.parent.resolve()==args.output.parent,'Canonical fresh output')
    correction_raw=(BASE/'manifest.json').read_bytes();correction=json.loads(correction_raw)
    for row in correction['files']:checked(BASE/row['path'],row)
    original_raw=(ORIGINAL/'manifest.json').read_bytes();require(digest(original_raw)==ORIGINAL_SHA,'Exact original freeze')
    originals={row['path']:checked(ORIGINAL/row['path'],row) for row in json.loads(original_raw)['files']}
    args.output.mkdir(mode=0o700)
    for name,raw in originals.items():(args.output/name).write_bytes(raw)
    for name in ('rsync_exec.py','test_owned_group.py'):(args.output/name).write_bytes((BASE/'proposed'/name).read_bytes())
    def pins(names):return {name:{'bytes':len((args.output/name).read_bytes()),'sha256':digest((args.output/name).read_bytes())} for name in sorted(names)}
    receiver=json.loads(originals['receiver-source-pins.json']);(args.output/'receiver-source-pins.json').write_bytes(encoded(pins(receiver)))
    local=set(json.loads(originals['source-pins.json']))|{'test_owned_group.py'}
    (args.output/'source-pins.json').write_bytes(encoded(pins(local)))
    commands=originals['commands.json'].decode().replace(str(ORIGINAL),str(args.output))
    value=json.loads(commands);value['ownedGroupControls']={'argv':['/usr/bin/python3','-B',str(args.output/'test_owned_group.py')],'suggestedOwnedParentBoundSeconds':30,'notExecuted':True}
    (args.output/'commands.json').write_bytes(encoded(value))
    (args.output/'source-checks.json').write_bytes(encoded(dict(sourceMaterializationOnly=True,originalSourceChecks=json.loads(originals['source-checks.json']),ownedGroupControlsStaged=3,executed=False)))
    (args.output/'original-manifest.json').write_bytes(original_raw)
    (args.output/'correction-manifest.json').write_bytes(correction_raw)
    (args.output/'correction-lineage.json').write_bytes(encoded(dict(originalSHA256=ORIGINAL_SHA,correctionSHA256=digest(correction_raw),runtimeChanges=['rsync_exec.py'],additionalTests=['test_owned_group.py'],payloadOrRemoteExecuted=False)))
    rows=[dict(path=p.name,bytes=len(p.read_bytes()),sha256=digest(p.read_bytes())) for p in sorted(args.output.iterdir()) if p.is_file()]
    raw=encoded(dict(schema='gemma4-artifact-transfer-owned-group-successor',files=rows,fileCount=len(rows),totalBytes=sum(r['bytes'] for r in rows)))
    (args.output/'manifest.json').write_bytes(raw)
    print(json.dumps(dict(output=str(args.output),manifestSHA256=digest(raw),files=len(rows))))
if __name__=='__main__':main()
