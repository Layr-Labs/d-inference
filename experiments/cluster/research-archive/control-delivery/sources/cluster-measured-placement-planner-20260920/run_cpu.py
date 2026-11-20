"""Root-owned optional qualification: one <=60s compile, one <=30s CPU child."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import resource
import time
from check_process import run_owned
from check_sources import BASE, sha, verify

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    manifest, contract = verify()
    out = Path(args.output).absolute()
    out.mkdir(mode=0o700, parents=False, exist_ok=False)
    lock = (BASE / 'qualification.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    receipt = dict(passed=False, sourceManifestSHA256=sha(BASE / 'manifest.json'),
                   compilerExecuted=False, gpuOrModelOrRemoteExecuted=False,
                   fixtureKind='synthetic-only', startedMonotonic=time.monotonic())
    limits = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, limits[1]))
    try:
        for key in list(os.environ):
            if key.startswith(('DYLD_', 'SWIFT_DRIVER_', 'SWIFT_FRONTEND_')) or key in ('LD_PRELOAD', 'SWIFT_EXEC'):
                del os.environ[key]
        binary = out / 'placement-checks'
        receipt['compilerExecuted'] = True
        receipt['compile'] = run_owned(['/usr/bin/xcrun', 'swiftc', '-swift-version', '6',
            '-warnings-as-errors', '-j', '2', '-parse-as-library', '-module-cache-path', str(out / 'ModuleCache'),
            *[str(BASE / path) for path in contract['swiftSources']], '-o', str(binary)], out, 'compile', 60)
        verify()
        receipt['checks'] = run_owned([str(binary)], out, 'checks', 30)
        expected = ''.join('PASS ' + name + '\n' for name in contract['groups'])
        expected += 'PASS 19 placement groups (synthetic fixtures only)\n'
        assert (out / 'checks.stdout').read_text() == expected, 'Exact group completions differ'
        assert (out / 'checks.stderr').read_bytes() == b'', 'Unexpected fixture diagnostics'
        receipt['groups'] = contract['groups']
        receipt['binarySHA256'] = sha(binary)
        receipt['passed'] = True
    except BaseException as error:
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, limits)
        try:
            final, _ = verify()
            assert final == manifest, 'Source manifest changed'
            receipt['sourceUnchanged'] = True
        except BaseException as error:
            receipt['passed'] = False
            receipt['sourceRecheckFailure'] = str(error)
            raise
        finally:
            receipt['elapsedSeconds'] = time.monotonic() - receipt.pop('startedMonotonic')
            receipt['evidence'] = {name: sha(out / name) for name in
                ['compile.json', 'compile.stdout', 'compile.stderr', 'checks.json', 'checks.stdout', 'checks.stderr']
                if (out / name).is_file()}
            (out / 'receipt.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
            lock.close()

if __name__ == '__main__':
    os.umask(0o077)
    main()
