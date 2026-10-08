"""Root-only strict-SSH same-binary CPU check; requires a quiet-slot grant."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shlex
import time
from owned_process import invoke_controller
from remote_result import validate_result
from ssh_settings import SSH

BASE = Path(__file__).resolve().parent
KNOWN = Path('/Users/developer/DarkbloomDev/cluster-research/qwen-resident-mtp-registered-probe-qualification-20260915/configuration/known_hosts')
KNOWN_SHA = '89a73d7ca9fe16a0c1aeb0fa6cfa640ff37a02d4a2d21114e7ad5fca089443ed'
BINARY_SHA = '3a2fb41e1374099700e19118458395828d262461e60e5daea060f155701602d8'


def require(value, reason):
    if not value: raise RuntimeError(reason)


def pin(path):
    raw = path.read_bytes()
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--peer', choices=['darkbloom-24', 'darkbloom-48'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    for item in json.loads((BASE / 'manifest.json').read_text())['files']:
        require(pin(BASE / item['path']) == {'bytes': item['sizeBytes'], 'sha256': item['sha256']}, 'Frozen input changed')
    require(pin(KNOWN)['sha256'] == KNOWN_SHA, 'Known-hosts pin changed')
    binary = (BASE / 'bundle/authenticated-record-benchmark').read_bytes()
    require(hashlib.sha256(binary).hexdigest() == BINARY_SHA, 'Benchmark binary changed')
    packet = {'schema': 'darkbloom_record_cpu_remote_v1', 'expectedSSHHost': args.peer,
        'binaryBase64': base64.b64encode(binary).decode('ascii'),
        'helperBase64': base64.b64encode((BASE / 'owned_process.py').read_bytes()).decode('ascii')}
    raw = (json.dumps(packet, separators=(',', ':'), sort_keys=True) + '\n').encode()
    require(len(raw) <= 524288, 'CPU deployment bound exceeded')
    output = args.output.resolve(); output.mkdir(mode=0o700, parents=False, exist_ok=False)
    payload = output / 'payload.json'; payload.write_bytes(raw); payload.chmod(0o600)
    command = SSH + ['-S', 'none', args.peer,
        shlex.join(['/usr/bin/python3', '-I', '-B', '-c', (BASE / 'remote_run.py').read_text()])]
    receipt = {'peer': args.peer, 'argv': command, 'knownHostsSHA256': KNOWN_SHA,
        'binarySHA256': BINARY_SHA, 'requestedCPUOnly': True, 'modelOrRDMATest': False, 'passed': False}
    started = time.monotonic()
    try:
        with payload.open('rb') as source, (output / 'stdout').open('xb') as stdout, (output / 'stderr').open('xb') as stderr:
            invoke_controller(command, stdout, stderr, receipt, timeout=75, stdin=source)
        require(receipt.get('exitCode') == 0 and receipt.get('reaped') and receipt.get('groupAbsent')
                and not receipt.get('killedOwnedGroup'), 'SSH CPU operation did not finish cleanly')
        require((output / 'stderr').stat().st_size == 0 and (output / 'stdout').stat().st_size <= 393216,
                'SSH output differs or exceeds bound')
        remote = json.loads((output / 'stdout').read_bytes())
        require(remote['schema'] == 'darkbloom_record_cpu_remote_result_v1' and remote['passed'] is True
                and remote['expectedSSHHost'] == args.peer and bool(remote['actualHostname']), 'Wrong remote result')
        require(remote['binarySHA256'] == remote['binaryBeforeSHA256'] == remote['binaryAfterSHA256'] == BINARY_SHA,
                'Remote binary pin differs')
        require(remote['modelExecuted'] is False and remote['encryptedRDMAMeasured'] is False
                and remote['journalModified'] is False, 'Remote scope differs')
        require(remote['journalBefore'] == remote['journalAfter'] and remote['journalAfter']['bytes'] == 0,
                'Canonical journal identity/size changed')
        require(all(remote[name]['prohibited'] == [] for name in
                    ['processesBefore', 'processesImmediatelyBefore', 'processesAfter']), 'Native process observation differs')
        require(remote['child']['exitCode'] == 0 and remote['child']['reaped'] and remote['child']['groupAbsent']
                and not remote['child']['killedOwnedGroup'], 'Remote CPU child did not end naturally')
        summaries = validate_result(remote['report'])  # Requires actual M4 Pro; never rewrites host identity.
        receipt.update(passed=True, actualHostname=remote['actualHostname'], hostChip=remote['report']['hostChip'],
            summary=summaries, remoteChild=remote['child'], canonicalJournal=remote['journalAfter'])
    finally:
        receipt.update(elapsedSeconds=time.monotonic() - started,
            stdout=pin(output / 'stdout'), stderr=pin(output / 'stderr'))
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'passed': True, 'peer': args.peer, 'hostChip': receipt['hostChip'],
                      'cases': 8, 'modelOrRDMATest': False}))


if __name__ == '__main__': main()
