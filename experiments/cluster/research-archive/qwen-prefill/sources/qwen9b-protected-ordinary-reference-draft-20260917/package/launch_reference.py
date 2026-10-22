"""Root-only reference launch; retain the remote terminal identity for collection."""
import argparse
import hashlib
from pathlib import Path
from binding_common import canonical, parse
from binding_inputs import snapshot
from reference_settings import REMOTE
import run_reference


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--job', required=True); parser.add_argument('--job-sha256', required=True)
    parser.add_argument('--launcher-sha256', required=True)
    args = parser.parse_args()
    result = 1
    try:
        result = run_reference.main(['--job', args.job, '--job-sha256', args.job_sha256,
                                     '--launcher-sha256', args.launcher_sha256])
        return result
    finally:
        path = REMOTE / 'runs/reference-1/terminal.json'
        if path.is_file() and not path.is_symlink():
            raw = snapshot(path, 1024**2)
            print(canonical(dict(schema='qwen9b_reference_launch_terminal_v1',
                runDirectory=str(path.parent), terminalSHA256=raw['sha256'],
                jobSHA256=args.job_sha256, launcherSHA256=args.launcher_sha256,
                status=parse(raw['raw']).get('status'), exitCode=result)).decode(), flush=True)


if __name__ == '__main__':
    raise SystemExit(main())
