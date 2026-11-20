"""Small-file source replay only; this does not qualify Swift or execute children."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
def sha(raw): return hashlib.sha256(raw).hexdigest()

def main():
    value = json.loads((ROOT / 'cpu-control/integration.json').read_bytes())
    patch = ''
    for row in value['changes']:
        old = (ROOT / 'cpu-control/preimages' / row['path']).read_bytes()
        new = (ROOT / 'cpu-control/proposed' / row['path']).read_bytes()
        assert sha(old) == row['beforeSHA256'] and sha(new) == row['afterSHA256']
        patch += ''.join(difflib.unified_diff(old.decode().splitlines(True), new.decode().splitlines(True),
            fromfile='a/' + row['path'], tofile='b/' + row['path']))
    assert patch.encode() == (ROOT / 'cpu-control/runtime.patch').read_bytes()
    evidence = json.loads((ROOT / 'source-evidence.json').read_bytes())
    for row in evidence['inputs']:
        raw = Path(row['path']).read_bytes()
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], row['path']
    base = ROOT / 'cpu-control/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    shim = (base / 'CollectivePointToPoint.swift').read_text()
    api = (base / 'Collective.swift').read_text()
    wire = (base / 'Gemma4BenchmarkWire.swift').read_text()
    assert 'func sendControlCompleted(_ bytes: Data,' in api
    assert 'check: () throws -> Void) throws -> Data' in api
    assert 'private static func sendInput(' in shim and 'private static func receiveArray(' in shim
    assert shim.count('fenceModelGPU: false') == 2 and shim.count('fenceModelGPU: true') == 2
    assert 'static func sendControl(_ bytes: Data,' in shim
    assert 'let input = MLXArray(bytes, [bytes.count], dtype: .uint8)' in shim
    assert 'private static let maximumControlBytes = 65_536' in shim
    assert 'try geometry.validateOwnedReceive(output)' in shim
    assert 'try requireSuccess(mlx_array_eval(array.ctx), operation: "evaluation", check: check)' in shim
    assert 'try requireSuccess(mlx_synchronize(communication.ctx), operation: "CPU completion", check: check)' in shim
    assert 'try requireSuccess(mlx_synchronize(gpu.ctx), operation: "GPU completion", check: check)' in shim
    assert 'else {\n            // Preserve the same fresh check/error checkpoint count.' in shim
    assert 'try group.sendControlCompleted(frame' in wire
    assert 'try group.receiveControlCompleted(' in wire
    ast.parse(Path(__file__).read_bytes(), filename=__file__)
    print(json.dumps(dict(schema='gemma4_cpu_control_source_check_v1', passed=True,
        exactOverlayFiles=3, exactContextPins=len(evidence['inputs']), patchReplay=True,
        swiftCompiled=False, fixtureExecuted=False, nativeExecuted=False, childExecuted=False)))

if __name__ == '__main__': main()
