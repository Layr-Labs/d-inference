"""Small source-only inverse/pin checks, without compiling or loading MLX."""
from pathlib import Path
import ast
import hashlib
import json

BASE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    for row in json.loads((BASE / 'manifest.json').read_bytes())['members']:
        path = BASE / row['path']
        assert not path.is_symlink() and path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
    controls = json.loads((BASE / 'controls.json').read_bytes())
    for row in controls['files']:
        path = Path(row['path'])
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
    assert sha(BASE / 'Tests/owned_process.py') == controls['helper']['sha256'] == sha(Path(controls['helper']['path']))
    dto = controls['dtoPrefix']
    assert (BASE / 'Tests/Gemma4ControlDTOs.swift').read_text() == Path(dto['path']).read_text().split(dto['splitBefore'])[0]
    for row in json.loads((BASE / 'integration.json').read_bytes())['files']:
        assert sha(Path(row['sourcePath'])) == row['afterSHA256']
        if row['beforeSHA256'] is not None:
            assert sha(BASE / 'original' / row['path']) == row['beforeSHA256']
    command = json.loads((BASE / 'Tests/compile-command.json').read_bytes())
    assert command[command.index('-j') + 1] == '2'
    assert len(json.loads((BASE / 'Tests/expected-checks.json').read_bytes())) == 18
    wire = (BASE / 'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Gemma4BenchmarkWire.swift').read_text()
    original = (BASE / 'original/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Gemma4BenchmarkWire.swift').read_text()
    # All operation/ACK/token handling after require remains byte-for-byte exact.
    suffix = '    func require(_ expected:'
    assert wire.split(suffix)[1] == original.split(suffix)[1]
    assert wire.count('try group.sendCompleted(') == 1 and wire.count('try group.receiveCompleted(') == 1
    assert 'Gemma4BenchmarkWireCodec.decode(data, scope: input.scopeSHA256, sender: 1-rank, ordinal: received)' in wire
    print(json.dumps(dict(status='passed', overlays=3, unchangedControls=8, stagedFoundationGroups=18,
                          compilerExecuted=False, nativeExecuted=False), sort_keys=True))


if __name__ == '__main__':
    main()
