"""Source-only pins, inverse diff, AST and import check; launches no child."""
import ast
import difflib
import hashlib
import importlib
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parent

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    rows=json.loads((ROOT/'source-inputs.json').read_bytes())['members']
    for row in rows:
        p=ROOT/row['path'];assert p.is_file() and not p.is_symlink()
        assert sha(p)==row['sha256'] and p.stat().st_size==row['bytes'],row['path']
        if p.suffix=='.py':ast.parse(p.read_text(),filename=str(p))
    patch=[];unchanged=[]
    for row in json.loads((ROOT/'copy-provenance.json').read_bytes())['members']:
        old=Path(row['sourcePath']);saved=ROOT/'originals'/row['path'];new=ROOT/row['path']
        assert sha(old)==row['beforeSHA256']==sha(saved)
        before=saved.read_text();after=new.read_text()
        patch+=difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='a/'+row['path'],tofile='b/'+row['path'])
        if before==after:unchanged.append(row['path'])
    assert ''.join(patch)==(ROOT/'supervisor.patch').read_text()
    unchanged_required=['package/worker_processes.py','package/worker_contract.py','package/reference_resources.py',
        'package/mtp_journal.py','package/target_processes.py','owned_process.py','lease_source.py','parent_settings.py']
    assert all(x in unchanged for x in unchanged_required)
    sys.dont_write_bytecode=True;sys.path[:0]=[str(ROOT),str(ROOT/'package')]
    for name in ['activation','deploy','root_run','run_case','remote_metadata','compare','qmv_contract','native_gate','run_benchmark']:
        importlib.import_module(name)
    from qmv_contract import expected
    assert len(expected('dense'))==108 and len(expected('gathered'))==288
    required=json.loads((ROOT/'required-native-sources.json').read_bytes())
    for name in ['actualBuildReceipt','actualSources','kernelManifest','metadataSources']:
        row=required[name];assert sha(Path(row['path']))==row['sha256']
    print(json.dumps(dict(sourceOnly=True,members=len(rows),imports=9,preservedSupervisors=len(unchanged_required),
                         compilerExecuted=False,childExecuted=False,remoteExecuted=False),sort_keys=True))

if __name__=='__main__':main()
