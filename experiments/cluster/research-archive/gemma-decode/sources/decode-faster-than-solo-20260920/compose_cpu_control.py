"""Apply the reviewed host-control-only fence change to the d785 composition."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent
WORK = ROOT.parent / 'gemma4-execution-20260920/build/workspace'
BASE = ROOT.parent / 'gemma4-decode-optimization-20260920/build/applied-control-frame.json'
DRAFT = ROOT / 'guard-audit/cpu-control'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(path):
    return dict(path=str(path.relative_to(WORK)), bytes=path.stat().st_size, sha256=sha(path))


def main():
    assert sha(BASE) == 'a2d46fa985b4f78bb2dde0dcb5bae3706a3e76fd3b0154a4554ef3eeee42e343'
    base = json.loads(BASE.read_bytes())
    for row in base['files']:
        assert record(WORK / row['path']) == row, row['path']
    integration = json.loads((DRAFT / 'integration.json').read_bytes())
    assert integration['baselineNativeSHA256'] == 'd7859728bbda3c1b4a0d65766e1bc44b964143d6e7b493e944fb05d3e09ca769'
    assert not integration['checksRemoved'] and not integration['resourceTermsChanged']
    output = ROOT / 'build'
    output.mkdir(mode=0o700)
    preserve = output / 'before-cpu-control'
    for row in integration['changes']:
        current = WORK / row['path']
        proposed = DRAFT / 'proposed' / row['path']
        assert sha(current) == row['beforeSHA256']
        assert sha(proposed) == row['afterSHA256']
        backup = preserve / row['path']
        backup.parent.mkdir(parents=True, exist_ok=True)
        with backup.open('xb') as stream:
            stream.write(current.read_bytes())
    for row in integration['changes']:
        (WORK / row['path']).write_bytes((DRAFT / 'proposed' / row['path']).read_bytes())
    names = {row['path'] for row in base['files']} | {row['path'] for row in integration['changes']}
    result = dict(schema='gemma4_cpu_control_composition_v1', baselineSourcesSHA256=sha(BASE),
                  integrationSHA256=sha(DRAFT / 'integration.json'),
                  changes=integration['changes'],
                  files=[record(WORK / name) for name in sorted(names)])
    with (output / 'applied-cpu-control.json').open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps(dict(status='passed', sourcesSHA256=sha(output / 'applied-cpu-control.json'),
                         files=len(result['files']))))


if __name__ == '__main__':
    main()
