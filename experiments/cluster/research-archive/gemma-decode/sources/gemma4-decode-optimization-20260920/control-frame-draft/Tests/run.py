"""Prospective Foundation-only runner. Requires the separately scheduled slot."""
from pathlib import Path
import argparse
import hashlib
import json
import time

from owned_process import invoke_controller

BASE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_inputs():
    values = json.loads((BASE / 'inputs.json').read_bytes())
    for value in values:
        path = Path(value['path'])
        if path.is_symlink() or not path.is_file():
            raise ValueError('Non-regular Foundation input: ' + str(path))
        if path.stat().st_size != value['bytes'] or sha(path) != value['sha256']:
            raise ValueError('Foundation source changed: ' + str(path))
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output
    if not output.is_absolute() or output.parent.resolve() != output.parent:
        raise ValueError('Use a fresh canonical absolute output path')
    before = verify_inputs()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    command = [value.replace('FRESH_OUTPUT', str(output)) for value in
               json.loads((BASE / 'compile-command.json').read_bytes())]
    receipt = dict(schema='padded_control_frame_foundation_v1', inputs=before, steps=[],
                   sourceOnlyFixture=True, modelExecuted=False, remoteExecuted=False,
                   rdmaExecuted=False, status='started')

    def save():
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')

    def run(name, argv, limit):
        step = dict(name=name, argv=argv)
        receipt['steps'].append(step)
        start = time.monotonic()
        try:
            with (output / (name + '.stdout')).open('xb') as stdout, (output / (name + '.stderr')).open('xb') as stderr:
                invoke_controller(argv, stdout, stderr, step, timeout=limit)
        finally:
            step['elapsedSeconds'] = time.monotonic() - start
            for suffix in ['stdout', 'stderr']:
                path = output / (name + '.' + suffix)
                if path.exists():
                    step[suffix + 'SHA256'] = sha(path)
                    step[suffix + 'Bytes'] = path.stat().st_size
            save()
        if step.get('exitCode') != 0 or not step.get('reaped') or not step.get('groupAbsent'):
            raise RuntimeError('Owned child did not pass and retire: ' + name)
        if step.get('failure') or step['stdoutBytes'] > 1_048_576 or step['stderrBytes'] > 4_194_304:
            raise RuntimeError('Owned child failed or exceeded diagnostic bounds: ' + name)

    try:
        run('compile', command, 60)
        run('fixture', [str(output / 'control-frame-controls')], 10)
        value = json.loads((output / 'fixture.stdout').read_bytes())
        expected = json.loads((BASE / 'expected-checks.json').read_bytes())
        if value != dict(passed=expected, nativeExecuted=False, frameBytes=16_384, maximumPayloadBytes=16_380, allFieldsControlJSONBytes=434):
            raise ValueError('Actual control coverage/limits differ')
        if verify_inputs() != before:
            raise ValueError('Foundation inputs changed')
        receipt.update(status='passed', checks=expected, sourceInputsUnchanged=True)
    except BaseException as error:
        receipt.update(status='failed', failure=type(error).__name__ + ': ' + str(error))
        try:
            receipt['sourceInputsUnchanged'] = verify_inputs() == before
        except BaseException as changed:
            receipt['sourceRecheckError'] = str(changed)
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
