"""Separate pinned resident/reference ancestries. Imports perform no work."""
import hashlib
import json
import os
from pathlib import Path

BASE = Path(__file__).resolve().parent
DRAFT = BASE.parent / 'qwen27b-structural-cut-validation-draft-20260916'
DRAFT_SHA = '32eeb9b524b16fb2551d6faf7bd7dd1db1c84c7480287853173bdad544539121'
METALLIB_SHA = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'


def require(value, message):
    if not value:
        raise RuntimeError(message)


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            h.update(block)
    return h.hexdigest()


def write(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')


def pin(path):
    return dict(path=str(path), bytes=path.stat().st_size, sha256=sha(path))


def checked(row):
    require(pin(Path(row['path'])) == row, 'Pinned input changed: ' + row['path'])


def authority(role):
    require(role in {'resident', 'reference'}, 'Expected resident or reference')
    require(sha(DRAFT / 'manifest.json') == DRAFT_SHA, 'Structural cut source manifest changed')
    for row in json.loads((DRAFT / 'manifest.json').read_bytes())['files']:
        path = DRAFT / row['path']
        require(path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], 'Structural source member changed')
    for row in json.loads((BASE / 'manifest.json').read_bytes())['files']:
        path = BASE / row['path']
        require(path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], 'Build source member changed')
    plan = json.loads((DRAFT / 'native-qualification-plan.json').read_bytes())
    spec = plan['ancestors'][role]
    for name in ['sourceSnapshot', 'dependencySnapshot', 'bundleManifest', 'definitionPreimage']:
        checked(spec[name])
    return spec


def paths(role):
    spec = authority(role)
    root = Path(spec['privateDestination'])
    work = root / 'workspace'
    package = work / ('libs/darkbloom-cluster-worker' if role == 'resident' else 'experiments/cluster/inference')
    cache = package / ('.build-native-worker' if role == 'resident' else '.build')
    binary = cache / 'arm64-apple-macosx/release' / ('darkbloom-cluster-worker' if role == 'resident' else 'cluster-inference')
    return spec, root, work, package, cache, binary


def source_snapshot(root, role):
    # Exact two inherited inventory conventions; never fuse their dependencies.
    rows = [] if role == 'resident' else {}
    for current, directories, names in os.walk(root, followlinks=False):
        if role == 'resident':
            directories[:] = sorted(x for x in directories if x not in {'.git', '__pycache__'} and not x.startswith('.build'))
        else:
            directories[:] = sorted(x for x in directories if x not in {'.git', '.build', '__pycache__'})
        for name in sorted(names):
            if name == '.git' or (role == 'resident' and name == '.DS_Store'):
                continue
            path = Path(current) / name
            relative = str(path.relative_to(root))
            if role == 'resident':
                row = dict(path=relative)
                if path.is_symlink():
                    row['symlink'] = os.readlink(path)
                else:
                    row.update(bytes=path.stat().st_size, sha256=sha(path))
                rows.append(row)
            elif not path.is_symlink():
                rows[relative] = sha(path)
    return sorted(rows, key=lambda x: x['path']) if role == 'resident' else rows


def link_snapshot(root):
    links = {}
    for current, directories, names in os.walk(root, followlinks=False):
        directories[:] = sorted(x for x in directories if x not in {'.git', '__pycache__'} and not x.startswith('.build'))
        for name in directories + names:
            path = Path(current) / name
            if path.is_symlink():
                links[str(path.relative_to(root))] = os.readlink(path)
    return links


def retained(spec, key, role):
    value = json.loads(Path(spec[key]).read_bytes()) if isinstance(spec[key], str) else json.loads(Path(spec[key]['path']).read_bytes())
    return value['members'] if role == 'resident' else value


def overlays(role, spec):
    rows = [(spec['sourceTarget'], DRAFT / spec['definitionOverlay'], Path(spec['definitionPreimage']['path']))]
    if role == 'reference':
        value = spec['testOnlyOverlay']
        rows.append((value['target'], DRAFT / value['source'],
                     Path(spec['workspaceAncestor']) / value['target']))
    return rows


def verify_ancestor(role, spec):
    original = Path(spec['workspaceAncestor'])
    sources = retained(spec, 'sourceSnapshot', role)
    dependencies = retained(spec, 'dependencySnapshot', role)
    require(len(sources) == spec['sourceCount'] and len(dependencies) == spec['dependencyCount'], 'Ancestry member count differs')
    require(source_snapshot(original, role) == sources, 'Original source snapshot changed')
    require(source_snapshot(Path(spec['cacheAncestor']) / 'checkouts', role) == dependencies, 'Original dependency snapshot changed')
    links = json.loads((BASE / 'source-links.json').read_bytes())[role]
    require(link_snapshot(original) == links, 'Original source links changed')
    return sources, dependencies, links


def verify_prepared(role):
    spec, root, work, package, cache, binary = paths(role)
    sources, dependencies, links = verify_ancestor(role, spec)
    expected = json.loads(json.dumps(sources))
    for relative, overlay, original in overlays(role, spec):
        require((work / relative).read_bytes() == overlay.read_bytes(), 'Prepared overlay changed')
        if role == 'resident':
            row, = [row for row in expected if row['path'] == relative]
            row.update(bytes=overlay.stat().st_size, sha256=sha(overlay))
        else:
            expected[relative] = sha(overlay)
    old_work = spec['workspaceAncestor']
    new_links = {name: str(work) + value[len(old_work):] if value.startswith(old_work + '/') else value
                 for name, value in links.items()}
    if role == 'resident':
        for row in expected:
            if 'symlink' in row:
                row['symlink'] = new_links[row['path']]
    require(link_snapshot(work) == new_links, 'Prepared source links differ')
    require(source_snapshot(work, role) == expected, 'Prepared source snapshot differs')
    require(source_snapshot(cache / 'checkouts', role) == dependencies, 'Prepared dependency snapshot differs')
    return dict(role=role, sourceMembers=len(expected), dependencyMembers=len(dependencies),
                changedSourcePaths=[x[0] for x in overlays(role, spec)],
                actualSource=expected, dependencies=dependencies,
                originalSourceAndDependenciesUnchanged=True, perStageLedgerEnabled=False)
