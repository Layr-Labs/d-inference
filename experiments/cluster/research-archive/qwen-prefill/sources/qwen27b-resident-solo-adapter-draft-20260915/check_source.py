"""Source/inverse checks only. Does not invoke Swift, MLX, a model or the network."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

BASE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    info = json.loads((BASE / 'lineage.json').read_bytes())
    actual = Path(info['base'])
    checks = []
    for rel, expected in info['originals'].items():
        assert digest(BASE / 'originals' / rel) == digest(actual / rel) == expected
        checks.append('exact original: ' + rel)
    for rel, expected in info['unchangedControls'].items():
        assert not (BASE / 'proposed' / rel).exists()
        assert digest(actual / rel) == expected
        checks.append('unchanged control: ' + rel)
    with tempfile.TemporaryDirectory(prefix='qwen-solo-inverse-') as temp:
        root = Path(temp)
        shutil.copytree(BASE / 'proposed', root, dirs_exist_ok=True)
        result = subprocess.run(['/usr/bin/patch', '-R', '-p1', '--batch', '-i', str(BASE / 'runtime.patch')],
                                cwd=root, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr.decode()
        restored = {str(p.relative_to(root)): digest(p) for p in root.rglob('*') if p.is_file()}
        assert restored == info['originals'], restored
        checks.append('all six patch members reverse to exact four originals')
    core = BASE / 'proposed/experiments/cluster/inference/Sources/ClusterInference'
    scope = (core / 'QwenResidentSoloModelScope.swift').read_text()
    assert 'geometry.layers - geometry.layers / geometry.fullAttentionInterval' in scope
    assert 'nativePrefillCalls == gatedDeltaLayers * 16' in scope
    assert 'nativeDecodeCalls == gatedDeltaLayers * 127' in scope
    assert 'fallbackCalls == 0, invalidGeometryCalls == 0' in scope
    cohort = (core / 'QwenResidentSoloCohort.swift').read_text()
    assert cohort.count('withQwenGatedDeltaWarmupObservation(request, profile: scope.warmupProfile)') == 1
    assert 'if ordinal == 0 {' in cohort and 'result = try request()' in cohort
    observer = (BASE / 'proposed/libs/mlx-swift-lm/Libraries/MLXLLM/Models/QwenResidentBenchmarkObservation.swift').read_text()
    assert 'profile: QwenGatedDeltaWarmupProfile = .nineB' in observer
    assert 'valueHeads == profile.valueHeads' in observer
    assert 'case .nineB: return 32' in observer and 'case .twentySevenB: return 48' in observer
    assert 'defer { qwenGatedDeltaWarmupCounter = nil }' in observer
    checks.append('closed geometry selected for warmup only; original default retained')
    assert digest(Path(info['retainedFixture']['path'])) == info['retainedFixture']['sha256']
    checks.append('bounded original retained metadata fixture exact')
    result = {'schema': 'qwen27b_solo_source_checks_v1', 'status': 'passed', 'checks': checks,
              'checkCount': len(checks), 'runtimePatchSHA256': digest(BASE / 'runtime.patch'),
              'swiftChecksExecuted': False, 'compilerExecuted': False, 'modelExecuted': False,
              'physicalQualificationEstablished': False}
    print(json.dumps(result, sort_keys=True, indent=2))


if __name__ == '__main__':
    main()
