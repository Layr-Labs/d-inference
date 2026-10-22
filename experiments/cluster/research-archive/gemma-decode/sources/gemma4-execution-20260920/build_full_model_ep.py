"""Compose the reviewed full Gemma expert model and bounded correctness entry."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

from build_experts import ROOT, WORK, build, digest, verify

PACKAGES = [
    ('gemma4-full-model-ep-20260920', '0551be93dca80120478b59b961dc241dca9ce97ce42bacfb340e0f5975094251'),
    ('gemma4-full-model-ep-execution-20260920', 'a08249a6b0fff34660741dbf6d38ffc6ed49f64c0f7301f2fbefc41b10577745'),
]


def compose():
    prior_path = ROOT / 'build/applied-uncached-sidecars.json'
    assert digest(prior_path) == '8ec41c24385edfa16b66864ffbf4161de470dbb5b5c559d8a134243b102288a6'
    prior = json.loads(prior_path.read_bytes())
    for row in prior['files']:
        verify(WORK / row['path'], row)
    virtual, originals, steps = {}, {}, []
    for number, (name, expected) in enumerate(PACKAGES):
        source = ROOT.parent / name
        spec_path = source / 'source-inputs.json'
        assert digest(spec_path) == expected
        spec = json.loads(spec_path.read_bytes())
        for row in spec.get('files', []):
            verify(source / row['path'], row)
        for row in spec['dependencies']:
            assert digest(Path(row['path'])) == row['sha256'], row['path']
        for row in spec['overlays']:
            if number == 0 and row['candidate'] == 'Runtime/Gemma4BenchmarkResourceBudget.swift':
                continue
            incoming = source / row['candidate']
            verify(incoming, row)
            destination = row['destination']
            path = WORK / destination
            if destination not in originals:
                assert not path.is_symlink()
                originals[destination] = path.read_bytes() if path.exists() else None
            current = virtual.get(destination, originals[destination])
            if 'beforeSHA256' in row:
                import hashlib
                assert current is not None and hashlib.sha256(current).hexdigest() == row['beforeSHA256'], destination
            else:
                assert current is None, destination
            virtual[destination] = incoming.read_bytes()
            steps.append(dict(package=name, destination=destination, sha256=row['sha256']))
    # Verify the entire prospective composition before touching the disposable source.
    preserve = ROOT / 'build/before-full-model-ep'
    preserve.mkdir(mode=0o700)
    for destination, before in originals.items():
        if before is not None:
            path = preserve / destination
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('xb') as stream:
                stream.write(before)
    for destination, after in virtual.items():
        path = WORK / destination
        path.parent.mkdir(parents=True, exist_ok=True)
        if originals[destination] is None:
            with path.open('xb') as stream:
                stream.write(after)
        else:
            path.write_bytes(after)
    paths = sorted({row['path'] for row in prior['files']} | set(virtual))
    receipt = dict(prior)
    receipt.update(priorSourcesSHA256=digest(prior_path),
                   fullExpertSourceInputsSHA256=[item[1] for item in PACKAGES],
                   fullExpertOverlaySteps=steps,
                   files=[dict(path=name, bytes=(WORK/name).stat().st_size, sha256=digest(WORK/name)) for name in paths])
    out = ROOT / 'build/applied-full-model-ep.json'
    with out.open('x') as stream:
        json.dump(receipt, stream, indent=2)
    return receipt


def owned(command, name, seconds):
    folder = ROOT / 'build/full-model-ep-controls'
    folder.mkdir(mode=0o700, exist_ok=True)
    started = time.monotonic()
    log = folder / (name + '.log')
    with log.open('xb') as stream:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=seconds)
        except BaseException:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=10)
            raise
    try:
        os.killpg(child.pid, 0)
    except ProcessLookupError:
        group_absent = True
    else:
        group_absent = False
    result = dict(argv=command, exitCode=code, elapsedSeconds=time.monotonic()-started,
                  reaped=True, groupAbsent=group_absent, logSHA256=digest(log), gpuExecuted=False)
    with (folder/(name+'.json')).open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps(result), flush=True)
    assert code == 0 and group_absent, name


def main():
    for number, (name, _) in enumerate(PACKAGES):
        source = ROOT.parent / name
        owned(['/usr/bin/python3', '-B', str(source/'Tests/check_source.py')], f'source-{number}', 30)
    successor = ROOT.parent / PACKAGES[1][0]
    commands = json.loads((successor/'commands.json').read_bytes())
    (successor/'Build').mkdir(mode=0o700)
    owned(commands['foundationCompile'], 'schedule-build', 60)
    owned(commands['foundationRun'], 'schedule-checks', 30)
    predecessor = ROOT.parent / PACKAGES[0][0]
    before = json.loads((predecessor/'commands.json').read_bytes())
    (predecessor/'Build').mkdir(mode=0o700)
    owned(before['foundationCompile'], 'partition-build', 60)
    owned(before['foundationRun'], 'partition-checks', 30)
    sources = compose()
    build('GemmaExpertFullCorrectness', sources, attempt=1, source_receipt='applied-full-model-ep.json')


if __name__ == '__main__':
    main()
