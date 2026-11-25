"""Exact small-source replay for the same-build solo extension; no children."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent
def sha(raw):return hashlib.sha256(raw).hexdigest()

def main():
    value=json.loads((ROOT/'integration.json').read_bytes())
    live=Path(value['liveDraftRoot']);patch=''
    for row in value['changes']:
        name=row['path'];new=(ROOT/'after'/name).read_bytes()
        assert sha(new)==row['afterSHA256'] and len(new)==row['afterBytes']
        assert (live/name).read_bytes()==new, name
        old=(ROOT/'before'/name).read_bytes() if row['beforeSHA256'] is not None else b''
        assert not old or sha(old)==row['beforeSHA256']
        patch+=''.join(difflib.unified_diff(old.decode().splitlines(True),new.decode().splitlines(True),
            fromfile='a/'+name if old else '/dev/null',tofile='b/'+name))
        ast.parse(new,filename=name)
    assert patch.encode()==(ROOT/'runtime.patch').read_bytes()
    for row in value['unchangedSupervision']:
        raw=(live/row['path']).read_bytes()
        assert sha(raw)==row['sha256'] and len(raw)==row['bytes'], row['path']
    print(json.dumps(dict(passed=True,exactChanges=5,unchangedSupervisionPins=9,
        pythonAST=True,compilerExecuted=False,nativeExecuted=False,remoteExecuted=False,childExecuted=False)))

if __name__=='__main__':main()
