"""Root-run bounded read-only collection for one complete matched timing cohort."""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import os
import shlex
import sys
from bounded_read import bounded_command
from parent_settings import SSH
from timing_results import validate_cohort
from package_checks import verify_package

BASE = Path(__file__).resolve().parent


def write(path, raw):
    with path.open('xb') as stream:
        stream.write(raw)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--case', choices=('serial', 'lookahead'), required=True)
    args = parser.parse_args()
    verify_package()
    sys.path.insert(0, str(BASE / 'helpers' / args.case))
    from audit_common import parse
    os.umask(0o077)
    case = BASE / args.case
    output = case / 'collection-1'
    output.mkdir(mode=0o700)
    # Failed/incomplete raw runs remain in physical-1. They cannot contribute
    # samples, reach remote collection here, or receive a success aggregate.
    pins = {}
    def read(path, cap=1024**2):
        raw = path.read_bytes()
        assert 0 < len(raw) <= cap
        pins[str(path)] = hashlib.sha256(raw).hexdigest()
        return raw
    config_path = case / 'configuration/controller.json'
    config = parse(read(config_path))
    lines = [parse(x) for x in read(case / 'physical-1/controller.stdout.jsonl').splitlines() if x]
    execution = parse(read(case / 'physical-1/execution.json'))
    validate_cohort(config, pins[str(config_path)], lines, execution)
    identifiers = [x['observation']['requestID'] for x in lines[1:-1]]
    code = read(BASE / 'read_remote.py').decode()
    records = []
    for rank, host in enumerate(('darkbloom-24', 'darkbloom-48')):
        owner = parse(read(case / ('configuration/owner-rank' + str(rank) + '.json')))
        expected_directory = owner['workerEnvironment']['DARKBLOOM_BENCHMARK_EVIDENCE_DIR']
        assert expected_directory == '/Users/developer/DarkbloomDev/qwen27b-8k-' + args.case + '-timing-20260915/evidence'
        destination = output / ('rank' + str(rank)); destination.mkdir()
        command = SSH + ['-S', 'none', host, shlex.join(['/usr/bin/python3', '-B', '-c', code, args.case] + identifiers)]
        stdout, stderr, receipt, failure = bounded_command(command, timeout=30)
        write(destination / 'remote.stdout.json', stdout); write(destination / 'remote.stderr', stderr)
        receipt.update(readerSHA256=hashlib.sha256(code.encode()).hexdigest(), stdoutSHA256=hashlib.sha256(stdout).hexdigest(),
                       stderrSHA256=hashlib.sha256(stderr).hexdigest())
        write(destination / 'ssh-receipt.json', (json.dumps(receipt, indent=2) + '\n').encode())
        if failure is not None:
            raise failure
        assert not stderr
        value = parse(stdout); names = sorted(x + '.json' for x in identifiers)
        assert value['directory'] == expected_directory
        assert value['expectedNames'] == value['observedBefore'] == value['observedAfter'] == names
        assert [x['name'] for x in value['files']] == names
        for item in value['files']:
            raw = base64.b64decode(item.pop('data'), validate=True)
            assert len(raw) == item['bytes'] <= 16 * 1024**2 and hashlib.sha256(raw).hexdigest() == item['sha256']
            write(destination / item['name'], raw)
        value.update(case=args.case, rank=rank, host=host)
        records.append(value)
    for path, expected in pins.items():
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == expected
    write(output / 'collection.json', (json.dumps(dict(records=records, inputPins=pins, readOnlyRemote=True,
        modelOrCompilerExecuted=False, readerSHA256=hashlib.sha256(code.encode()).hexdigest()), indent=2) + '\n').encode())
    print(json.dumps(dict(case=args.case, rankSidecars=[4,4], collectionSHA256=hashlib.sha256((output/'collection.json').read_bytes()).hexdigest())))


if __name__ == '__main__':
    main()
