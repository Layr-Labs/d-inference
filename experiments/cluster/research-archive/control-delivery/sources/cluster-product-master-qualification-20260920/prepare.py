"""Root-invoked APFS-only scratch preparation; never alters either source workspace."""
import ctypes
import json
import os
import subprocess
import sys
from pathlib import Path
from common import BASE, RUN, WORKSPACE, PACKAGES, inputs, read, require, save, sha, source_contract
from inventory import inventory, checkout_inventory, closure


def clone_sources(source, destination):
    clone = ctypes.CDLL(None, use_errno=True).clonefile
    clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    clone.restype = ctypes.c_int
    for rel in PACKAGES:
        for parent, dirs, files in os.walk(source / rel, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in ('.git', '.build', '__pycache__'))
            target = destination / Path(parent).relative_to(source)
            target.mkdir(parents=True, exist_ok=True)
            for directory in dirs:
                require(not (Path(parent) / directory).is_symlink(), 'Directory symlink outside clone contract')
            for name in sorted(files):
                if name == '.git':
                    continue
                src, dst = Path(parent) / name, target / name
                if src.is_symlink():
                    src.resolve(strict=True).relative_to(source)
                    link = os.readlink(src)
                    require(not os.path.isabs(link), 'Absolute source symlink outside clone contract')
                    dst.symlink_to(link)
                else:
                    require(src.is_file() and clone(os.fsencode(src), os.fsencode(dst), 0) == 0, 'APFS source clone refused: ' + str(src))


def relocate(value, old, new):
    if isinstance(value, str):
        return new + value[len(old):] if value == old or value.startswith(old + '/') else value
    if isinstance(value, list):
        return [relocate(x, old, new) for x in value]
    if isinstance(value, dict):
        return {k: relocate(v, old, new) for k, v in value.items()}
    return value


def validate_locked_state(state, resolved):
    expected = {r['identity']: r['state']['revision'] for r in resolved['pins']}
    actual = {}
    for dep in state['object']['dependencies']:
        if dep['state']['name'] == 'sourceControlCheckout':
            name = dep['packageRef']['identity']
            require(name not in actual, 'Duplicate cached dependency')
            actual[name] = dep['state']['checkoutState']['revision']
    require(actual == expected, 'Cache does not match every Package.resolved revision')


def main():
    require(len(sys.argv) == 2 and Path(sys.argv[1]) == RUN / 'prepare', 'Exact root output required')
    output = Path(sys.argv[1])
    contract = inputs()
    source, old = Path(contract['sourceWorkspace']), Path(contract['cacheWorkspace'])
    require(not WORKSPACE.exists(), 'Scratch workspace already exists')
    source_contract(source, git_heads=True)
    for row in read(BASE / 'coordinator-context.json'):
        require(sha(source / row['path']) == row['sha256'], 'Intended common coordinator composition differs: ' + row['path'])
    closure(source)
    require(sha(old / 'provider-swift/Package.resolved') == contract['packageResolvedSHA256'], 'Cache lock differs')
    state_path = old / 'provider-swift/.build/workspace-state.json'
    require(sha(state_path) == contract['cacheStateSHA256'], 'Retained cache metadata changed')
    state = read(state_path)
    validate_locked_state(state, read(source / 'provider-swift/Package.resolved'))
    before = inventory(source, checkouts=False)
    dependencies = checkout_inventory(old)
    require(dependencies == read(BASE / 'cache-dependencies.json'), 'Cache checkout bytes differ from the prior qualified context')
    save(output / 'source-before.json', before)
    save(output / 'dependencies-before.json', dependencies)
    WORKSPACE.mkdir(mode=0o700)
    clone_sources(source, WORKSPACE)
    require(inventory(WORKSPACE, checkouts=False) == before, 'Source clone differs')
    command = ['/bin/cp', '-cR', str(old / 'provider-swift/.build'), str(WORKSPACE / 'provider-swift/.build')]
    subprocess.run(command, check=True, timeout=180)
    require(checkout_inventory(WORKSPACE) == dependencies, 'Cloned dependency bytes differ')
    target_state = WORKSPACE / 'provider-swift/.build/workspace-state.json'
    require(sha(target_state) == contract['cacheStateSHA256'], 'Cloned SwiftPM metadata differs')
    with (output / 'cache-state-original.json').open('xb') as stream:
        stream.write(target_state.read_bytes())
    target_state.write_text(json.dumps(relocate(state, str(old), str(WORKSPACE)), indent=2, sort_keys=True) + '\n')
    closure(WORKSPACE)
    source_contract(WORKSPACE)
    expected = dict(before, **dependencies)
    require(inventory(WORKSPACE) == expected, 'Scratch compilation closure differs')
    require(inventory(source, checkouts=False) == before and checkout_inventory(old) == dependencies and sha(state_path) == contract['cacheStateSHA256'], 'Original source/cache changed during clone')
    save(output / 'candidate.json', expected)
    save(output / 'prepared.json', dict(passed=True, manifestSHA256=sha(BASE / 'manifest.json'), candidateSHA256=sha(output / 'candidate.json'), sourceFiles=len(before), dependencyFiles=len(dependencies), cacheStateSHA256=sha(target_state), cacheCloneCommand=command, originalSourceAndCacheUnchanged=True, compilerExecuted=False))


if __name__ == '__main__':
    os.umask(0o077)
    main()
