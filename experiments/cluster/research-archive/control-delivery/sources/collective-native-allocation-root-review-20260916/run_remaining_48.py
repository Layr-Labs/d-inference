"""Root-owned fixed serial schedule through the reviewed per-case supervisor."""
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
BOUND = Path('/Users/developer/DarkbloomDev/cluster-research/collective-native-allocation-bound-supervisor-48-20260916')
assert hashlib.sha256((BOUND / 'manifest.json').read_bytes()).hexdigest() == 'c0279a736080d88209456a3b22db88fb71bdac63457b23ad1d51f0f22de27577'
sys.path.insert(0, str(BOUND))
import run_physical
from allocation_result import CASES

names = list(CASES)
assert len(names) == 35 and names[0] == 'fresh-u32-4'
first = json.loads((BOUND / 'physical-collect-fresh-u32-4-1/qualification.json').read_bytes())
assert first['passed'] and first['actualNativeCleanup'] and first['standaloneGateCleanup']
for index, name in enumerate(names[1:], 2):
    print(json.dumps({'startingCase': name, 'ordinal': index, 'totalCases': 35}), flush=True)
    for action in ('run', 'collect'):
        sys.argv = [str(BOUND / 'run_physical.py'), action, '--fixture', name, '--attempt', '1']
        code = run_physical.main()
        if code:
            raise SystemExit(code)
    result = json.loads((BOUND / ('physical-collect-' + name + '-1') / 'qualification.json').read_bytes())
    assert result['passed'] and result['actualNativeCleanup'] and result['standaloneGateCleanup']
    print(json.dumps({'completedCase': name, **result}, sort_keys=True), flush=True)

print(json.dumps({'passed': True, 'actualCases': 35, 'rdmaQualified': False,
                  'resourceProfileQualified': False, 'servingEnabled': False}), flush=True)
