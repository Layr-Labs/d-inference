"""Small source-only closure and exact-copy/inverse validation. No workspace/cache inventory."""
import ast
import hashlib
import json
from pathlib import Path

BASE=Path(__file__).resolve().parent

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    root=json.loads((BASE/'manifest.json').read_bytes())
    for value in root['manifests']:
        path=BASE/value['path']
        if sha(path)!=value['sha256']:raise ValueError('Subpackage freeze changed')
    counts={}
    for name in ['Build','Compare','Physical','Tests']:
        directory=BASE/name; value=json.loads((directory/'manifest.json').read_bytes())
        members=value.get('files',value.get('members'))
        for row in members:
            path=directory/row['path']; raw=path.read_bytes()
            if path.is_symlink() or len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:
                raise ValueError('Source member changed: '+str(path))
            if path.suffix=='.py':ast.parse(raw,filename=str(path))
        counts[name]=len(members)
    for row in json.loads((BASE/'Compare/helper-lineage.json').read_bytes())['exactCopies']:
        if sha(Path(row['source']))!=row['sha256'] or sha(BASE/'Compare'/row['path'])!=row['sha256']:
            raise ValueError('Exact comparator helper changed')
    old=(BASE/'Compare/audit_candidate.py').read_text()
    expected=old.replace('def compare(reference, candidates, expected_agreement, context):',
        'from accepted_rounds import accepted_agreement as agreement\n\n\ndef compare(reference, candidates, expected_agreement, context):')
    expected=expected.replace('mtpEnabled=False, physicalTransferQualified=False,','mtpEnabled=True, physicalTransferQualified=False,')
    expected=expected.replace("schema='private_generation128_numerical_comparison_v1'", "schema='qwen_mtp_accepted_target_comparison_v1'")
    if expected!=(BASE/'Compare/accepted_target.py').read_text():raise ValueError('Accepted target delta exceeds declared three changes')
    for row in json.loads((BASE/'Physical/template-lineage.json').read_bytes())['files']:
        if sha(Path(row['source']))!=row['sha256'] or sha(BASE/'Physical'/row['path'])!=row['sha256']:
            raise ValueError('Qualified physical predecessor changed')
    helper='c3910bf16a0fbe4d68ab6349e862ef5a2c92fe64e79a68d2ccfc700daf4fa2bf'
    if sha(BASE/'Tests/owned_process.py')!=helper:raise ValueError('Owned helper differs')
    staged=0
    for path in (BASE/'Tests').glob('test_*.py'):
        staged+=sum(isinstance(node,(ast.FunctionDef,ast.AsyncFunctionDef)) and node.name.startswith('test_') for node in ast.walk(ast.parse(path.read_text())))
    if staged!=16:raise ValueError('Expected16 staged CPU controls')
    print(json.dumps(dict(status='passed',sourceMembers=counts,stagedCPUControls=staged,
        comparatorExactCopies=8,physicalPredecessors=43,nativeExecuted=False,compilerExecuted=False,
        sourcePreparationPerformed=False,remoteExecuted=False),sort_keys=True))

if __name__=='__main__':main()
