"""One temporary IPv4 alias around the first resident physical model cohort."""
from pathlib import Path
import hashlib
import json
import os
import select
import shlex
import subprocess
import time

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
LEASE = r'''
import json, os, re, signal, subprocess, sys
address = '169.254.70.47'
client = sys.argv[1]
addition_attempted = False
result = {'address': address, 'leaseSeconds': 600, 'restored': False}
def command(args):
    p = subprocess.run(args, capture_output=True, text=True, timeout=5)
    if p.returncode or p.stderr or len(p.stdout) > 100000:
        raise RuntimeError('Observation/action failed: ' + str(args) + ': ' + p.stderr[:1000])
    return p.stdout
def snapshot():
    return {'en1': command(['/sbin/ifconfig', 'en1']),
            'bridge0': command(['/sbin/ifconfig', 'bridge0']),
            'gid': command(['/usr/bin/ibv_devinfo', '-d', 'rdma_en1', '-v']),
            'managementRoute': command(['/sbin/route', '-n', 'get', client])}
def stable(before, after):
    members = lambda s: sorted(re.findall(r'member: (\S+)', s['bridge0']))
    route = lambda s: re.findall(r'^\s*(?:gateway|interface):\s*(.*)$', s['managementRoute'], re.M)
    return (members(before) == members(after)
            and before['bridge0'].splitlines()[0] == after['bridge0'].splitlines()[0]
            and route(before) == route(after)
            and 'status: active' in after['en1'] and 'PORT_ACTIVE' in after['gid'])
def interrupted(signum, frame):
    raise RuntimeError('Temporary alias lease ended by signal ' + str(signum))
for sig in (signal.SIGALRM, signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
    signal.signal(sig, interrupted)
signal.alarm(600)
try:
    result['before'] = snapshot()
    all_interfaces = command(['/sbin/ifconfig', '-a'])
    if 'inet ' + address + ' ' in all_interfaces or re.search(r'\binet ', result['before']['en1']):
        raise RuntimeError('Interface address state changed before the temporary alias')
    addition_attempted = True
    command(['/sbin/ifconfig', 'en1', 'inet', address, 'netmask', '255.255.255.255', 'alias'])
    result['afterAdd'] = snapshot()
    if not stable(result['before'], result['afterAdd']) or '::ffff:' + address not in result['afterAdd']['gid']:
        raise RuntimeError('Alias did not produce the mapped GID with stable bridge and management route')
    print(json.dumps({'state': 'ready', 'address': address, 'bridgeAndManagementStable': True}), flush=True)
    if sys.stdin.readline() != 'release\n':
        raise RuntimeError('Temporary alias release channel closed or differed')
except BaseException as error:
    result['error'] = type(error).__name__ + ': ' + str(error)
finally:
    signal.alarm(0)
    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, signal.SIG_IGN)
    if addition_attempted:
        try:
            current = command(['/sbin/ifconfig', 'en1'])
            if 'inet ' + address + ' ' in current:
                command(['/sbin/ifconfig', 'en1', 'inet', address, '-alias'])
            result['afterRemove'] = snapshot()
            result['restored'] = (stable(result['before'], result['afterRemove'])
                and 'inet ' + address + ' ' not in result['afterRemove']['en1']
                and '::ffff:' + address not in result['afterRemove']['gid'])
        except BaseException as error:
            result['cleanupError'] = type(error).__name__ + ': ' + str(error)
    else:
        result['restored'] = True
    print(json.dumps(result), flush=True)
raise SystemExit(0 if result['restored'] and 'error' not in result else 1)
'''


def main():
    rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
            for line in (ROOT.parent / 'machines/CREDENTIALS.private.md').read_text().splitlines()
            if line.startswith('|')]
    password = rows[2][[cell.lower() for cell in rows[0]].index('password')]
    connection = subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=5','darkbloom-48','/usr/bin/printenv','SSH_CONNECTION'], capture_output=True, text=True, check=True, timeout=10)
    client = connection.stdout.split()[0]
    assert len(connection.stdout.split()) == 4 and ':' not in client
    output = ROOT / 'resident-physical-v2-cut12-20260915'
    record = {'kind': 'temporary_alias_resident_physical_cohort', 'performanceQualified': False}
    errpath = ROOT / 'resident-physical-v2-alias-20260915.stderr.log'
    with errpath.open('xb') as err:
        os.fchmod(err.fileno(), 0o600)
        lease = subprocess.Popen(['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
            'darkbloom-48', shlex.join(['/usr/bin/sudo', '-k', '-S', '-p', '',
                                      '/usr/bin/python3', '-c', LEASE, client])],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, bufsize=0)
        try:
            lease.stdin.write((password + '\n').encode())
            lease.stdin.flush()
            ready = bytearray()
            deadline = time.monotonic() + 15
            while b'\n' not in ready:
                if time.monotonic() >= deadline or not select.select([lease.stdout], [], [], 1)[0]:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Alias readiness deadline exceeded')
                    continue
                block = os.read(lease.stdout.fileno(), 1)
                if not block or len(ready) > 65536:
                    raise RuntimeError('Alias readiness stream ended or exceeded bound')
                ready.extend(block)
            record['ready'] = json.loads(ready)
            if record['ready'].get('state') != 'ready':
                raise RuntimeError('Temporary alias was not admitted')
            command = ['python3', '-B', str(ROOT / 'resident-physical-integration-v2-20260915/run_physical.py'), '--config', str(ROOT / 'resident-physical-v2-plan-20260915.json'), '--output', str(output)]
            completed = subprocess.run(command, capture_output=True, text=True, timeout=560)
            record['probe'] = {'command': command, 'exitCode': completed.returncode,
                               'stdout': completed.stdout, 'stderr': completed.stderr}
        except BaseException as error:
            record['error'] = type(error).__name__ + ': ' + str(error)
        finally:
            try:
                lease.stdin.write(b'release\n')
                lease.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
            try:
                tail, _ = lease.communicate(timeout=40)
                record['leaseExitCode'] = lease.returncode
                record['leaseRawTail'] = tail.decode(errors='replace')
                record['leaseFinal'] = [json.loads(line) for line in tail.splitlines() if line.strip()]
            except BaseException as error:
                record['cleanupUnconfirmed'] = True
                record['cleanupObservationError'] = type(error).__name__ + ': ' + str(error)
                try:
                    lease.terminate()
                    lease.wait(timeout=5)
                except BaseException as termination_error:
                    record['localLeaseTerminationError'] = type(termination_error).__name__ + ': ' + str(termination_error)
    record['leaseStderr'] = errpath.read_text().replace(password, '[REDACTED]')
    path = ROOT / 'resident-physical-v2-alias-execution-20260915.json'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(record, f, indent=2)
        f.write('\n')
    print(json.dumps({'receipt': str(path), 'probeExitCode': record.get('probe', {}).get('exitCode'),
        'error': record.get('error'), 'leaseExitCode': record.get('leaseExitCode'),
        'restored': [row.get('restored') for row in record.get('leaseFinal', [])],
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}))
    final = record.get('leaseFinal', [])
    success = ('error' not in record and not record.get('cleanupUnconfirmed')
               and record.get('probe', {}).get('exitCode') == 0
               and record.get('leaseExitCode') == 0 and len(final) == 1
               and final[0].get('restored') is True)
    raise SystemExit(0 if success else 1)


if __name__ == '__main__':
    main()
