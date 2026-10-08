#!/usr/bin/env python3
"""Copy the existing dirty source/cache closure, then apply the frozen overlay."""
import hashlib, json, os, re, subprocess, sys, time
from pathlib import Path

PLAN = Path(__file__).resolve().parent
PACKAGES = ('provider-swift', 'libs/darkbloom-cluster', 'libs/mlx-swift', 'libs/mlx-swift-lm')

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')

def inventory(root):
    result = {}
    roots = [root / x for x in PACKAGES] + [root / 'provider-swift/.build/checkouts']
    for base in roots:
        for parent, dirs, files in os.walk(base, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in ('.git', '.build'))
            for name in sorted(files):
                if name == '.git':
                    continue
                path = Path(parent) / name
                if path.is_symlink():
                    path.resolve(strict=True).relative_to(root)
                    result[str(path.relative_to(root))] = {'symlink': os.readlink(path), 'sha256': sha(path)}
                else:
                    result[str(path.relative_to(root))] = {'sha256': sha(path)}
    return result

def closure(root):
    seen, pending = set(), ['provider-swift']
    while pending:
        rel = pending.pop()
        if rel in seen:
            continue
        seen.add(rel)
        package = root / rel
        for value in re.findall(r'\.package\(\s*path:\s*"([^"]+)"', (package / 'Package.swift').read_text()):
            target = (package / value).resolve(strict=True)
            pending.append(str(target.relative_to(root)))
    assert seen == set(PACKAGES), seen
    return sorted(seen)

def replace_paths(value, old, new):
    if isinstance(value, str):
        return new + value[len(old):] if value == old or value.startswith(old + '/') else value
    if isinstance(value, list):
        return [replace_paths(v, old, new) for v in value]
    if isinstance(value, dict):
        return {k: replace_paths(v, old, new) for k, v in value.items()}
    return value

def main():
    source, output = (Path(x).resolve() for x in sys.argv[1:])
    assert len(sys.argv) == 3
    output.mkdir(exist_ok=False)
    workspace = output / 'workspace'
    workspace.mkdir()
    integration = json.loads((PLAN / 'integration.json').read_text())
    for frozen in integration['frozenInputs']:
        path = Path(frozen['path'])
        assert sha(path) == frozen['sha256']
        for item in json.loads(path.read_text())['members']:
            assert sha(path.parent / item['path']) == item['sha256'], item['path']
    for item in integration['files']:
        path = source / item['path']
        assert (sha(path) if path.exists() else None) == item['baseSHA256'], item['path']
        assert sha(PLAN / 'proposed' / item['path']) == item['sha256']
    local_packages = closure(source)
    before = inventory(source)
    save(output / 'main-source-before.json', before)
    print(f'Pinned {len(before)} source/dependency files; cloning four package directories.', flush=True)
    copies = []
    for rel in PACKAGES:
        src, dst = source / rel, workspace / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        command = ['/bin/cp', '-cR', str(src), str(dst)]
        began = time.monotonic()
        subprocess.run(command, check=True)
        copies.append({'command': command, 'seconds': time.monotonic() - began})
        print(f'Cloned {rel}', flush=True)
    assert inventory(workspace) == before, 'APFS source/dependency clone differs'
    assert inventory(source) == before, 'MAIN changed during preparation'
    assert closure(workspace) == local_packages
    # The copied cache contains absolute paths to local packages/artifacts.
    # Relocate only private SwiftPM metadata, retaining its original bytes.
    state = workspace / 'provider-swift/.build/workspace-state.json'
    (output / 'workspace-state-original.json').write_bytes(state.read_bytes())
    save(state, replace_paths(json.loads(state.read_text()), str(source), str(workspace)))
    for item in integration['files']:
        target = workspace / item['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((PLAN / 'proposed' / item['path']).read_bytes())
    expected = dict(before)
    for item in integration['files']:
        expected[item['path']] = {'sha256': item['sha256']}
    observed = inventory(workspace)
    assert observed == expected, 'Combined overlay differs beyond the 20 files'
    save(output / 'candidate-source-before.json', observed)
    for name, args in [('main-status-before.txt', ['git', 'status', '--short']),
                       ('main-tracked-before.patch', ['git', 'diff', '--binary']),
                       ('main-staged-before.patch', ['git', 'diff', '--cached', '--binary'])]:
        (output / name).write_bytes(subprocess.check_output(args, cwd=source))
    receipt = {'source': str(source), 'workspace': str(workspace), 'localPackageClosure': local_packages,
               'copyCommands': copies, 'sourceDependencyFileCount': len(before),
               'exactCopyVerifiedBeforeOverlay': True, 'only20OverlayFilesChanged': True,
               'combinedOverlayFiles': integration['files'],
               'privateWorkspaceStateSHA256': sha(state), 'mainSourceUnchanged': True,
               'sourcePinsSHA256': sha(output / 'candidate-source-before.json'), 'compilerRun': False}
    save(output / 'preparation.json', receipt)
    print(json.dumps({'preparationSHA256': sha(output / 'preparation.json'),
                      'candidateFiles': len(observed), 'workspace': str(workspace)}, indent=2), flush=True)

if __name__ == '__main__':
    main()
