#!/usr/bin/env python3
"""Read the explicit small source closure; no cache, compiler, child or model IO."""
import ast, difflib, hashlib, json
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def check():
    value=json.loads((ROOT/'lineage.json').read_bytes()); base=Path(value['qualifiedWorkspace'])
    for row in value['predecessorPins']:
        p=Path(row['path']); assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],str(p)
    patch=''
    for row in value['overlays']:
        p=ROOT/'proposed'/row['path']; old=ROOT/'original'/row['path']
        assert sha(p)==row['sha256'] and p.stat().st_size==row['bytes']
        if row['beforeSHA256'] is None: assert not old.exists(); before=''
        else:
            assert sha(old)==sha(row['predecessorSource'])==row['beforeSHA256']; before=old.read_text()
        main=ROOT.parent.parent/'d-inference'/row['path']
        assert (sha(main) if main.exists() else None)==row['mainSHA256']
        patch+=''.join(difflib.unified_diff(before.splitlines(True),p.read_text().splitlines(True),fromfile='a/'+row['path'] if old.exists() else '/dev/null',tofile='b/'+row['path']))
    assert patch==(ROOT/'runtime-and-tests.patch').read_text() and sha(ROOT/'runtime-and-tests.patch')==value['patchSHA256']
    for row in value['unchangedBaseControls']:
        assert sha(base/row['path'])==row['sha256'] and (base/row['path']).stat().st_size==row['bytes']
    composition=json.loads((ROOT/'Build/composition.json').read_bytes())
    assert sha(composition['priorInventoryPath'])==composition['priorInventorySHA256']
    prior=json.loads(Path(composition['priorInventoryPath']).read_bytes()); expected=dict(prior)
    for row in composition['files']:
        assert prior.get(row['path'],{}).get('sha256')==row['beforeSHA256'] and sha(row['sourcePath'])==row['sha256']
        assert (sha(base/row['path']) if (base/row['path']).exists() else None)==row['beforeSHA256']
        expected[row['path']]={'sha256':row['sha256']}
    assert expected==json.loads((ROOT/'Build/candidate-after.json').read_bytes()) and sha(ROOT/'Build/candidate-after.json')==composition['candidateInventorySHA256']
    for row in composition['sourceHelpers']: assert sha(ROOT/'Build'/row['path'])==sha(row['source'])==row['sha256']
    prefix='provider-swift/Sources/ProviderCore/'
    owner=(ROOT/'original'/prefix/'Coordinator/NativePairRequestExecutionOwner.swift').read_text()
    body=owner[owner.index('        guard request.promptTokens.count'):owner.index('\n    }',owner.index('        guard request.promptTokens.count'))]
    assert body in (ROOT/'proposed'/prefix/'Inference/Distributed/ProtectedLocalWorkload.swift').read_text()
    for p in [ROOT/'check_sources.py',*sorted((ROOT/'Build').glob('*.py'))]: ast.parse(p.read_text())
    return dict(passed=True,overlays=len(value['overlays']),composedFiles=len(composition['files']),baseInventory=len(prior),candidateInventory=len(expected),prospectiveTests=175,compilerOrFixturesExecuted=False,originalShapeGateExact=True)
if __name__=='__main__': print(json.dumps(check(),sort_keys=True))
