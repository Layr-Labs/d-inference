"""Small source/AST/inverse checks only; never imports or executes the fixtures."""
import ast
import hashlib
import json
from pathlib import Path
BASE=Path(__file__).resolve().parent


def main():
    lineage=json.loads((BASE/'source-lineage.json').read_bytes());checked=0
    for row in lineage['copies']:
        source=Path(row['source']).read_bytes()
        assert len(source)==row['bytes'] and hashlib.sha256(source).hexdigest()==row['sha256'],row['source']
        actual=(BASE/row['destination']).read_bytes()
        if row['destination']=='package/worker_contract.py':
            source=source.replace(b'MAX_LINE = 32 * 1024 * 1024',b'MAX_LINE = 1_048_576').replace(b'MAX_OUTPUT = 160 * 1024 * 1024',b'MAX_OUTPUT = 2 * 1024 * 1024')
        elif row['destination']=='parent_settings.py':source=source.replace(b"'-T',",b"'-T', '-S', 'none',")
        assert actual==source,row['destination'];checked+=1
    original=(BASE/'package/worker_processes.py').read_bytes()
    assert (BASE/'ssh_processes.py').read_bytes()==original.replace(b'<= 315',b'<= 360').replace(b'Worker lifetime must be1...315seconds',b'Worker lifetime must be1...360seconds')
    original=(BASE/'originals/target_processes.py').read_bytes()
    assert (BASE/'package/target_processes.py').read_bytes()==original.replace(b"'collectiveallocationcheck',",b"'collectiveallocationcheck', 'gemmashortcorrectnesscheck',")
    original=(BASE/'originals/install_new_tree.py').read_bytes()
    assert (BASE/'install_new_tree.py').read_bytes()==original.replace(b'gemma-window-state-check-20260916',b'gemma4-short-correctness-20260916').replace(b'window_state_native',b'gemma_short')
    files=list(BASE.rglob('*.py'))
    for path in files:ast.parse(path.read_bytes(),filename=str(path))
    tree=ast.parse((BASE/'Tests/test_supervision.py').read_bytes())
    methods=sum(isinstance(n,ast.FunctionDef) and n.name.startswith('test_') for n in ast.walk(tree));assert methods==14
    metadata=Path('/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Tests/StageMetadataChecks/Inputs')
    for row in json.loads((BASE/'metadata-controls.json').read_bytes()):
        raw=(metadata/row['path']).read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
    actual=json.loads((BASE/'package/native-build-reference.json').read_bytes())
    receipt=Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-short-correctness-draft-20260916/build/native-1/receipt.json').read_bytes()
    assert hashlib.sha256(receipt).hexdigest()==actual['buildReceiptSHA256']
    build=json.loads(receipt);assert build['status']=='passed' and build['binary']['sha256']==actual['nativeSHA256']
    print(json.dumps(dict(passed=True,pythonSourcesParsed=len(files),sourceCopyBindingsChecked=checked,
        stagedCPUFixtureMethods=methods,fixturesExecuted=False,compilerExecuted=False,nativeExecuted=False,
        sourcePreparationExecuted=False,remoteExecutedByThisCheck=False),sort_keys=True))
if __name__=='__main__':main()
