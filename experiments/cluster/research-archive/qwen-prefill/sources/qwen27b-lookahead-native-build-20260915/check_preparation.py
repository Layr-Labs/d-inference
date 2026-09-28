"""Small source/inverse inspection only; never hashes a workspace, cache, native or model."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def main():
    assert not (BASE / 'workspace').exists(), 'Author preparation check precedes materialization'
    for path in list(BASE.glob('*.py')) + list((BASE / 'upstream').glob('*.py')):
        ast.parse(path.read_text())
    for name in ['prepare.py', 'owned_process.py']:
        assert (BASE / name).read_bytes() == (BASE / 'upstream' / name).read_bytes()
    before = (BASE / 'upstream/build_native.py').read_text()
    after = (BASE / 'build_native.py').read_text().replace("OLD / 'runtime-bundle-1/mlx.metallib'", "OLD / 'bundle/mlx.metallib'")
    assert after == before
    after = (BASE / 'package_native.py').read_text().replace("OLD / 'runtime-bundle-1/bundle.json'", "OLD / 'bundle/bundle.json'")
    after = after.replace('qwen27b_lookahead_native_bundle_v1', 'qwen27b_resident_load_diagnostics_native_bundle_v1')
    assert after == (BASE / 'upstream/package_native.py').read_text()
    def functions(path):
        return {node.name: ast.dump(node) for node in ast.parse(path.read_text()).body if isinstance(node, ast.FunctionDef)}
    old, new = functions(BASE / 'upstream/build_inputs.py'), functions(BASE / 'build_inputs.py')
    for name in ['sha', 'relative', 'snapshot']:
        assert old[name] == new[name]
    overlay = BASE / 'overlay/libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/NativeWorkerRuntime.swift'
    assert hashlib.sha256(overlay.read_bytes()).hexdigest() == '39272cd3f59c17e1d3d25e88c1883a8d0195aa07857432f21222dd2b78af0a84'
    print(json.dumps(dict(status='passed', sourceOnly=True, prepareAndOwnedHelperExact=True,
        buildAndPackageInverse=True, overlaySHA256=hashlib.sha256(overlay.read_bytes()).hexdigest(),
        workspaceMaterialized=False, compilerModelOrRemoteExecuted=False), sort_keys=True, indent=2))


if __name__ == '__main__':
    main()
