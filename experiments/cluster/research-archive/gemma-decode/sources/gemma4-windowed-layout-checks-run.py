"""One bounded Foundation layout check; no native model or remote execution."""
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent / 'd-inference'
DRAFT = ROOT / 'gemma4-windowed-request-state-draft-20260915'
SUPPORT = REPO / 'libs/darkbloom-cluster/Tests/SecurityChecks'
sys.path.insert(0, str(SUPPORT))
from run import run_owned


def main():
    output = ROOT / 'gemma4-windowed-layout-checks-1-20260915'
    output.mkdir(mode=0o700)
    runtime = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    sources = [DRAFT / 'proposed' / runtime / 'LayerAttentionStateLayout.swift',
               REPO / runtime / 'ClusterMetadataHashing.swift',
               REPO / runtime / 'ClusterRuntimeError.swift', DRAFT / 'Tests/LayoutCheck.swift']
    paths = sources + [DRAFT / 'Tests/config.json', SUPPORT / 'run.py', SUPPORT / 'owned_process.py', Path(__file__).resolve()]
    def snapshot():
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    before = snapshot()
    (output / 'source-snapshot.json').write_text(json.dumps(before, indent=2, sort_keys=True) + '\n')
    (output / 'module-cache').mkdir()
    binary = output / 'layout-check'
    try:
        build = run_owned(['xcrun', 'swiftc', '-j', '2', '-swift-version', '6', '-warnings-as-errors',
            '-target', 'arm64-apple-macos14.0', '-parse-as-library', '-module-cache-path', str(output / 'module-cache')]
            + list(map(str, sources)) + ['-o', str(binary)], output, 'compile', 60)
        if snapshot() != before:
            raise ValueError('Source changed during compilation')
        check = run_owned([str(binary), str(DRAFT / 'Tests/config.json')], output, 'fixture', 10)
    finally:
        if snapshot() != before:
            raise ValueError('Source changed during layout check')
    (output / 'checks.json').write_text(json.dumps({'passed': True, 'compile': build,
        'fixture': check, 'sourceUnchanged': True, 'nativeModelExecuted': False}, indent=2) + '\n')
    print((output / 'fixture.stdout').read_text(), end='')


if __name__ == '__main__':
    os.umask(0o077)
    main()
