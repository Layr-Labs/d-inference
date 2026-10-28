"""Root-only read-only preflight of the unchanged installed 27B owner tree."""
from pathlib import Path
import argparse
import hashlib
import json
import shlex
import subprocess
import time
from parent_settings import SSH

BASE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--rank', type=int, choices=(0, 1), required=True)
    args = parser.parse_args()
    for item in json.loads((BASE / 'run-pins.json').read_bytes())['files']:
        path = Path(item['path'])
        assert path.stat().st_size == item['bytes'] and hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256']
    rank = json.loads((BASE / 'deployment.json').read_bytes())['ranks'][args.rank]
    script = (BASE / 'preparation/remote_preflight.py').read_text()
    output = BASE / 'preflight-1' / ('rank' + str(args.rank))
    output.parent.mkdir(mode=0o700, exist_ok=True)
    output.mkdir(mode=0o700, exist_ok=False)
    command = SSH + ['-S', 'none', rank['host'], shlex.join(['/usr/bin/python3', '-B', '-c', script])]
    started = time.monotonic()
    receipt = {'schema': 'qwen27b_unchanged_tree_preflight_v1', 'rank': args.rank,
               'passed': False, 'remoteMutationRequested': False, 'modelExecuted': False}
    try:
        result = subprocess.run(command, input=json.dumps(rank, separators=(',', ':')).encode(),
                                capture_output=True, timeout=45)
        (output / 'stdout').write_bytes(result.stdout)
        (output / 'stderr').write_bytes(result.stderr)
        receipt.update(exitCode=result.returncode, stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(),
                       stderrSHA256=hashlib.sha256(result.stderr).hexdigest())
        assert result.returncode == 0 and not result.stderr and len(result.stdout) <= 128 * 1024
        value = json.loads(result.stdout)
        assert len(value['verified']) == 14 and value['active'] == []
        assert value['journal']['bytes'] == 0 and value['evidenceEmpty'] is True
        receipt['passed'] = True
    except subprocess.TimeoutExpired as error:
        (output / 'stdout').write_bytes(error.stdout or b'')
        (output / 'stderr').write_bytes(error.stderr or b'')
        receipt['timeout'] = True
        raise
    finally:
        receipt['elapsedSeconds'] = time.monotonic() - started
        (output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'rank': args.rank, 'passed': True, 'output': str(output)}))


if __name__ == '__main__':
    main()
