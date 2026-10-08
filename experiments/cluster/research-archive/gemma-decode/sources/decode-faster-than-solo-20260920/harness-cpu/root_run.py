"""Root-invoked bounded actions over the preserved physical supervision."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

from owned_process import invoke_controller

ROOT = Path(__file__).resolve().parent
PYTHON = '/usr/bin/python3'

def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()

def verify_source():
    source = ROOT / 'source-inputs.json'
    value = json.loads(source.read_bytes())
    for row in value['members']:
        path = ROOT / row['path']
        assert path.is_file() and not path.is_symlink()
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
    return sha(source)

def slug(value):
    assert value and all(c.isalnum() or c in '-_' for c in value)
    return value

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=['deploy-prepare', 'install', 'case-prepare',
        'prepare-memory', 'solo', 'pair', 'metadata', 'compare', 'compare-overlap'])
    parser.add_argument('--name', required=True, help='Fresh root action output directory')
    parser.add_argument('--case')
    parser.add_argument('--match')
    parser.add_argument('--mode', choices=['full', 'stage0', 'stage1'], default='full')
    parser.add_argument('--operation', choices=['describe', 'check-arguments'], default='describe')
    parser.add_argument('--host', choices=['darkbloom-24', 'darkbloom-48'])
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--build-receipt', type=Path)
    parser.add_argument('--prompt', type=int, choices=[128, 256, 1024, 4096, 8192], default=4096)
    parser.add_argument('--cut', type=int, choices=[6, 7, 8, 10], default=7)
    parser.add_argument('--chunk', type=int, choices=[64, 128], default=64)
    parser.add_argument('--policy', choices=['serial', 'oneChunkLookahead'], default='serial')
    parser.add_argument('--capture', action='store_true')
    args = parser.parse_args()
    source_sha = verify_source()
    for value in [args.name, args.case, args.match]:
        if value is not None: slug(value)
    command = [PYTHON, '-B']
    detail = {}
    if args.action == 'deploy-prepare':
        assert args.binary and args.build_receipt
        assert args.binary.name == 'GemmaResidentBenchmark' and args.binary.is_absolute()
        build = json.loads(args.build_receipt.read_bytes())
        assert build['exitCode'] == 0 and build['compilerReaped'] is True
        assert build['gpuExecuted'] is False
        assert sha(args.binary) == build['nativeSHA256'] and args.binary.stat().st_size == build['nativeBytes']
        detail = dict(buildReceipt=str(args.build_receipt), buildReceiptSHA256=sha(args.build_receipt), nativeSHA256=build['nativeSHA256'])
        command += [str(ROOT / 'deploy.py'), 'prepare', '--binary', str(args.binary)]
        timeout = 150
    elif args.action == 'install':
        assert args.host
        command += [str(ROOT / 'deploy.py'), 'install', '--host', args.host]
        timeout = 150
    elif args.action == 'case-prepare':
        assert args.case
        command += [str(ROOT / 'run_case.py'), 'prepare', '--name', args.case,
            '--prompt', str(args.prompt), '--cut', str(args.cut), '--chunk', str(args.chunk), '--policy', args.policy]
        if args.capture: command.append('--capture')
        if args.match: command += ['--match', args.match]
        timeout = 30
    elif args.action == 'prepare-memory':
        assert args.case and (ROOT / 'cases' / args.case).is_dir()
        command += [str(ROOT / 'prepare_memory.py'), '--output', str(ROOT / 'cases' / args.case / (args.name + '.json'))]
        timeout = 150
    elif args.action in ['solo', 'pair']:
        assert args.case
        command += [str(ROOT / 'run_case.py'), args.action, '--name', args.case]
        # Native300 / remote315 / SSH345 / alias expiry625, then at most two
        # sequential180s collections. This bounds the controller, not native life.
        timeout = 1020
    elif args.action == 'metadata':
        assert args.case
        command += [str(ROOT / 'remote_metadata.py'), '--case', args.case,
            '--mode', args.mode, '--operation', args.operation]
        timeout = 50
    elif args.action == 'compare':
        assert args.case
        command += [str(ROOT / 'compare_results_v2.py'), str(ROOT / 'cases' / args.case)]
        timeout = 180
    else:
        assert args.case and args.match
        command += [str(ROOT / 'compare_results_overlap.py'), str(ROOT / 'cases' / args.match), str(ROOT / 'cases' / args.case)]
        timeout = 240
    parent = ROOT / 'root-actions'; parent.mkdir(mode=0o700, exist_ok=True)
    output = parent / args.name; output.mkdir(mode=0o700)
    receipt = dict(schema='gemma4_decode_root_action_v1', action=args.action, argv=command,
        sourceManifestSHA256=source_sha, **detail)
    started = time.monotonic()
    try:
        with (output / 'stdout').open('xb') as stdout, (output / 'stderr').open('xb') as stderr:
            invoke_controller(command, stdout, stderr, receipt, timeout=timeout)
        assert receipt['exitCode'] == 0 and receipt['reaped'] and receipt['groupAbsent']
        assert verify_source() == source_sha
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt['status'] = 'failed'
        receipt['error'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        receipt['elapsedSeconds'] = time.monotonic() - started
        for name in ['stdout', 'stderr']:
            path = output / name
            if path.exists(): receipt[name+'SHA256'] = sha(path); receipt[name+'Bytes'] = path.stat().st_size
        with (output / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2); stream.write('\n')
        print(json.dumps(receipt), flush=True)

if __name__ == '__main__':
    main()
