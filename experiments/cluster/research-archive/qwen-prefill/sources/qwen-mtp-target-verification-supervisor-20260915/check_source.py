"""Pure/local-file checks only. Never launches the GPU binary or remote commands."""
import ast
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT/'package'))
from binding_common import canonical, require
from target_contract import EXPECTED, validate_result
from target_inputs import Pins, verify_package
from target_processes import parse_processes


def refuses(callback):
    try: callback()
    except (ValueError, OSError): return
    raise AssertionError('Expected refusal')


def main():
    checked = []
    for p in sorted(ROOT.rglob('*.py')):
        ast.parse(p.read_text()); checked.append(str(p.relative_to(ROOT)))
    validate_result(canonical(EXPECTED))
    bad = []
    for key in ['modelExecution','bilateralVerification']:
        value=copy.deepcopy(EXPECTED); value[key]=True; bad.append(canonical(value))
    value=copy.deepcopy(EXPECTED); value['fabricatedNativeArrays']=1; bad.append(canonical(value))
    for passed in [EXPECTED['passed'][:-1], EXPECTED['passed']+[EXPECTED['passed'][0]], list(reversed(EXPECTED['passed']))]:
        value=copy.deepcopy(EXPECTED); value['passed']=passed; bad.append(canonical(value))
    bad.extend([b'{}', b'{"modelExecution":false,"modelExecution":false}', b'x'*16385])
    for raw in bad: refuses(lambda: validate_result(raw))
    rows=parse_processes(b'0 0 kernel_task\n123 501 /tmp/TargetVerificationCheck\n124 501 /tmp/cluster-inference\n125 501 /tmp/owner-controller\n126 501 /usr/bin/python3\n')
    require([x['pid'] for x in rows['prohibited']] == [123,124,125], 'Process family coverage')
    with tempfile.TemporaryDirectory(prefix='target-check-', dir='/private/tmp') as directory:
        path=Path(directory)/'input';path.write_bytes(b'bound');os.chmod(path,0o600)
        pins=Pins();pins.read(path,5,hashlib.sha256(b'bound').hexdigest());pins.recheck()
        path.write_bytes(b'wrong');refuses(pins.recheck)
        link=Path(directory)/'link';link.symlink_to(path);refuses(lambda: Pins().read(link,5,hashlib.sha256(b'wrong').hexdigest()))
    lineage=json.loads((ROOT/'lineage.json').read_text())
    for row in lineage['files']:
        if row['unchanged']:
            require((ROOT/'package'/row['path']).read_bytes() == Path(row['source']).read_bytes(), 'Copied helper changed')
    package=ROOT/'package/package.json'
    pins=Pins();verified=verify_package(ROOT/'package',hashlib.sha256(package.read_bytes()).hexdigest(),pins);pins.recheck()
    result=dict(status='passed', syntaxFiles=checked, exactResultAccepted=True,
        malformedResultsRefused=len(bad), knownProcessNamesChecked=3, fileGroups=3,
        package=verified, nativeExecuted=False, remoteExecuted=False, processChildrenLaunched=0)
    (ROOT/'source-checks.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,sort_keys=True))


if __name__ == '__main__': main()
