"""Read/source checks only; never executes a helper, process or model."""
import ast
import hashlib
import json
from pathlib import Path
import re

D = Path(__file__).resolve().parent
REPO = Path('/Users/developer/DarkbloomDev/d-inference')
NATIVE = REPO / 'experiments/cluster/inference/Sources/ClusterInference'


def pin(path):
    raw = path.read_bytes()
    return dict(path=str(path), sizeBytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def assignment(path, name):
    for node in ast.parse(path.read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise AssertionError('Assignment missing: ' + name)


def run():
    sources = sorted(D.glob('*.py'))
    for p in sources:
        ast.parse(p.read_text(), feature_version=(3, 9))
    helpers = assignment(D/'run_selected_stage_load.py', 'HELPERS')
    for name, expected in helpers.items():
        assert pin(D/name)['sha256'] == expected
    old = assignment(D/'originals/run_dense_constructor_probe_v2.py', 'PROFILES')
    # Evaluate only this pure contract module (it contains no execution calls).
    scope = {}
    exec(compile((D/'stage_load_contract.py').read_text(), 'stage_load_contract.py', 'exec'), scope)
    for name, profile in scope['PROFILES'].items():
        for key in ('configuration', 'manifest', 'artifact', 'canonicalTensorCount'):
            assert profile[key] == old[name][key]
    report = (NATIVE/'QwenDenseStageLoadProbe.swift').read_text().split('/// The only return')[0]
    fields = set(re.findall(r'(?:\blet\s+|,\s*)(\w+)\s*(?:=|:)', report))
    assert fields == scope['REPORT_KEYS'], (fields-scope['REPORT_KEYS'], scope['REPORT_KEYS']-fields)
    cli = (NATIVE/'QwenDenseStageLoadCLI.swift').read_text()
    assert 'arguments.count == 10' in cli and '"--stage-index"' in cli and '"qwen-dense-stage-load-check"' in cli
    entry = (NATIVE/'QwenDenseStageLoadEntry.swift').read_text()
    assert 'data.count < 8 * 1_048_576' in entry and 'data.append(10)' in entry
    names = ['QwenDenseStageLoadCLI.swift','QwenDenseStageLoadEntry.swift','QwenDenseStageLoadProbe.swift',
        'QwenDenseStageLoadBudget.swift','QwenDenseStageLoadPolicy.swift','QwenDenseStageLoadResources.swift',
        'QwenDenseSelectedStageLoading.swift','VerifiedQwenLayerStageLoading.swift','VerifiedCheckpoint.swift',
        'QwenLayerStageInventoryTypes.swift','QwenDenseRegisteredSpecification.swift']
    # The selected owner filename is obtained from source, not a candidate.
    if not (NATIVE/names[6]).exists():
        matches = [p.name for p in NATIVE.glob('*.swift') if 'private final class QwenDenseStageLoadGate' in p.read_text()]
        assert len(matches) == 1
        names[6] = matches[0]
    return dict(kind='private_selected_stage_parent_source_checks', passed=True, python39Files=len(sources),
        sharedHelpersByteIdentical=helpers, originalRegisteredPinsUnchanged=True,
        actualNativeReportKeysEqual=True, nativeSources=[pin(NATIVE/name) for name in names],
        runtimeSources=[pin(REPO/'experiments/cluster/runtime'/name) for name in ['bundle.py','artifacts.py','rank_worker.py']],
        parentSources=[pin(p) for p in sources], nativeOrHelperProcessExecuted=False,
        candidateOrModelPayloadAccessed=False)


if __name__ == '__main__':
    print(json.dumps(run(), sort_keys=True, indent=2))
