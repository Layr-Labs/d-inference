"""Small source/metadata replay only; large payload identity comes from the copy receipt."""
import ast
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'package'))
from target_contract import BUNDLE, JOBS, SOURCE


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    package = ROOT/'package'
    for path in ROOT.rglob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
    copied = json.loads((ROOT/'bundle-preparation.json').read_bytes())
    assert copied['status'] == 'passed' and copied['bundleSHA256'] == BUNDLE
    assert sha(package/'bundle/bundle.json') == BUNDLE
    bundle = json.loads((package/'bundle/bundle.json').read_bytes())
    assert bundle['sourceSnapshotSHA256'] == SOURCE
    assert bundle['jobs'] == {k:{a:b for a,b in job.items() if a != 'sha256'} for k,job in JOBS.items()}
    resources = {'bundle/'+x['path']:x for x in copied['files']}
    declared = json.loads((package/'package.json').read_bytes())['files']
    assert len(declared) == 58
    for row in declared:
        path = package/row['path']
        assert path.is_file() and not path.is_symlink() and path.stat().st_size == row['bytes']
        if row['path'] in resources:
            assert row['sha256'] == resources[row['path']]['sha256']
        else:
            assert sha(path) == row['sha256']
    assert {str(p.relative_to(package)) for p in package.rglob('*') if p.is_file()} == {x['path'] for x in declared} | {'package.json'}
    for name in ['session_result.py', 'transaction_result.py']:
        old = ast.parse((ROOT/'originals'/name).read_text())
        new = ast.parse((package/name).read_text())
        methods = lambda tree:[ast.dump(x) for x in tree.body if isinstance(x, ast.FunctionDef)]
        assert methods(old) == methods(new)
    helper = json.loads((ROOT/'helper-lineage.json').read_bytes())['helpers']
    unchanged = ['binding_common.py', 'binding_inputs.py', 'mtp_journal.py', 'reference_resources.py',
                 'stage_checks/__init__.py', 'stage_checks/common.py', 'worker_contract.py', 'worker_processes.py']
    for name in unchanged:
        row = next(x for x in helper if x['path'] == 'package/'+name)
        assert sha(package/name) == row['sha256']
    binding = json.loads((ROOT/'native-source-binding.json').read_bytes())
    assert len(binding['sourceFiles']) == 33 and binding['sourceSnapshotSHA256'] == SOURCE
    for row in binding['sourceFiles']:
        assert sha(package/'native-contract/sources'/row['path']) == row['sha256']
    deployment = json.loads((ROOT/'deployment.json').read_bytes())['files']
    assert len(deployment) == 59
    assert {x.removeprefix('check/') for x in deployment} == {x['path'] for x in declared} | {'package.json'}
    commands = json.loads((ROOT/'ROOT-COMMANDS.json').read_bytes())
    assert sha(ROOT/'deployment.json') == commands['deploymentSHA256']
    assert sha(package/'package.json') == commands['packageSHA256']
    assert set(commands['runRemote']) == set(JOBS)
    print(json.dumps(dict(sourceReplay=True, unchangedCoreHelpers=8, preservedValidatorBodies=2,
                         packageFiles=58, deploymentFiles=59, boundNativeSources=33,
                         largePayloadRehashPerformed=False, retainedActualBundleCopyHashes=True,
                         nativeExecuted=False, remoteExecuted=False), sort_keys=True))


if __name__ == '__main__': main()
