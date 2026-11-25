"""Root-run only: stage both defaults, run one balanced HTTP request, restore exact bytes."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
from configuration_files import publish, read_private
from configuration_transaction import HOSTS, transact
from harness.guards import SSH

BASE = Path(__file__).resolve().parent


def bundled_remote():
    files = (BASE / 'configuration_files.py').read_text()
    main = (BASE / 'configuration_remote.py').read_text()
    return ('import sys,types\nmodule=types.ModuleType("configuration_files")\n'
            'exec(compile(' + repr(files) + ',"configuration_files.py","exec"),module.__dict__)\n'
            'sys.modules["configuration_files"]=module\n'
            'exec(compile(' + repr(main) + ',"configuration_remote.py","exec"),{"__name__":"__main__"})\n')


def recovery_pins(original):
    pins, errors = {}, {}
    for host in HOSTS:
        path = original / (host + '.prepare.stdout.json')
        receipt_path = original / (host + '.prepare.receipt.json')
        try:
            if not path.exists() and not receipt_path.exists(): continue
            raw = read_private(path)[0]
            receipt = json.loads(read_private(receipt_path)[0])
            if type(receipt.get('exitCode')) is not int or receipt['exitCode'] != 0 or receipt.get('stdoutSHA256') != hashlib.sha256(raw).hexdigest():
                raise ValueError('Prepared output receipt differs')
            value = json.loads(raw)
            pin = value['afterSHA256']
            if value.get('memberID') != host or type(pin) is not str or len(pin) != 64 or any(c not in '0123456789abcdef' for c in pin):
                raise ValueError('Prepared postimage identity differs')
            pins[host] = pin
        except BaseException as error:
            # Do not prevent restoration of the other host. Without a retained
            # pin this host can only verify an already-exact original default.
            errors[host] = type(error).__name__ + ': ' + str(error)
    return pins, errors


def remote_action(host, action, pin, attempt, output):
    role = 'leader' if host == HOSTS[0] else 'follower'
    payload = dict(host=host, action=action, attempt=attempt, postimageSHA256=pin,
                   configuration=base64.b64encode((BASE / 'configuration' / (role + '.configure.json')).read_bytes()).decode())
    code = bundled_remote()
    command = SSH + ['-S', 'none', host, shlex.join(['/usr/bin/python3', '-B', '-c', code])]
    result = subprocess.run(command, input=json.dumps(payload).encode(), capture_output=True, timeout=45)
    if len(result.stdout) > 65536 or len(result.stderr) > 16384:
        raise ValueError('Configuration command output exceeded bound')
    name = host + '.' + action
    publish(output / (name + '.stdout.json'), result.stdout)
    publish(output / (name + '.stderr'), result.stderr)
    publish(output / (name + '.receipt.json'), (json.dumps(dict(
        exitCode=result.returncode, remoteProgramSHA256=hashlib.sha256(code.encode()).hexdigest(),
        stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(), stderrSHA256=hashlib.sha256(result.stderr).hexdigest(),
        postimageSHA256=pin, nativeModelExecuted=False), indent=2) + '\n').encode())
    value = json.loads(result.stdout)
    if result.returncode != 0 or 'error' in value:
        raise ValueError('Configuration ' + action + ' refused on ' + host + ': ' + str(value.get('error')))
    return value


def physical(attempt, output):
    fixtures = BASE.parent / 'installed-http-long-prompts-20260915/fixtures'
    command = ['/usr/bin/python3', '-B', str(BASE / 'harness/run.py'), '--attempt', str(attempt),
               '--prompt-file', str(fixtures / 'prompt-8192.txt'), '--declared-prompt-tokens', '8192',
               '--rendered-prompt', str(fixtures / 'prompt-8192.rendered.txt'),
               '--expected-token-ids', str(fixtures / 'prompt-8192.ids.json'), '--client', str(BASE.parent / 'installed-http-client-draft-20260915/client.py')]
    environment = dict(os.environ, PYTHONPATH=str(BASE.parent / 'installed-http-client-draft-20260915'))
    with (output / 'harness.stdout').open('xb') as out, (output / 'harness.stderr').open('xb') as err:
        process = subprocess.Popen(command, cwd=BASE, env=environment, stdout=out, stderr=err, start_new_session=True)
        try:
            process.wait(timeout=650)
        except BaseException:
            # SIGINT permits the existing harness's BaseException/finally path
            # to retain its cleanup. Remote ownership is still checked before
            # either default can be restored; killing this parent proves none.
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try: process.wait(timeout=650)
                except BaseException:
                    process.kill(); process.wait(timeout=5)
            raise
    receipt = BASE / 'harness' / ('physical-' + str(attempt)) / 'execution.json'
    raw = receipt.read_bytes()
    if len(raw) > 1024 * 1024: raise ValueError('Harness receipt exceeds bound')
    value = json.loads(raw)
    return dict(httpObservationQualified=process.returncode == 0 and value.get('completed') is True,
                harnessExitCode=process.returncode, receipt=str(receipt), receiptSHA256=hashlib.sha256(raw).hexdigest(),
                inferenceRequestSucceeded=value.get('clientExitCode') == 0,
                slaPassed=(json.loads((BASE / 'harness' / ('physical-' + str(attempt)) / 'client/receipt.json').read_bytes())['measurement']['content_sla']['reported_prompt_tokens']['request_passed']))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--attempt', required=True, type=int)
    parser.add_argument('--execute', action='store_true', help='Acknowledge the reviewed real two-host pointer switch.')
    parser.add_argument('--restore-only', action='store_true')
    args = parser.parse_args()
    if not args.execute or not 1 <= args.attempt <= 99:
        parser.error('Expected --execute and fresh attempt1...99; restoration uses the original attempt')
    os.umask(0o077)
    root = BASE / 'transactions'; root.mkdir(mode=0o700, exist_ok=True)
    original = root / ('attempt-' + str(args.attempt))
    pins, recovery_errors = {}, {}
    if args.restore_only:
        pins, recovery_errors = recovery_pins(original)
        output = root / ('restore-' + str(args.attempt) + '-' + str(os.getpid()))
    else:
        if (BASE / 'harness' / ('physical-' + str(args.attempt))).exists():
            raise ValueError('Physical attempt already exists')
        output = original
    output.mkdir(mode=0o700)
    interrupted = False
    def interrupt(_signal, _frame):
        nonlocal interrupted
        if not interrupted:
            interrupted = True
            raise KeyboardInterrupt('Operator requested stop; cleanup/restoration remains owned')
    signal.signal(signal.SIGINT, interrupt); signal.signal(signal.SIGTERM, interrupt)
    record = transact(lambda host, action, pin: remote_action(host, action, pin, args.attempt, output),
                      lambda: physical(args.attempt, output), prepared=pins, restore_only=args.restore_only)
    record.update(schema='installed_balanced_http_transaction_v1', attempt=args.attempt,
                  configuredRequestTimeoutSeconds=120, ordinaryRequestTimeoutSeconds=120,
                  selectedPlanSHA256='2b5aa52cab49c12cfa44f2348326f956127d2ca15b1c55b5632f447901e56293',
                  externalContentSLANanoseconds=18_192_000_000, representativePerformanceQualified=False,
                  restoreOnly=args.restore_only, interrupted=interrupted, recoveryReceiptErrors=recovery_errors)
    if recovery_errors: record['qualified'] = False
    publish(output / 'execution.json', (json.dumps(record, indent=2) + '\n').encode())
    print(json.dumps({key: record[key] for key in ('qualified', 'defaultsRestored', 'error', 'restorationErrors', 'physical')}, sort_keys=True))
    raise SystemExit(0 if record['qualified'] else 1)


if __name__ == '__main__': main()
