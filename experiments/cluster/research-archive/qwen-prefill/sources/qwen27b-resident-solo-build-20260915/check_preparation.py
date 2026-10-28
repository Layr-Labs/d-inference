"""Source closure and exact operational helper checks; no full tree hashing or execution."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert not (BASE / 'workspace').exists(), 'Author check precedes materialization'
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text())
    assert (BASE / 'owned_process.py').read_bytes() == (BASE / 'upstream/owned_process.py').read_bytes()
    old_tree = ast.parse((BASE / 'upstream/prepare_build.py').read_text())
    new_tree = ast.parse((BASE / 'build_inputs.py').read_text())
    method = lambda tree, name: next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == name)
    assert ast.dump(method(old_tree, 'members')) == ast.dump(method(new_tree, 'members'))
    old_build = ast.parse((BASE / 'upstream/build_check.py').read_text())
    new_build = ast.parse((BASE / 'build_check.py').read_text())
    old_argv = next(node.value for node in ast.walk(old_build) if isinstance(node, ast.Assign)
        and isinstance(node.value, ast.List) and node.value.elts and
        isinstance(node.value.elts[0], ast.Constant) and node.value.elts[0].value == 'swift')
    new_argv = next(node for node in ast.walk(new_build) if isinstance(node, ast.List) and node.elts
        and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == 'swift')
    assert ast.dump(old_argv) == ast.dump(new_argv), 'Actual qualified build flags changed'
    info = json.loads((BASE / 'run-template-lineage.json').read_bytes())
    changed = {'solo_inputs.py', 'solo_contract.py', 'worker_processes.py'}
    for name, expected in info['runtimeFiles'].items():
        assert sha(BASE / 'run-template' / name) == expected
        if name not in changed:
            assert expected == info['originalFiles'][name]
    assert info['safeWorkerProcessesSHA256'] == '26448b0b7a2bdfb2d06efd78ba2924a8d3786bf6371c4e5e2b126651dd095356'
    assert sha(BASE / 'run-template/worker_processes.py') == info['safeWorkerProcessesSHA256']
    names = set(info['runtimeFiles'])
    for name in names:
        tree = ast.parse((BASE / 'run-template' / name).read_text())
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                target = node.module.replace('.', '/') + '.py'
                if target.startswith(('binding_', 'reference_', 'solo_', 'worker_', 'stage_checks/')):
                    assert target in names, (name, target)
    print(json.dumps(dict(status='passed', sourceOnly=True, ownedHelperExact=True,
        sourceSnapshotConventionAndCompilerFlagsExact=True, runClosureMembers=len(names),
        changedRunSources=sorted(changed), safeOwnershipHelperPinned=True, workspaceMaterialized=False,
        compilerModelOrRemoteExecuted=False), sort_keys=True, indent=2))


if __name__ == '__main__':
    main()
