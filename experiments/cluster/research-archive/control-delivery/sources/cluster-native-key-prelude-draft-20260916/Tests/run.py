"""Private Foundation/CryptoKit prelude checks; never model, RDMA or registration.
Requires a root compiler grant. Every process uses the existing owned helper.
"""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import resource
import signal
import subprocess
import sys
import time
from owned_process import invoke_controller

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PROPOSED = ROOT / 'proposed/libs/darkbloom-cluster/Sources'
DEPENDENCIES = ROOT / 'dependencies'
LIBCRYPTO = Path('/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib').resolve()


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def snapshot(paths):
    result = {}
    for path in paths:
        if path.is_symlink() or not path.is_file(): raise ValueError('Expected regular source: ' + str(path))
        result[str(path)] = digest(path)
    return result


def verify():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    for item in manifest['files']:
        path = ROOT / item['path']
        if path.is_symlink() or digest(path) != item['sha256']: raise ValueError('Frozen source differs: ' + item['path'])
    for item in json.loads((ROOT / 'dependency-pins.json').read_text()):
        if digest(ROOT / item['snapshot']) != item['sha256']: raise ValueError('Dependency snapshot differs')
    tools = json.loads((ROOT / 'tool-pins.json').read_text())
    if str(LIBCRYPTO) != tools['libcrypto']['path'] or digest(LIBCRYPTO) != tools['libcrypto']['sha256']:
        raise ValueError('Independent OpenSSL source changed')
    return snapshot([ROOT / item['path'] for item in manifest['files']] + [ROOT / 'manifest.json', LIBCRYPTO])


def run_owned(argv, output, name, timeout):
    receipt = {'argv': argv, 'timeoutSeconds': timeout, 'timedOut': False}
    began = time.monotonic()
    try:
        with (output / (name + '.stdout')).open('xb') as stdout, (output / (name + '.stderr')).open('xb') as stderr:
            with contextlib.redirect_stdout(io.StringIO()) as launch:
                invoke_controller(argv, stdout, stderr, receipt, timeout=timeout)
            receipt['launchObservation'] = launch.getvalue()
    except BaseException as error:
        receipt['timedOut'] = isinstance(error, subprocess.TimeoutExpired)
        raise
    finally:
        receipt['elapsedSeconds'] = time.monotonic() - began
        (output / (name + '.json')).write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    for suffix in ['stdout', 'stderr']:
        if (output / (name + '.' + suffix)).stat().st_size > 1_048_576: raise ValueError('Output bound')
    if receipt.get('exitCode') != 0 or not receipt.get('reaped') or not receipt.get('groupAbsent'):
        raise ValueError(name + ' failed; retained receipt/output')
    if (output / (name + '.stderr')).stat().st_size: raise ValueError(name + ' stderr was not empty')
    return receipt


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64': raise ValueError('Expected local Apple Silicon')
    before = verify()
    output = args.output.resolve(); output.mkdir(mode=0o700, exist_ok=False)
    (output / 'module-cache').mkdir(mode=0o700)
    (output / 'source-snapshot.json').write_text(json.dumps(before, indent=2, sort_keys=True) + '\n')
    bootstrap = sorted((DEPENDENCIES / 'Sources/DarkbloomClusterBootstrap').glob('*.swift')) + sorted((PROPOSED / 'DarkbloomClusterBootstrap').glob('*.swift'))
    security = sorted((DEPENDENCIES / 'Sources/DarkbloomClusterSecurity').glob('*.swift')) + sorted((PROPOSED / 'DarkbloomClusterSecurity').glob('*.swift'))
    native_checks = sorted(HERE.glob('NativeKey*.swift'))
    if len(bootstrap) != 6 or len(security) != 12 or len(native_checks) != 4: raise ValueError('Source closure changed')
    command = ['xcrun', 'swiftc', '-j', '2', '-swift-version', '6', '-warnings-as-errors', '-target', 'arm64-apple-macos14.0',
               '-parse-as-library', '-module-cache-path', str(output / 'module-cache')]
    linkage = ['-I', str(output), '-L', str(output), '-Xlinker', '-rpath', '-Xlinker', str(output)]
    steps = []
    def execute(argv, name, timeout=60):
        steps.append(run_owned(argv, output, name, timeout))
        if verify() != before: raise ValueError('Frozen source changed during checks')
    try:
        vector = output / 'independent-vector.json'
        execute([sys.executable, '-B', str(HERE / 'make_vector.py'), '--libcrypto', str(LIBCRYPTO), '--output', str(vector)], 'independent-vector', 10)
        for module, sources, libraries in [('DarkbloomClusterBootstrap', bootstrap, []),
                                           ('DarkbloomClusterSecurity', security, ['-lDarkbloomClusterBootstrap'])]:
            library = output / ('lib' + module + '.dylib')
            execute(command + ['-enable-testing', '-emit-library', '-emit-module', '-module-name', module,
                '-emit-module-path', str(output / (module + '.swiftmodule'))] + linkage + libraries +
                list(map(str, sources)) + ['-Xlinker', '-install_name', '-Xlinker', '@rpath/' + library.name, '-o', str(library)], module + '-compile')
        native_binary = output / 'native-key-check'
        execute(command + linkage + ['-lDarkbloomClusterBootstrap', '-lDarkbloomClusterSecurity'] +
                list(map(str, native_checks)) + ['-o', str(native_binary)], 'native-key-compile')
        execute([str(native_binary), str(vector)], 'native-key-fixture', 30)
        lines = (output / 'native-key-fixture.stdout').read_text().splitlines()
        if len(lines) != 8 or not all(line.startswith('PASS ') for line in lines) or '23 actual children' not in lines[-1]:
            raise ValueError('Native key checks incomplete')
        old_bootstrap = output / 'legacy-bootstrap-check'
        execute(command + linkage + ['-lDarkbloomClusterBootstrap', str(DEPENDENCIES / 'Tests/BootstrapChannelCheck.swift'),
                '-o', str(old_bootstrap)], 'legacy-bootstrap-compile')
        execute([str(old_bootstrap)], 'legacy-bootstrap-fixture', 10)
        if (output / 'legacy-bootstrap-fixture.stdout').read_text() != 'PASS 5 bootstrap check groups; 12 actual local children; no model, RDMA or remote network\n':
            raise ValueError('Legacy bootstrap regression incomplete')
        for name in ['Codec', 'Adapter']:
            binary = output / (name.lower() + '-check')
            sources = sorted((DEPENDENCIES / 'Tests' / name).glob('*.swift'))
            execute(command + linkage + ['-lDarkbloomClusterBootstrap'] + list(map(str, security + sources)) + ['-o', str(binary)], name.lower() + '-compile')
            arguments = [str(DEPENDENCIES / 'Tests/Codec/vectors.json')] if name == 'Codec' else []
            execute([str(binary)] + arguments, name.lower() + '-fixture', 10)
            lines = (output / (name.lower() + '-fixture.stdout')).read_text().splitlines()
            if len(lines) != 9 or not all(line.startswith('PASS ') for line in lines): raise ValueError(name + ' regression incomplete')
        result = {'passed': True, 'groups': 28, 'actualLocalChildCases': 35, 'steps': steps,
                  'sourceUnchanged': True, 'modelExecuted': False, 'rdmaExecuted': False,
                  'coordinatorAuthorizationExercised': False, 'nativeApprovalExercised': False,
                  'vectorSHA256': digest(vector), 'binaries': {p.name: digest(p) for p in output.iterdir() if p.is_file() and (p.name.endswith('-check') or p.suffix == '.dylib')}}
        (output / 'checks.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
        print('PASS 28 CPU groups/35 actual local children; no model/RDMA/coordinator authorization')
    finally:
        unchanged = verify() == before
        (output / 'source-recheck.json').write_text(json.dumps({'unchanged': unchanged}) + '\n')
        if not unchanged: raise ValueError('Source changed')


if __name__ == '__main__':
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024 * 1024, 256 * 1024 * 1024))
    def timeout(_signum, _frame): raise TimeoutError('Whole CPU check bound reached')
    signal.signal(signal.SIGALRM, timeout); signal.alarm(450)
    main()
