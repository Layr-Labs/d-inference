"""Authorized read-only collection, using UUIDs from completed controller receipts."""
from pathlib import Path
import base64
import hashlib
import json
import os
import shlex
import sys
import uuid
from bounded_read import bounded_command
from parent_settings import SSH

BASE = Path(__file__).resolve().parent
SOURCE = BASE.parent / 'qwen9b-balanced-prefill-candidate-20260915'
HOSTS = ('darkbloom-24', 'darkbloom-48')


def write(path, raw):
    with path.open('xb') as stream:
        stream.write(raw)


def main():
    os.umask(0o077)
    output = BASE / 'collection-1'
    output.mkdir(mode=0o700)
    code = (BASE / 'read_remote.py').read_text()
    pins, records = {}, []
    for case in ('cut4-timing', 'cut16-timing'):
        folder = SOURCE / 'cases' / case
        controller_path = folder / 'physical-1/controller.stdout.jsonl'
        raw = controller_path.read_bytes()
        assert 0 < len(raw) <= 1024**2
        pins[str(controller_path)] = hashlib.sha256(raw).hexdigest()
        values = [json.loads(line) for line in raw.splitlines() if line]
        observations = [v['observation'] for v in values if v['schema'] == 'owner_timing_request_v1']
        finals = [v for v in values if v['schema'] == 'owner_timing_cohort_result_v1']
        assert len(finals) == 1 and finals[0]['completed'] is True and finals[0]['requests'] == observations
        assert [x['phase'] for x in observations] == ['warmup', 'measured', 'measured', 'measured']
        ids = [x['requestID'] for x in observations]
        assert len(set(ids)) == 4 and all(str(uuid.UUID(x)) == x for x in ids)
        for rank, host in enumerate(HOSTS):
            config_path = folder / 'configuration' / ('owner-rank' + str(rank) + '.json')
            config_raw = config_path.read_bytes()
            pins[str(config_path)] = hashlib.sha256(config_raw).hexdigest()
            expected_directory = json.loads(config_raw)['workerEnvironment']['DARKBLOOM_BENCHMARK_EVIDENCE_DIR']
            assert expected_directory == '/Users/developer/DarkbloomDev/qwen9b-balanced-prefill-20260915/' + case + '/evidence'
            destination = output / case / ('rank' + str(rank)); destination.mkdir(parents=True)
            command = SSH + ['-S', 'none', host,
                shlex.join(['/usr/bin/python3', '-B', '-c', code, case] + ids)]
            stdout, stderr, process, failure = bounded_command(command, timeout=30)
            write(destination / 'remote.stdout.json', stdout)
            write(destination / 'remote.stderr', stderr)
            process.update(readerSHA256=hashlib.sha256(code.encode()).hexdigest(),
                stdoutSHA256=hashlib.sha256(stdout).hexdigest(), stderrSHA256=hashlib.sha256(stderr).hexdigest())
            write(destination / 'ssh-receipt.json', (json.dumps(process, indent=2)+'\n').encode())
            if failure is not None:
                raise failure
            assert not stderr
            value = json.loads(stdout)
            expected = sorted(x + '.json' for x in ids)
            assert value['directory'] == expected_directory
            assert value['expectedNames'] == value['observedBefore'] == value['observedAfter'] == expected
            assert [x['name'] for x in value['files']] == expected
            for item in value['files']:
                data = base64.b64decode(item.pop('data'), validate=True)
                assert len(data) == item['bytes'] <= 16*1024**2
                assert hashlib.sha256(data).hexdigest() == item['sha256']
                write(destination / item['name'], data)
            value.update(case=case, rank=rank, host=host, sshReceipt='ssh-receipt.json')
            records.append(value)
            print(case + ' rank' + str(rank) + ': ' + str(len(expected)) + ' sidecars collected', flush=True)
    for path, pin in pins.items():
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == pin
    write(output / 'collection.json', (json.dumps(dict(records=records, inputPins=pins,
        readerSHA256=hashlib.sha256(code.encode()).hexdigest(), readOnlyRemote=True,
        modelOrCompilerExecuted=False, frozenReportsModified=False),indent=2)+'\n').encode())


if __name__ == '__main__':
    main()
