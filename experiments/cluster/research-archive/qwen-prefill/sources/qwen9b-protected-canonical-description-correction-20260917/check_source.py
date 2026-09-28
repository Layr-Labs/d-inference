"""Small source/golden checks only; never imports/builds/runs the native product."""
import ast
import base64
import hashlib
import json
from pathlib import Path
import re

BASE = Path(__file__).resolve().parent
RUNTIME = Path('libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')
UPSTREAM = BASE.parent / 'qwen9b-native-protected-transport-draft-20260917'
MAIN = Path('/Users/developer/DarkbloomDev/d-inference')
EXPECTED_POLICY = '17cc0e02c144ef20fd4a489aa8c602069639d0005bfaf3dfea1762e46e6d5cf2'

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def corrected(original):
    opening = 'try JSONSerialization.data(withJSONObject: ['
    closing = '] as [String: Any], options: [.sortedKeys, .withoutEscapingSlashes])'
    result = original
    for record in ['QwenProtectedResourcePolicyRecord', 'QwenProtectedRuntimeDescriptionRecord']:
        start = result.index(opening)
        end = result.index(closing, start)
        body = re.sub(r'"([A-Za-z0-9_]+)":', r'\1:', result[start + len(opening):end])
        body = body.replace('servingEnabled: false,\n', 'servingEnabled: false\n')
        result = result[:start] + 'try canonicalJSONData(' + record + '(' + body + '))' + result[end + len(closing):]
    return result

def check():
    before = BASE / 'originals' / RUNTIME / 'QwenProtectedExperimentContract.swift'
    after = BASE / 'proposed' / RUNTIME / before.name
    if sha(before) != 'da3cf391fb0597b1b114ff4277d96308bfd2a874e32d67fc18302171f68d4b8c':
        raise ValueError('Original protected producer changed')
    if before.read_bytes() != (UPSTREAM/'proposed'/RUNTIME/before.name).read_bytes():
        raise ValueError('Original producer lineage differs')
    if corrected(before.read_text()) != after.read_text():
        raise ValueError('Correction changes fields, values or unrelated producer bytes')
    source = after.read_text()
    constants = source[source.index('    public static let identifier'):source.index('    static func limits()')]
    policy = source[source.index('    static func resourcePolicyBytes()'):source.index('    static func requireWorkload')]
    fixture = 'import Foundation\n\n// Exact extracted production constants + resourcePolicyBytes; checked before compilation.\nenum QwenProtectedFixturePolicy {\n' + constants + policy + '}\n'
    if fixture != (BASE/'Tests/PolicyProducer.swift').read_text():
        raise ValueError('Foundation fixture is not the exact production policy slice')
    if (BASE/'Tests/CanonicalJSON.swift').read_bytes() != (MAIN/RUNTIME/'CanonicalJSON.swift').read_bytes():
        raise ValueError('Shared canonical encoder differs')
    if (BASE/'Tests/QwenProtectedSourceBindings.swift').read_bytes() != (UPSTREAM/'proposed'/RUNTIME/'QwenProtectedSourceBindings.swift').read_bytes():
        raise ValueError('Source binding values differ')
    contract = json.loads((BASE/'fixtures/description-contract.json').read_text())
    raw = (BASE/'fixtures/resource-policy.canonical.json').read_bytes()
    canonical = lambda v: json.dumps(v, sort_keys=True, separators=(',', ':')).encode()
    if raw != canonical(contract['resourcePolicy']) or hashlib.sha256(raw).hexdigest() != EXPECTED_POLICY:
        raise ValueError('Independent 17cc policy golden differs')
    observed = json.loads((BASE/'fixtures/observed-native-description.json').read_bytes())
    if observed['resourcePolicySHA256'] != '95fb5106714851461debd3297883f901a75c26fc1138e378880b40780a2c9f80':
        raise ValueError('Actual failed native description differs')
    if json.loads(base64.b64decode(observed['resourcePolicyBase64'], validate=True)) != contract['resourcePolicy']:
        raise ValueError('Actual failed policy is not semantically identical')
    observed['resourcePolicyBase64'] = base64.b64encode(raw).decode()
    observed['resourcePolicySHA256'] = EXPECTED_POLICY
    if len(observed) != 26 or canonical(observed) + b'\n' != (BASE/'fixtures/description.canonical.json').read_bytes():
        raise ValueError('Descriptor golden changes fields beyond canonical policy bytes/hash')
    if (BASE/'manifest.json').exists():
        for row in json.loads((BASE/'manifest.json').read_text())['files']:
            p = BASE/row['path']
            if not p.is_file() or p.is_symlink() or p.stat().st_size != row['bytes'] or sha(p) != row['sha256']:
                raise ValueError('Frozen correction member changed')
    for p in BASE.glob('*.py'):
        ast.parse(p.read_text())
    return dict(passed=True, sourceOnly=True, replacementFiles=1, newTypedRecordFiles=1,
                productionPolicySliceExact=True, originalFieldsAndValuesUnchanged=True,
                expectedPolicySHA256=EXPECTED_POLICY, goldenDescriptorFields=26,
                ordinaryCapabilityBytesUnchanged=True, compilerExecuted=False, nativeExecuted=False)

if __name__ == '__main__':
    print(json.dumps(check(), sort_keys=True))
