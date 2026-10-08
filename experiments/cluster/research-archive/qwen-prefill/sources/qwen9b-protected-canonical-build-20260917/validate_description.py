"""Validate actual metadata output; no candidate output is an expected input."""
import base64
import hashlib
import json
from pathlib import Path


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def parsed(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise ValueError('Duplicate metadata field')
            value[key] = item
        return value
    return json.loads(raw, object_pairs_hook=pairs)


def validate(ordinary_raw, protected_raw, binary_sha, contract_path):
    contract = parsed(Path(contract_path).read_bytes())
    if len(protected_raw) > 32768 or len(ordinary_raw) > 16384:
        raise ValueError('Metadata response exceeds bound')
    ordinary, protected = parsed(ordinary_raw), parsed(protected_raw)
    if canonical(ordinary) + b'\n' != ordinary_raw or canonical(protected) + b'\n' != protected_raw:
        raise ValueError('Metadata response is not its exact canonical object')
    if set(protected) != set(contract['schema']['fields']):
        raise ValueError('Protected response field set differs')
    for key, expected in contract['fixed'].items():
        actual = protected[key]
        if type(actual) is not type(expected) or actual != expected:
            raise ValueError('Protected description differs: ' + key)
    if protected['runtimeBinarySHA256'] != binary_sha or ordinary['runtimeBinarySHA256'] != binary_sha:
        raise ValueError('Actual executable pin differs')
    embedded = base64.b64decode(protected['ordinaryCapabilityBase64'], validate=True)
    if embedded != ordinary_raw or protected['capabilitySHA256'] != hashlib.sha256(ordinary_raw).hexdigest():
        raise ValueError('Ordinary metadata changed in protected description')
    plans = [p for p in ordinary['partitions'] if len(p['stages']) == 2 and
             p['stages'][0]['sourceLayerStart'] == 0 and p['stages'][0]['sourceLayerEnd'] == 16 and
             p['stages'][1]['sourceLayerStart'] == 16 and p['stages'][1]['sourceLayerEnd'] == 32]
    if len(plans) != 1 or protected['selectedPlanSHA256'] != plans[0]['planSHA256']:
        raise ValueError('Protected Plan differs from actual ordinary capability')
    if protected['profileFingerprint'] != ordinary['profileFingerprint']:
        raise ValueError('Protected profile differs from actual ordinary capability')
    policy_raw = base64.b64decode(protected['resourcePolicyBase64'], validate=True)
    expected_policy = canonical(contract['resourcePolicy'])
    if policy_raw != expected_policy or protected['resourcePolicySHA256'] != hashlib.sha256(expected_policy).hexdigest():
        raise ValueError('Protected resource policy differs from prospective source-bound contract')
    return dict(descriptorSHA256=hashlib.sha256(protected_raw).hexdigest(),
                capabilitySHA256=hashlib.sha256(ordinary_raw).hexdigest(),
                resourcePolicySHA256=protected['resourcePolicySHA256'],
                selectedPlanSHA256=protected['selectedPlanSHA256'],
                profileFingerprint=protected['profileFingerprint'], fields=26,
                servingEnabled=False, physicalExecutionQualified=False)
