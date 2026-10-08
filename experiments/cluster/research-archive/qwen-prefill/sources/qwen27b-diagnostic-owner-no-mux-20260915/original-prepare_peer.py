"""Root-only: preflight old tree, replace only diagnostic owner, preflight new tree."""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import shlex
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BASE))
from parent_settings import SSH
from install_diagnostic_owner import OLD_SHA, OLD_BYTES, NEW_SHA, NEW_BYTES


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--rank', type=int, choices=(0, 1), required=True)
    args = parser.parse_args()
    pins = json.loads((BASE / 'run-pins.json').read_bytes())
    for entry in pins['files']:
        path = Path(entry['path'])
        assert path.stat().st_size == entry['bytes'] and hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256']
    deployment = json.loads((BASE / 'deployment.json').read_bytes())
    after = deployment['ranks'][args.rank]
    before = json.loads(json.dumps(after))
    owner = next(item for item in after['files'] if item['path'] == 'darkbloom-owner-qualification')
    before_owner = next(item for item in before['files'] if item['path'] == 'darkbloom-owner-qualification')
    before_owner.update(bytes=OLD_BYTES, sha256=OLD_SHA)
    raw = Path(owner['source']).read_bytes()
    assert len(raw) == NEW_BYTES and hashlib.sha256(raw).hexdigest() == NEW_SHA
    preflight = Path(__file__).with_name('remote_preflight.py').read_text()
    installer = Path(__file__).with_name('install_diagnostic_owner.py').read_text()
    output = BASE / 'install-1' / ('rank' + str(args.rank))
    output.parent.mkdir(mode=0o700, exist_ok=True)
    output.mkdir(mode=0o700, exist_ok=False)
    records = []

    def invoke(label, script, value, timeout):
        began = time.monotonic()
        command = SSH + [after['host'], shlex.join(['/usr/bin/python3', '-B', '-c', script])]
        try:
            result = subprocess.run(command, input=json.dumps(value, separators=(',', ':')).encode(),
                                    capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            (output / (label + '.stdout')).write_bytes(error.stdout or b'')
            (output / (label + '.stderr')).write_bytes(error.stderr or b'')
            records.append({'operation': label, 'timeout': True, 'remoteOutcomeUnknown': True})
            raise
        (output / (label + '.stdout')).write_bytes(result.stdout)
        (output / (label + '.stderr')).write_bytes(result.stderr)
        records.append({'operation': label, 'exitCode': result.returncode,
                        'elapsedSeconds': time.monotonic() - began,
                        'stdoutSHA256': hashlib.sha256(result.stdout).hexdigest(),
                        'stderrSHA256': hashlib.sha256(result.stderr).hexdigest()})
        assert result.returncode == 0 and not result.stderr, 'Remote operation failed: ' + label
        return json.loads(result.stdout)

    passed = False
    try:
        invoke('before', preflight, before, 45)
        changed = invoke('install', installer, {'schema': 'qwen27b_native_diagnostic_owner_install_v1',
                         'rank': args.rank, 'binaryBase64': base64.b64encode(raw).decode()}, 20)
        assert changed['beforeSHA256'] == OLD_SHA and changed['afterSHA256'] == NEW_SHA
        checked = invoke('after', preflight, after, 45)
        assert len(checked['verified']) == 14 and checked['journal']['bytes'] == 0 and checked['evidenceEmpty'] is True
        passed = True
    finally:
        receipt = {'schema': 'qwen27b_diagnostic_owner_peer_preparation_v1', 'rank': args.rank,
                   'passed': passed, 'operations': records, 'configurationUnchanged': True,
                   'nativeControllerOrLibrariesChanged': False, 'modelExecuted': False}
        (output / 'result.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'rank': args.rank, 'passed': passed, 'output': str(output)}))


if __name__ == '__main__':
    main()
