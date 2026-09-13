#!/usr/bin/env python3
"""Test the portable CI runner offline using an isolated temporary Go cache."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from sandbox_ci_bundle import FIXTURES, go_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--go-sdk', type=Path, help='explicit SDK; otherwise use the repository toolchain on PATH')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='darkbloom-ci-runner-tests-') as temporary:
        private = Path(temporary)
        if args.go_sdk:
            sdk = args.go_sdk.resolve(strict=True)
        else:
            selected = shutil.which('go')
            if not selected:
                parser.error('Go SDK unavailable; configure the repository toolchain or pass --go-sdk')
            # Discover only the selected local SDK. Toolchain downloads, user
            # config, API credentials and production database settings are absent.
            discovery = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(private),
                         'GOTOOLCHAIN': 'local', 'GOENV': 'off', 'GOPROXY': 'off', 'GOSUMDB': 'off',
                         'GOTELEMETRY': 'off', 'GOWORK': 'off'}
            sdk = Path(subprocess.check_output([selected, 'env', 'GOROOT'], env=discovery,
                                               cwd=FIXTURES / 'runner', text=True, timeout=30).strip()).resolve(strict=True)
        environment = go_environment(sdk, private, 4)
        print('Testing standard-library CI runner with isolated caches and local SDK:', sdk, flush=True)
        result = subprocess.run([sdk / 'bin/go', 'test', '-race', '-count=1', '-timeout=3m', './...'],
                                cwd=FIXTURES / 'runner', env=environment, timeout=240)
        return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
