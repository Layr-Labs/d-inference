"""Foundation children only; execute after a separately granted compiler slot."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
from check_process import run_owned

HERE = Path(__file__).resolve().parent


def pin(path):
    raw = path.read_bytes()
    return {'path': str(path), 'sizeBytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--checkout', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.checkout.resolve(), args.output.resolve()
    out.mkdir(mode=0o700, parents=False, exist_ok=False)
    cluster = root / 'libs/darkbloom-cluster/Sources'
    names = ['DarkbloomClusterProtocol', 'DarkbloomClusterBootstrap', 'DarkbloomClusterProcess', 'DarkbloomClusterRemote']
    sources = {name: sorted((cluster / name).glob('*.swift')) for name in names}
    if any(not values for values in sources.values()):
        raise ValueError('Incomplete current shared module source closure')
    all_sources = [p for values in sources.values() for p in values] + sorted((HERE / 'Children').glob('*.swift'))
    before = [pin(p) for p in all_sources]
    (out / 'source-snapshot.json').write_text(json.dumps(before, indent=2) + '\n')
    flags = ['xcrun', 'swiftc', '-j', '2', '-swift-version', '6', '-warnings-as-errors',
             '-target', platform.machine() + '-apple-macos14.0', '-module-cache-path', str(out / 'module-cache')]
    links = ['-I', str(out), '-L', str(out), '-Xlinker', '-rpath', '-Xlinker', str(out)]
    dependencies = {'DarkbloomClusterProtocol': [], 'DarkbloomClusterBootstrap': [],
                    'DarkbloomClusterProcess': ['DarkbloomClusterProtocol'],
                    'DarkbloomClusterRemote': ['DarkbloomClusterProtocol', 'DarkbloomClusterBootstrap', 'DarkbloomClusterProcess']}
    receipts = []
    for name in names:
        command = flags + links + ['-emit-library', '-emit-module', '-enable-testing', '-module-name', name,
            '-emit-module-path', str(out / (name + '.swiftmodule'))]
        command += ['-l' + value for value in dependencies[name]] + [str(p) for p in sources[name]]
        command += ['-o', str(out / ('lib' + name + '.dylib')), '-Xlinker', '-install_name', '-Xlinker', '@rpath/lib' + name + '.dylib']
        receipts.append(run_owned(command, out, 'compile-' + name, 60))
    for name, inputs in [('InstalledProbeFixture', ['InstalledProbeFixture.swift']),
                         ('InstalledFakeOwner', ['InstalledFixtureIdentity.swift', 'InstalledFakeOwner.swift']),
                         ('InstalledFakeWorker', ['InstalledFixtureIdentity.swift', 'FakeClusterWorker.swift'])]:
        command = flags + links + ['-parse-as-library'] + ['-l' + value for value in names]
        command += [str(HERE / 'Children' / path) for path in inputs] + ['-o', str(out / name)]
        receipts.append(run_owned(command, out, 'compile-' + name, 30))
    if before != [pin(p) for p in all_sources]:
        raise ValueError('Compilation inputs changed')
    (out / 'checks.json').write_text(json.dumps({'compiled': True, 'sourcePinsUnchanged': True,
        'processes': receipts, 'nativeModelExecuted': False}, indent=2) + '\n')


if __name__ == '__main__':
    main()
