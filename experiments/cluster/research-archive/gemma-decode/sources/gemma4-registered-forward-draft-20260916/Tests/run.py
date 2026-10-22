"""Prospective Foundation check; run only with the scheduled compiler slot."""
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


def pin(path):
    raw = path.read_bytes()
    return {'path': str(path), 'sizeBytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def verify_inputs():
    # Bind the already qualified runner/helper and every existing Swift/input
    # dependency before importing any executable Python from that checkout.
    controls = json.loads((BASE / 'source-controls.json').read_text())
    for item in controls['foundationInputs']:
        if pin(Path(item['path'])) != item:
            raise ValueError('Foundation dependency changed: ' + item['path'])
    manifest = json.loads((BASE / 'manifest.json').read_text())
    for item in manifest['members']:
        actual = pin(BASE / item['path'])
        if actual['sizeBytes'] != item['bytes'] or actual['sha256'] != item['sha256']:
            raise ValueError('Private source changed: ' + item['path'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    verify_inputs()
    sys.path.insert(0, str(CHECKS))
    spec = importlib.util.spec_from_file_location('qualified_stage_metadata_runner', CHECKS / 'run.py')
    old = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(old)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    snapshot = old.prepare_snapshot(output)
    sources = [Path(p) for p in snapshot['swiftSources'] if p != str(CHECKS / 'Main.swift')]
    additions = [BASE / 'proposed/Gemma4ForwardSelection.swift', BASE / 'Tests/Main.swift',
                 BASE / 'Tests/Gemma4ForwardSelectionCheck.swift']
    sources += additions
    if len(sources) != 26:
        raise ValueError('Unexpected exact Foundation closure')
    snapshot['swiftSources'] = [str(p) for p in sources]
    snapshot['files'] += [pin(p) for p in additions + [Path(__file__), BASE / 'manifest.json', BASE / 'source-controls.json']]
    (output / 'source-snapshot.json').write_text(json.dumps(snapshot, indent=2, sort_keys=True) + '\n')
    os.chdir(CHECKS)
    (output / 'module-cache').mkdir(mode=0o700)
    binary = output / 'gemma-forward-selection-check'
    command = ['xcrun', 'swiftc', '-j', '2', '-swift-version', '6', '-warnings-as-errors',
               '-target', platform.machine() + '-apple-macos14.0', '-parse-as-library',
               '-module-cache-path', str(output / 'module-cache')] + snapshot['swiftSources'] + ['-o', str(binary)]
    compiled = old.run_owned(command, output, 'compile', 60)
    old.verify_snapshot(snapshot); verify_inputs()
    checked = old.run_owned([str(binary), str(CHECKS / 'Inputs')], output, 'fixture', 10)
    old.verify_snapshot(snapshot); verify_inputs()
    result = json.loads((output / 'fixture.stdout').read_text())
    if (output / 'fixture.stderr').stat().st_size or result['runtimeExecutionAuthorized']:
        raise ValueError('Unexpected fixture diagnostics or authorization claim')
    (output / 'checks.json').write_text(json.dumps({'compile': compiled, 'fixture': checked,
        'acceptedCount': result['acceptedCount'], 'refusedCount': result['refusedCount'],
        'sourceUnchanged': True, 'modelConstructed': False, 'payloadRead': False}, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
