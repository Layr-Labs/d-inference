#!/usr/bin/python3
"""Small read-only source/lineage check; no compiler, crypto or workspace copy."""
import ast, hashlib, json
from pathlib import Path
ROOT=Path('/Users/developer/DarkbloomDev/d-inference')
HERE=Path(__file__).resolve().parent.parent
RESEARCH=HERE.parent

def digest(path):
    if path.is_symlink() or not path.is_file(): raise ValueError('expected regular source: '+str(path))
    return hashlib.sha256(path.read_bytes()).hexdigest()
def check_manifest(folder,expected):
    p=folder/'manifest.json'
    if digest(p)!=expected: raise ValueError('upstream manifest changed')
    rows=json.loads(p.read_text())['files']
    for row in rows:
        if digest(folder/row['path'])!=row['sha256']: raise ValueError('upstream member changed: '+row['path'])
    return len(rows)
def main():
    member=check_manifest(RESEARCH/'cluster-registered-member-draft-20260915','4ae431c60990ff9e4dfe319b8b5387ac8fb6bffcd54eac0213d3f85ed60ef965')
    native=check_manifest(RESEARCH/'cluster-native-key-prelude-validation-3-20260916/source','61f28887e6165c6f488071882868216c6e92bb1f1f6f81cec826c7de0349c5bf')
    rows=json.loads((HERE/'integration.json').read_text())['files']
    for row in rows:
        p=Path(row['effectiveBasePath']) if row['effectiveBasePath'] else None
        if p is not None and digest(p)!=row['baseSHA256']: raise ValueError('effective preimage changed')
        main=ROOT/row['path']
        if row['mainSHA256'] is None:
            if main.exists() or main.is_symlink(): raise ValueError('MAIN addition no longer absent')
        elif digest(main)!=row['mainSHA256']: raise ValueError('MAIN preimage changed')
        if digest(HERE/'proposed'/row['path'])!=row['proposedSHA256']: raise ValueError('proposed source changed')
    for row in json.loads((HERE/'source-pins.json').read_text())['files']:
        if digest(Path(row['path']))!=row['sha256']: raise ValueError('source dependency changed')
    for p in HERE.rglob('*.py'): ast.parse(p.read_text(),filename=str(p))
    print(json.dumps({'status':'source checks only PASS','memberManifestMembers':member,'nativeManifestMembers':native,'proposedFiles':len(rows),'compilerRun':False,'nativeRun':False,'mainChanged':False},sort_keys=True))
if __name__=='__main__':main()
