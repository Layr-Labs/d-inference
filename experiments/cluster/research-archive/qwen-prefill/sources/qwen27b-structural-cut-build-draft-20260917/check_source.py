"""Small-file source check only. No workspace/cache scan, clone or compiler."""
import ast
import hashlib
import json
import os
from pathlib import Path

BASE = Path(__file__).resolve().parent
DRAFT = BASE.parent / 'qwen27b-structural-cut-validation-draft-20260916'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(value, message):
    if not value:
        raise RuntimeError(message)


def main():
    require(digest(DRAFT / 'manifest.json') == '32eeb9b524b16fb2551d6faf7bd7dd1db1c84c7480287853173bdad544539121', 'Source candidate changed')
    for row in json.loads((DRAFT / 'manifest.json').read_bytes())['files']:
        p = DRAFT / row['path']
        require(p.stat().st_size == row['bytes'] and digest(p) == row['sha256'], 'Frozen structural source changed')
    require((BASE / 'owned_process.py').read_bytes() == (DRAFT / 'owned_process.py').read_bytes(), 'Owned cleanup helper changed')
    plan = json.loads((DRAFT / 'native-qualification-plan.json').read_bytes())
    links = json.loads((BASE / 'source-links.json').read_bytes())
    require(set(plan['ancestors']) == set(links) == {'resident', 'reference'}, 'Two separate native ancestries required')
    for role, spec in plan['ancestors'].items():
        for name in ['sourceSnapshot', 'dependencySnapshot', 'bundleManifest', 'definitionPreimage']:
            row = spec[name]; path = Path(row['path'])
            require(path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], 'Ancestry descriptor changed')
        for name, value in links[role].items():
            path = Path(spec['workspaceAncestor']) / name
            require(path.is_symlink() and os.readlink(path) == value, 'Retained source link changed')
            if Path(value).is_absolute():
                require(value.startswith(spec['workspaceAncestor'] + '/'), 'Absolute source link escapes its ancestry')
        require(spec['compilerJobsMaximum'] == 2 and spec['compilerSeconds'] == 900, 'Compiler bounds changed')
    extra = json.loads((BASE / 'extra-inputs.json').read_bytes())
    for row in [extra['referenceRetainedFixture']] + extra['privateLookaheadAndPureArgumentSource']:
        path = Path(row['path'])
        require(path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], 'CPU/argument source input changed')
    names = sorted(p.name for p in BASE.glob('*.py'))
    for name in names:
        ast.parse((BASE / name).read_text(), filename=name)
    # Both build commands are the existing product-specific commands. No
    # common dependency resolver, package manifest or native source is added.
    text = (BASE / 'build_native.py').read_text()
    require("'--jobs', '2'" in text and "'compile', compile_argv, 900" in text,
            'Reference compile bounds missing')
    require("str(package / 'build-native-worker.sh')" in text, 'Resident inherited native runner missing')
    require('QwenOwnedStageRequestBudget' not in (BASE / 'prepare_native.py').read_text(), 'Prospective accounting must not be staged')
    frozen = BASE / 'manifest.json'
    count = None
    if frozen.exists():
        rows = json.loads(frozen.read_bytes())['files']
        for row in rows:
            path = BASE / row['path']
            require(path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], 'Build frozen member changed')
        count = len(rows)
    print(json.dumps(dict(passed=True, pythonSources=len(names), sourceMembersVerified=27,
        sourceLinksVerified={role: len(value) for role, value in links.items()}, frozenMembers=count,
        fullSourceOrDependencyTreesHashed=False, payloadRead=False,
        materializationCompilerNativeRemoteExecuted=False), sort_keys=True))


if __name__ == '__main__':
    main()
