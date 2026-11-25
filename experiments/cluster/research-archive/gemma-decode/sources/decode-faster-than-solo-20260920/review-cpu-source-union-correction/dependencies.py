"""Import byte-pinned, unchanged physical and numerical validators."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
TASK = HERE.parent
OLD = TASK.parent / 'gemma4-decode-optimization-20260920'
HARNESS = TASK / 'harness-cpu'
sha = lambda raw: hashlib.sha256(raw).hexdigest()

def verify_inputs():
    value = json.loads((HERE / 'source-inputs.json').read_bytes())
    for row in value['files']:
        path = Path(row['path'])
        assert path.is_file() and not path.is_symlink() and path.stat().st_size == row['bytes']
        assert sha(path.read_bytes()) == row['sha256'], str(path)
    return value

verify_inputs()
sys.path.insert(0, str(OLD / 'review'))
import compare_three_roles as c
sys.path.insert(0, str(OLD / 'review-padded'))
spec = importlib.util.spec_from_file_location('retained_padded_comparison', OLD / 'review-padded/compare.py')
padded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(padded)
import decode_summary

exact, require = c.exact, c.require
BASELINE_NATIVE = 'd7859728bbda3c1b4a0d65766e1bc44b964143d6e7b493e944fb05d3e09ca769'
NATIVE = '4170caffc2f21238efea2ab115c4a3d43a105faedd78e62fbbad0e84b8e4d621'
BUILD = OLD / 'build/cpu-control-build-1.json'
APPLIED = TASK / 'build/applied-cpu-control.json'
INTEGRATION = TASK / 'guard-audit/cpu-control/integration.json'

def source_composition(build, applied, previous, integration):
    exact(build['exitCode'], 0, 'Actual compiler exit')
    for name, expected in dict(compilerReaped=True, groupAbsent=True, gpuExecuted=False).items():
        exact(build[name], expected, 'Actual build ' + name)
    exact(build['nativeSHA256'], NATIVE, 'Actual native')
    exact(build['nativeBytes'], 47_069_704, 'Actual binary size')
    exact(build['sourcesSHA256'], c.pin(APPLIED)['sha256'], 'Actual source composition')
    exact(applied['schema'], 'gemma4_cpu_control_composition_v1', 'Source schema')
    exact(applied['baselineSourcesSHA256'], c.pin(OLD / 'build/applied-control-frame.json')['sha256'], 'Padded ancestry')
    exact(applied['integrationSHA256'], c.pin(INTEGRATION)['sha256'], 'Reviewed CPU-control overlay')
    exact(applied['changes'], integration['changes'], 'Exact three source deltas')
    exact(len(integration['changes']), 3, 'Three changed files')
    before = {row['path']: row for row in previous['files']}
    after = {row['path']: row for row in applied['files']}
    exact(len(before), len(previous['files']), 'Unique before inventory')
    exact(len(after), len(applied['files']), 'Unique after inventory')
    changed = {row['path']: row for row in integration['changes']}
    exact(len(changed), 3, 'Unique changed paths')
    added = {'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/' + name
             for name in ('Collective.swift', 'CollectivePointToPoint.swift')}
    exact(set(after), set(before) | set(changed), 'Exact source inventory union')
    exact(set(after) - set(before), added, 'Two existing files newly tracked by this composition')
    for path in after:
        if path not in changed:
            exact(after[path], before[path], 'Unchanged source ' + path)
        else:
            delta = changed[path]
            preimage = TASK / 'guard-audit/cpu-control/preimages' / path
            prior = preimage.read_bytes()
            exact(sha(prior), delta['beforeSHA256'], 'Reviewed source preimage ' + path)
            if path in before:
                exact(before[path], dict(path=path, bytes=len(prior), sha256=sha(prior)), 'Prior inventory ' + path)
            source = TASK / 'guard-audit/cpu-control/proposed' / path
            raw = source.read_bytes()
            exact(sha(raw), delta['afterSHA256'], 'Frozen candidate ' + path)
            exact(after[path], dict(path=path, bytes=len(raw), sha256=sha(raw)), 'Applied source ' + path)

def contract(new, old):
    exact(len(new['samples']), 4, 'Complete candidate cohort')
    exact(len(old['samples']), 4, 'Complete baseline cohort')
    for a, b in zip(new['samples'], old['samples']):
        exact((a['ordinal'], a['warmup']), (b['ordinal'], b['warmup']), 'Exact sample identity')
        exact(len(a['frames']), len(b['frames']), 'Exact frame count')
    c.matched_workload(new, old)
    return dict(cadence=c.same_cadence(new, old), budget=c.same_budget(new, old))
