"""Rebuild only the local Foundation controller and its coherent four modules."""
from pathlib import Path
import json
import sys
from run_checks import BASE, invoke, sha


def main():
    attempt, = sys.argv[1:]
    assert attempt.isdecimal()
    run = BASE / ('local-build-' + attempt)
    run.mkdir()
    paths = sorted((BASE / 'proposed').rglob('*.swift'))
    paths += [BASE / 'build_local_controller.sh', BASE / 'run_checks.py', Path(__file__).resolve()]
    pins = [{'path': str(path.relative_to(BASE)), 'bytes': path.stat().st_size, 'sha256': sha(path)} for path in paths]
    (run / 'source-pins.json').write_text(json.dumps(pins, indent=2) + '\n')
    code = invoke(run, 'build', ['/bin/bash', str(BASE / 'build_local_controller.sh'), str(run / 'artifacts')], 180)
    unchanged = all((BASE / pin['path']).stat().st_size == pin['bytes'] and sha(BASE / pin['path']) == pin['sha256'] for pin in pins)
    (run / 'execution.json').write_text(json.dumps({'exitCode': code, 'sourcePinsUnchanged': unchanged,
        'remoteOwnerOrNativeChanged': False, 'nativeModelOrNetworkExecution': False}, indent=2) + '\n')
    assert unchanged
    return code


if __name__ == '__main__':
    sys.exit(main())
