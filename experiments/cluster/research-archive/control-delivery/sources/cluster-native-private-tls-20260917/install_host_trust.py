"""Install only this private CA with an SSL hostname constraint, retaining rollback evidence."""
import base64
import hashlib
import json
import os
import plistlib
import signal
import ssl
import stat
import subprocess
import sys
import time
from pathlib import Path

HOST = 'm4-max-36gb-connected.tail618116.ts.net'
CA_SHA = 'fcbb7d623762ef21a671a3a5267fd50e04db5f33f849f59c023c864709460e01'
LEAF_SHA = '3d5b06cffb2a69dfdd7cf3f827bddc044ed835b05244ebc035a7a61b891d800a'
ROOT = Path('/Users/developer/DarkbloomDev/cluster-tls-development-20260917')

def digest(raw):
    return hashlib.sha256(raw).hexdigest()

def main():
    os.umask(0o077)
    def expired(_signal, _frame):
        raise TimeoutError('Trust setup exceeded its total lifetime')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(120)
    secret = sys.stdin.buffer.readline(8193)
    if not 1 < len(secret) <= 8192 or not secret.endswith(b'\n'):
        raise ValueError('Invalid credential input')
    payload = json.loads(sys.stdin.buffer.read(16385))
    if set(payload) != {'ca', 'leaf', 'memoryBytes'}:
        raise ValueError('Invalid public certificate payload')
    if int(subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.memsize'], timeout=5)) != payload['memoryBytes']:
        raise ValueError('Target hardware differs')
    ROOT.mkdir(mode=0o700)
    receipt = dict(status='failed', hostname=HOST, trustInstalled=False, steps=[])
    started_mutation = False

    def run(name, argv, admin=False, expected=0):
        command = (['/usr/bin/sudo', '-k', '-S', '-p', ''] if admin else []) + argv
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        record = dict(name=name, argv=command, pid=child.pid, killedOwnedGroup=False)
        started = time.monotonic()
        try:
            out, err = child.communicate(secret if admin else b'', timeout=20)
        except BaseException:
            if child.returncode is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                    record['killedOwnedGroup'] = True
                except ProcessLookupError:
                    pass
            child.communicate(timeout=5)
            raise
        finally:
            record.update(exitCode=child.returncode, reaped=child.returncode is not None, elapsedSeconds=time.monotonic()-started)
            try:
                os.killpg(child.pid, 0)
                record['groupAbsent'] = False
            except ProcessLookupError:
                record['groupAbsent'] = True
            receipt['steps'].append(record)
        if len(out) + len(err) > 131072:
            raise ValueError('Unexpected diagnostic volume')
        # Passwords never enter command arguments, receipts, or persisted diagnostics.
        for suffix, raw in [('stdout', out), ('stderr', err)]:
            with (ROOT / (name + '.' + suffix)).open('xb') as stream:
                stream.write(raw.replace(secret.rstrip(b'\n'), b'[REDACTED]'))
        if not record['reaped'] or not record['groupAbsent'] or record['killedOwnedGroup']:
            raise ValueError('Incomplete child retirement')
        if expected is not None and child.returncode != expected:
            raise ValueError('Command failed: ' + name)
        return child.returncode, out, err

    try:
        for key, name, expected in [('ca', 'ca.crt', CA_SHA), ('leaf', 'server.crt', LEAF_SHA)]:
            raw = base64.b64decode(payload[key], validate=True)
            if len(raw) > 4096 or digest(raw) != expected:
                raise ValueError('Certificate bytes differ')
            with (ROOT / name).open('xb') as stream:
                stream.write(raw)
        der = ssl.PEM_cert_to_DER_cert((ROOT / 'ca.crt').read_text())
        cert_sha1 = hashlib.sha1(der).hexdigest().upper()
        cert_sha256 = digest(der).upper()
        security = ['/usr/bin/security']
        _, _, error = run('trust-before', security + ['trust-settings-export', '-d', str(ROOT / 'trust-before.plist')], expected=None)
        if (ROOT / 'trust-before.plist').exists():
            before = plistlib.loads((ROOT / 'trust-before.plist').read_bytes())
        elif b'No Trust Settings were found' in error or b'no trust settings were found' in error.lower():
            before = {'trustList': {}}
        else:
            raise ValueError('Prior trust settings could not be preserved')
        if cert_sha1 in before['trustList']:
            raise ValueError('This CA already has trust settings')
        verify = security + ['verify-cert', '-L', '-p', 'ssl', '-c', str(ROOT / 'server.crt')]
        run('untrusted-ca', verify + ['-c', str(ROOT / 'ca.crt'), '-n', HOST], expected=1)
        run('explicit-ca', verify + ['-r', str(ROOT / 'ca.crt'), '-n', HOST])
        run('wrong-host-before', verify + ['-r', str(ROOT / 'ca.crt'), '-n', 'wrong-host.invalid'], expected=1)
        started_mutation = True
        run('install', security + ['add-trusted-cert', '-d', '-r', 'trustRoot', '-p', 'ssl', '-s', HOST,
            '-k', '/Library/Keychains/System.keychain', str(ROOT / 'ca.crt')], admin=True)
        run('trust-after', security + ['trust-settings-export', '-d', str(ROOT / 'trust-after.plist')])
        after = plistlib.loads((ROOT / 'trust-after.plist').read_bytes())
        added = after['trustList'].pop(cert_sha1)
        if after['trustList'] != before['trustList']:
            raise ValueError('Unrelated trust settings changed')
        settings = added['trustSettings']
        if len(settings) != 1 or settings[0].get('kSecTrustSettingsPolicyString') != HOST or settings[0].get('kSecTrustSettingsResult') != 1:
            raise ValueError('Trust is not restricted to the exact SSL hostname')
        if settings[0].get('kSecTrustSettingsPolicyName') not in ('ssl', 'sslServer') or 'kSecTrustSettingsAllowedError' in settings[0]:
            raise ValueError('SSL policy or error constraint differs')
        run('os-trusted-ca', verify + ['-n', HOST])
        run('wrong-host-after', verify + ['-n', 'wrong-host.invalid'], expected=1)
        receipt.update(status='passed', trustInstalled=True, sslHostConstraint=HOST, caDER_SHA256=cert_sha256,
            unrelatedTrustSettingsUnchanged=True, privateKeyCopied=False, osTrustValidated=True,
            rollbackCommands=[security + ['remove-trusted-cert', '-d', str(ROOT / 'ca.crt')],
                              security + ['delete-certificate', '-Z', cert_sha256, '/Library/Keychains/System.keychain']])
    except BaseException as error:
        signal.alarm(0)
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        if started_mutation:
            for name, command in [('rollback-trust', ['/usr/bin/security', 'remove-trusted-cert', '-d', str(ROOT / 'ca.crt')]),
                                  ('rollback-cert', ['/usr/bin/security', 'delete-certificate', '-Z', cert_sha256, '/Library/Keychains/System.keychain'])]:
                try:
                    run(name, command, admin=True)
                except BaseException as rollback:
                    receipt.setdefault('rollbackFailures', []).append(type(rollback).__name__ + ': ' + str(rollback))
        raise
    finally:
        signal.alarm(0)
        with (ROOT / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write('\n')
        print(json.dumps({key: value for key, value in receipt.items() if key not in ('steps', 'rollbackCommands')}, sort_keys=True), flush=True)

if __name__ == '__main__':
    main()
