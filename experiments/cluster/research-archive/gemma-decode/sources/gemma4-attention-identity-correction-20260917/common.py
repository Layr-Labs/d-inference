"""Fixed qualified workspace; no preparation occurs on import."""
import hashlib, importlib.util, json
from pathlib import Path

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'gemma4-short-correctness-draft-20260916' / 'build'
WORKSPACE = OLD / 'workspace'
SCRATCH = WORKSPACE / 'libs/darkbloom-cluster-worker/.build-native-worker'
BINARY = SCRATCH / 'arm64-apple-macosx/release/GemmaShortCorrectnessCheck'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def authorities():
    manifest = json.loads((BASE / 'manifest.json').read_bytes())
    for row in manifest['members']:
        path = BASE / row['path']
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Changed frozen correction member: ' + str(path))
    value = json.loads((BASE / 'inputs.json').read_bytes())
    for row in value['pins']:
        path = Path(row['path'])
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Changed authority: ' + str(path))
    for row in value['overlays']:
        path = BASE / row['source']
        if path.is_symlink() or sha(path) != row['afterSHA256']:
            raise ValueError('Changed correction source')
    return value

def inventories():
    # Exact previously qualified enumeration code, pinned before import.
    authorities()
    spec = importlib.util.spec_from_file_location('qualified_gemma_inputs', OLD / 'build_inputs.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module.entries(WORKSPACE), module.entries(SCRATCH / 'checkouts')

def expected():
    value = authorities()
    rows = {row['path']: row for row in json.loads((OLD / 'source-snapshot-1.json').read_bytes())['members']}
    for row in value['overlays']:
        path = BASE / row['source']; data = path.read_bytes()
        rows[row['path']] = dict(path=row['path'], bytes=len(data), sha256=sha(path))
    return sorted(rows.values(), key=lambda row: Path(row['path']))

def verify(prepared):
    sources, deps = inventories()
    wanted = expected() if prepared else json.loads((OLD / 'source-snapshot-1.json').read_bytes())['members']
    if sources != wanted or deps != json.loads((OLD / 'dependency-snapshot-1.json').read_bytes())['members']:
        raise ValueError('Exact Gemma source/dependency inventory changed')
    return dict(sources=len(sources), dependencies=len(deps))
