"""Prospective bounded Foundation checks. Requires the root's compiler slot."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import sys

BASE = Path(__file__).resolve().parent.parent
MAIN = Path('/Users/developer/DarkbloomDev/d-inference')
CHECKS = MAIN / 'libs/darkbloom-cluster/Tests/StageMetadataChecks'
FORWARD = BASE.parent / 'gemma4-registered-forward-draft-20260916'
WINDOW = BASE.parent / 'gemma4-windowed-state-build-20260916/workspace'


def pin(path):
    raw = path.read_bytes()
    return {'path': str(path), 'sizeBytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def verify_inputs():
    controls = json.loads((BASE / 'source-controls.json').read_text())
    for item in controls['files']:
        if pin(Path(item['path'])) != item:
            raise ValueError('Dependency changed: ' + item['path'])
    manifest = json.loads((BASE / 'manifest.json').read_text())
    for item in manifest['members']:
        actual = pin(BASE / item['path'])
        if actual['sizeBytes'] != item['bytes'] or actual['sha256'] != item['sha256']:
            raise ValueError('Private member changed: ' + item['path'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    verify_inputs()
    sys.path.insert(0, str(CHECKS))
    spec = importlib.util.spec_from_file_location('qualified_stage_metadata_runner', CHECKS / 'run.py')
    old = importlib.util.module_from_spec(spec); spec.loader.exec_module(old)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    snapshot = old.prepare_snapshot(output)
    sources = [Path(p) for p in snapshot['swiftSources'] if p != str(CHECKS / 'Main.swift')]
    runtime = MAIN / 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    additions = [FORWARD / 'proposed/Gemma4ForwardSelection.swift', FORWARD / 'Tests/Gemma4ForwardSelectionCheck.swift',
        BASE / 'proposed/Gemma4ShortResourceBudget.swift', BASE / 'proposed/Gemma4OrderedLoadProgress.swift',
        BASE / 'Tests/Main.swift', BASE / 'Tests/Gemma4ShortBudgetCheck.swift', BASE / 'Tests/Gemma4OrderedLoadCheck.swift',
        runtime / 'QwenLayerStageGenerationRequest.swift', runtime / 'QwenLayerStageSchedule.swift',
        runtime / 'QwenLayerStageWireExpectation.swift',
        WINDOW / 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/LayerAttentionStateLayout.swift']
    sources += additions
    if len(sources) != 34 or len(set(sources)) != len(sources):
        raise ValueError('Unexpected exact Foundation source closure')
    snapshot['swiftSources'] = [str(p) for p in sources]
    snapshot['files'] += [pin(p) for p in additions + [BASE / 'ledger.json', Path(__file__), BASE / 'manifest.json', BASE / 'source-controls.json']]
    (output / 'source-snapshot.json').write_text(json.dumps(snapshot, indent=2, sort_keys=True) + '\n')
    os.chdir(CHECKS)
    (output / 'module-cache').mkdir(mode=0o700)
    binary = output / 'gemma-short-resource-check'
    command = ['xcrun', 'swiftc', '-j', '2', '-swift-version', '6', '-warnings-as-errors',
        '-target', platform.machine() + '-apple-macos14.0', '-parse-as-library',
        '-module-cache-path', str(output / 'module-cache')] + snapshot['swiftSources'] + ['-o', str(binary)]
    compiled = old.run_owned(command, output, 'compile', 60)
    old.verify_snapshot(snapshot); verify_inputs()
    fixture = old.run_owned([str(binary), str(CHECKS / 'Inputs'), str(BASE / 'ledger.json')], output, 'fixture', 10)
    old.verify_snapshot(snapshot); verify_inputs()
    result = json.loads((output / 'fixture.stdout').read_text())
    if (output / 'fixture.stderr').stat().st_size or result['runtimeExecutionAuthorized'] or result['actualAllocatorBoundsObserved']:
        raise ValueError('Unexpected fixture diagnostics or native claim')
    (output / 'checks.json').write_text(json.dumps({'compile': compiled, 'fixture': fixture,
        'acceptedCount': result['acceptedCount'], 'refusedCount': result['refusedCount'],
        'sourceUnchanged': True, 'modelConstructed': False, 'payloadRead': False,
        'actualAllocatorBoundsObserved': False}, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
