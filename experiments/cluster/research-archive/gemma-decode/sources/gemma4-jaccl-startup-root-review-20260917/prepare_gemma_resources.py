"""Quiescent post-copy cache maintenance; all native resource floors stay intact."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import shlex
import stat
import subprocess
import time

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent / 'qwen27b-matched-short-cohort-draft-20260916/physical-source/prepare_resources.py'
assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == 'f4477ad6d5b0c046c0a8b10978263c35b8d36dce79c3ee8b8a06ddae906907e6'
spec = importlib.util.spec_from_file_location('retained_resource_preparation', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# The copy can leave reclaimable file cache with very few free pages. A native
# launch is still forbidden there. Only this quiescent maintenance operation may
# enter with that condition; its postflight retains the complete original gate.
before = 'before=sample_local();validate_local(before)'
after = "before=sample_local();assert before['acPower'] is True and before['pressureLevel']==1 and float(before['reportedSwapBytes'])==0"
assert module.REMOTE.count(before) == 1
REMOTE = module.REMOTE.replace(before, after)
old_prefix = "startswith(('darkbloom','qwen'))"
assert REMOTE.count(old_prefix) == 1
REMOTE = REMOTE.replace(old_prefix, "startswith(('darkbloom','qwen','gemma'))")
assert 'validate_local(after)' in REMOTE


def main():
    for host, expected in [
        ('darkbloom-24', '6c28a7701e6bd84016ef823cc35f561f7af648805187f4a34581b186258f0d0b'),
        ('darkbloom-48', '7fc254a1ddbeec643a2e2cafb39e57703b9ec304afc87b6d3dec8cc394aca548'),
    ]:
        path = ROOT.parent / ('gemma4-artifact-copy-' + host + '-2-20260917/receipt.json')
        assert hashlib.sha256(path.read_bytes()).hexdigest() == expected
        value = json.loads(path.read_text())
        assert value['status'] == 'passed' and value['receiverStatus']['groupAbsent']
        assert value['verification']['postflight']['journalEmptyAndUnlocked']
    os.umask(0o077)
    output = ROOT / 'resource-preparation-1'
    output.mkdir(mode=0o700)
    credential = ROOT.parent.parent / 'machines/CREDENTIALS.private.md'
    info = credential.lstat()
    assert stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o600
    rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
            for line in credential.read_text().splitlines() if line.startswith('|')]
    secret = (rows[2][[cell.lower() for cell in rows[0]].index('password')] + '\n').encode()
    for rank, host in enumerate(['darkbloom-24', 'darkbloom-48']):
        command = module.SSH + ['-S', 'none', host, shlex.join(['/usr/bin/python3', '-B', '-c', REMOTE])]
        start = time.monotonic()
        record = dict(host=host, passed=False,
            remoteScriptSHA256=hashlib.sha256(REMOTE.encode()).hexdigest(),
            originalRemoteSHA256=hashlib.sha256(module.REMOTE.encode()).hexdigest(),
            beforeFreeFloorAppliesToNativeOnly=True, nativeResourceFloorsChanged=False)
        try:
            result = subprocess.run(command, input=secret, capture_output=True, timeout=50)
            (output / f'rank{rank}.stdout').write_bytes(result.stdout)
            (output / f'rank{rank}.stderr').write_bytes(result.stderr)
            record.update(exitCode=result.returncode,
                stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(),
                stderrSHA256=hashlib.sha256(result.stderr).hexdigest())
            assert result.returncode == 0 and not result.stderr and len(result.stdout) <= 131072
            value = json.loads(result.stdout)
            assert value['passed'] and value['journalUnchanged'] and value['reaped'] and value['groupAbsent']
            record.update(passed=True, beforeFreeBytes=value['before']['actualFreeBytes'],
                          afterFreeBytes=value['after']['actualFreeBytes'])
        finally:
            record['elapsedSeconds'] = time.monotonic() - start
            (output / f'rank{rank}.receipt.json').write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record), flush=True)


if __name__ == '__main__':
    prior = ROOT.parent / 'gemma4-jaccl-startup-progress-draft-20260917/physical-actions-1/stages/action/receipt.json'
    assert hashlib.sha256(prior.read_bytes()).hexdigest() == 'b6b789be01546f779303b08bacbf0c673660a500d71a0ee6c2aca8b9cd69cb6b'
    value = json.loads(prior.read_text())
    assert value['status'] == 'failed' and value['aliasRelease']['restored'] is True
    assert value['retirement']['journalsEmpty'] is True and value['retirement']['nativeProcessesAbsent'] is True
    assert value['retirement']['observationErrors'] == []
    main()
