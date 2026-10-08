#!/usr/bin/env python3
"""Read-only source/path/patch verification; does not execute the public runner."""
from pathlib import Path
import ast
import difflib
import hashlib
import json
import re

D=Path(__file__).resolve().parent
REPO=Path('/Users/developer/DarkbloomDev/d-inference')
PROPOSED=D/'proposed'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def check():
    m=json.loads((D/'source-map.json').read_text())
    test=Path('experiments/cluster/inference/Tests/ShortRequestLedger')
    source=Path('experiments/cluster/inference/Sources/ClusterInference')
    run=PROPOSED/test/'run.sh';text=run.read_text()
    paths=[]
    for line in text.splitlines():
        hit=re.fullmatch(r'  "\$(source_dir|test_dir)/([^"]+\.swift)" \\',line)
        if hit:
            base=source if hit[1]=='source_dir' else test
            path=(REPO/base/hit[2]).resolve().relative_to(REPO)
            paths.append(str(path))
    assert paths==[x['path'] for x in m['orderedSwiftInputs']] and len(paths)==21
    for x in m['orderedSwiftInputs']:assert sha(REPO/x['path'])==x['sha256'],x['path']
    assert sha(REPO/m['sharedStdin'])==m['sharedStdinSHA256']
    assert '"$test_dir/../RegisteredDenseProfiles/retained-inputs.json"' in text
    assert '-parse-as-library -swift-version 6 -warnings-as-errors' in text
    assert 'trap \'rm -rf -- "$check_dir"\' EXIT' in text
    assert '--model-dir' not in text and 'curl ' not in text
    assert not list(PROPOSED.rglob('*.json')) and not list(PROPOSED.rglob('*.swift'))
    patches=[]
    for name,pin in m['documentBases'].items():
        assert sha(REPO/name)==pin,name
        before=(REPO/name).read_text();after=(PROPOSED/name).read_text()
        patches.append(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='a/'+name,tofile='b/'+name)))
    # Patch order is the author insertion order, independent of sorted JSON keys.
    expected=(D/'docs.patch').read_text()
    assert expected==''.join(reversed(patches)) or expected==''.join(patches)
    page=Path('experiments/cluster/inference/QWEN_DENSE_SHORT_LEDGER.md')
    doc=(PROPOSED/page).read_text()
    assert doc.splitlines()[2]=='> Last updated: 2026-09-14 · commit `e4df336bc`'
    for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)',doc):
        assert '://' not in target
        relative=(REPO/page.parent/target.split('#')[0]).resolve().relative_to(REPO)
        assert (PROPOSED/relative).is_file() or (REPO/relative).is_file(),relative
    for literal in ['31 accepted / 42 rejected','public runner execution remains pending',
                    'allocatorProvenanceIndependentlyVerified','runtimeExecutionAuthorized',
                    'not a whole-process peak','without loading weights']:
        assert literal in doc,literal
    for p in PROPOSED.rglob('*'):
        if p.is_file():assert '/Users/' not in p.read_text(),p
    ast.parse(Path(__file__).read_text(),feature_version=(3,9))
    return {'kind':'public_short_ledger_source_check','schemaVersion':1,'result':'passed',
            'orderedSwiftInputs':21,'proposedFiles':len([p for p in PROPOSED.rglob('*') if p.is_file()]),
            'sharedMetadataReused':True,'publicRunnerExecuted':False,'compilerOrNativeExecuted':False}

if __name__=='__main__':print(json.dumps(check(),sort_keys=True,indent=2))
