"""Selected-source and metadata checks only; no workspace/cache/child execution."""
import ast
import difflib
import json
from pathlib import Path
from build_inputs import BASE, inputs, sha
from build_native import expected_cases


def main():
    v, old, source, overlay, exclude = inputs()
    for path in BASE.glob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
    original = ast.parse((BASE / 'originals/base_build_inputs.py').read_text())
    current = ast.parse((BASE / 'build_inputs.py').read_text())
    old_snapshot = next(x for x in original.body if isinstance(x, ast.FunctionDef) and x.name == 'snapshot')
    new_snapshot = next(x for x in current.body if isinstance(x, ast.FunctionDef) and x.name == 'entries')
    old_snapshot.name = 'entries'
    if ast.dump(old_snapshot) != ast.dump(new_snapshot):
        raise ValueError('Qualified ancestry snapshot convention changed')
    links = [x for x in source if 'symlink' in x]
    if links != [dict(path='libs/mlx-swift/Source/Cmlx/mlx/CLAUDE.md', symlink='AGENTS.md')]:
        raise ValueError('Unexpected ancestral source symlink')
    by = {r['path']: r for r in source}
    if len({r['path'] for r in overlay}) != 45 or len({r['path'] for r in exclude}) != 5:
        raise ValueError('Duplicate composition entry')
    if set(r['path'] for r in overlay) & set(r['path'] for r in exclude):
        raise ValueError('Overlapping restoration and exclusion')
    patch = []
    for row in overlay + exclude:
        before_path = old / 'workspace' / row['path']
        if row['beforeSHA256'] is None:
            if before_path.exists():
                raise ValueError('Expected ancestral absence changed')
            before = ''
        else:
            if sha(before_path) != row['beforeSHA256']:
                raise ValueError('Selected actual ancestral preimage changed')
            before = before_path.read_text()
        after = Path(row['source']).read_text() if 'afterSHA256' in row else ''
        patch.extend(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                     fromfile='a/' + row['path'] if row['beforeSHA256'] else '/dev/null',
                     tofile='b/' + row['path'] if 'afterSHA256' in row else '/dev/null'))
    if ''.join(patch) != (BASE / 'runtime.patch').read_text():
        raise ValueError('Exact 50-entry review patch differs')
    additions = sum(r['beforeSHA256'] is None for r in overlay)
    if len(source) + additions - len(exclude) != v['expectedSourceCount'] or v['expectedSourceCount'] != 3060:
        raise ValueError('Wrong composed inventory count')
    probe = json.loads((Path(v['probe']) / 'integration.json').read_bytes())['files']
    actual = {r['path']: r for r in overlay}
    if len(probe) != 22:
        raise ValueError('Wrong frozen probe/facade inventory')
    for row in probe:
        if actual[row['path']]['afterSHA256'] != row['afterSHA256']:
            raise ValueError('Frozen probe/facade source changed')
    if len([r for r in overlay if '/DarkbloomClusterSecurity/' in r['path']]) != 8:
        raise ValueError('Incomplete actual Security implementation')
    if len([r for r in overlay if '/lib/jaccl/' in r['path']]) != 4:
        raise ValueError('Incomplete tail-clearing source')
    if len([r for r in overlay if r['reason'].startswith('restore exact MAIN model/worker')]) != 9:
        raise ValueError('Incomplete explicit private-model restoration')
    commands = (BASE / 'build_native.py').read_text()
    defines = [node.value for node in ast.walk(ast.parse(commands))
               if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value.startswith('-D')]
    if defines != ['-DCOLLECTIVE_RECORD_ALLOCATION_CHECK'] or 'run-resource-case' in commands:
        raise ValueError('Unexpected build define or GPU mode')
    if len(expected_cases()) != 35 or (BASE / 'workspace').exists():
        raise ValueError('Wrong catalog or source check attempted after materialization')
    print(json.dumps(dict(pythonSyntax=True, exactHelpers=True, exactPatchReplay=True,
                         frozenProbeAndFacadeFiles=22, explicitMainRestorations=9,
                         securitySources=8, nativeTailSources=4, selectedCompositionEntries=50,
                         overlayFiles=45, excludedFiles=5, baseSources=3040, expectedSources=3060,
                         dependencyMetadataFiles=8755, pureCatalogCases=35, workspaceMaterialized=False,
                         cacheCloned=False, compilerExecuted=False, nativeExecuted=False), sort_keys=True))


if __name__ == '__main__':
    main()
