#!/usr/bin/env python3
"""Run only the approved Provider regression selection in the private copy."""
import importlib.util, json, os, signal, subprocess, sys, time
from pathlib import Path

sys.dont_write_bytecode = True
PLAN = Path('/Users/developer/DarkbloomDev/cluster-research/distributed-http-terminal-delivery-integration-plan')
spec = importlib.util.spec_from_file_location('preparation', PLAN / 'prepare-private.py')
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)
output = Path(sys.argv[1]).resolve()
record = json.loads((output / 'preparation.json').read_text())
workspace, source = Path(record['workspace']), Path(record['source'])
before = json.loads((output / 'candidate-source-before-3.json').read_text())
main_before = json.loads((output / 'main-source-before.json').read_text())
assert prep.inventory(workspace) == before
assert prep.inventory(source) == main_before
integration = json.loads((output / 'integration-3.json').read_text())
for item in integration['files']:
    assert prep.sha(workspace / item['path']) == item['sha256']
run = output / 'provider-tests-3'
run.mkdir(exist_ok=False)
command = integration['swiftCommand']
began = time.monotonic()
with (run / 'stdout.txt').open('wb') as stdout, (run / 'stderr.txt').open('wb') as stderr:
    child = subprocess.Popen(command, cwd=workspace / 'provider-swift', stdout=stdout, stderr=stderr,
                             start_new_session=True)
    prep.save(run / 'launch.json', {'command': command, 'cwd': str(workspace / 'provider-swift'),
                                  'pid': child.pid, 'timeoutSeconds': 1200})
    print(f'Provider Swift test PID {child.pid}; stdout/stderr in {run}', flush=True)
    timed_out = False
    try:
        code = child.wait(timeout=1200)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(child.pid, signal.SIGTERM)
        try:
            code = child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            code = child.wait()
after, main_after = prep.inventory(workspace), prep.inventory(source)
prep.save(run / 'candidate-source-after.json', after)
prep.save(run / 'main-source-after.json', main_after)
result = {'command': command, 'exitCode': code, 'elapsedSeconds': time.monotonic() - began,
          'timedOut': timed_out, 'candidateSourceUnchanged': after == before,
          'mainSourceUnchanged': main_after == main_before,
          'stdoutSHA256': prep.sha(run / 'stdout.txt'), 'stderrSHA256': prep.sha(run / 'stderr.txt')}
prep.save(run / 'execution.json', result)
print(json.dumps(result, indent=2), flush=True)
sys.exit(0 if code == 0 and after == before and main_after == main_before else 1)
