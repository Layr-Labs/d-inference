"""Load only this package's frozen numerical oracle, never archived launcher code."""
import types
import sys
from pathlib import Path
import tempfile
from binding_common import parse, require, sha
from binding_inputs import snapshot

HERE = Path(__file__).resolve().parent
PINS = {
    'audit_short_parity.py': 'b772a62396d7b8a792e9ed200ab6efb9ed0a68231dcd7c7e92c02465923a7b98',
    'recorded_math.py': 'f166a6a27c20021c30c62e6966e63583b9ecab955a3b23af64869cd821f25914',
    'short_parity_contract.py': '10f2e6c4b82b3c441e7c06ea183c249cb6f0454c93a3b623fe423f4345fecfcb',
    'stage_load_contract.py': '8102af85633e949d53d81de605b1e8edd65792ecb47afe75cf7c5b49473e2d83',
}


_MODULES = {}
_OWNED_DIRECTORY = None


def load():
    global _OWNED_DIRECTORY
    root = HERE / 'oracle'
    snapshots = {name:snapshot(root / name, 65536) for name in PINS}
    for name, expected in PINS.items():
        require(snapshots[name]['sha256'] == expected, 'Frozen oracle changed')
    names = ('stage_load_contract', 'short_parity_contract', 'recorded_math', 'audit_short_parity')
    if _MODULES:
        require(all(sys.modules.get(name) is _MODULES[name] for name in names), 'Oracle module identity changed')
        for name, expected in PINS.items():
            require(snapshot(Path(_OWNED_DIRECTORY.name) / name, 65536)['sha256'] == expected,
                    'Owned oracle snapshot changed')
    else:
        require(all(name not in sys.modules for name in names), 'Conflicting oracle module already loaded')
        owned = tempfile.TemporaryDirectory(prefix='short-binding-oracle-')
        try:
            for name, item in snapshots.items():
                path = Path(owned.name) / name
                with path.open('xb') as stream:
                    stream.write(item['raw'])
                path.chmod(0o400)
            for name in names:
                filename = name + '.py'
                module = types.ModuleType(name)
                # The unchanged short contract reads its sibling during import.
                # Point that check at owned copies, never reopen caller bytes.
                module.__file__ = str(Path(owned.name) / filename)
                module.__package__ = ''
                module.__cached__ = None
                sys.modules[name] = module
                _MODULES[name] = module
                exec(compile(snapshots[filename]['raw'], str(root / filename), 'exec'), module.__dict__)
            _OWNED_DIRECTORY = owned
        except BaseException:
            for name, module in _MODULES.items():
                if sys.modules.get(name) is module:
                    sys.modules.pop(name)
            _MODULES.clear()
            owned.cleanup()
            raise
    # A replacement during import cannot supply executable bytes and is refused.
    for name, expected in PINS.items():
        require(snapshot(root / name, 65536)['sha256'] == expected, 'Frozen oracle changed during import')
    return _MODULES['audit_short_parity'], _MODULES['short_parity_contract']


def tokens(core):
    result = {}
    for role, count in (('prompt', 3), ('teacher', 1)):
        item = core[role]
        ids = parse(item['raw'])
        require(type(ids) is list and len(ids) == count and all(type(n) is int and 0 <= n < 248320 for n in ids),
                'Wrong bounded token history: ' + role)
        result[role] = dict(sizeBytes=item['size_bytes'], sha256=item['sha256'], tokenIDs=ids)
    return result


def replay(core, profile, token_metadata):
    oracle, _ = load()
    raw = core['retained_metadata']['raw']
    require(sha(raw) == oracle.FIXTURE_SHA, 'Registered metadata bytes differ')
    # The frozen oracle expects a path. Give it an owned snapshot, never reopen
    # the caller's path with its older reader or use its historical default path.
    with tempfile.TemporaryDirectory(prefix='short-binding-metadata-') as folder:
        path = Path(folder) / 'metadata.json'
        with path.open('xb') as stream:
            stream.write(raw)
        path.chmod(0o400)
        return oracle.audit(core['stdout']['raw'], profile, token_metadata, fixture=path)
