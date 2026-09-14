"""Validate CI sample identity and summarize paired inner workload timings."""
import math
import statistics
import hashlib
import json
from pathlib import PurePosixPath
import tarfile

from sandbox_ci_bundle import WORKLOAD


def valid_digest(value):
    return isinstance(value, str) and len(value) == 64 and all(char in '0123456789abcdef' for char in value)


def validate_sample(sample, manifest_hash, manifest):
    if not isinstance(sample, dict):
        raise ValueError('CI sample must be a JSON object')
    expected = {'schema_version': 1, 'workload': WORKLOAD, 'status': 'passed',
                'manifest_sha256': manifest_hash, 'go_version': manifest['go_version'],
                'goos': manifest['goos'], 'goarch': manifest['goarch'],
                'gomaxprocs': manifest['gomaxprocs'], 'fresh_gocache': True}
    if any(type(sample.get(key)) is not type(value) or sample.get(key) != value for key, value in expected.items()):
        raise ValueError('CI sample input, toolchain, or cache identity mismatch')
    for key in ('build_seconds', 'test_seconds', 'inner_seconds'):
        value = sample.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            raise ValueError('CI timings must be positive and finite')
    if not math.isclose(sample['inner_seconds'], sample['build_seconds'] + sample['test_seconds'], rel_tol=1e-8):
        raise ValueError('CI inner time must equal build plus test time')
    artifacts = sample.get('artifacts_sha256', {})
    if not isinstance(artifacts, dict) or set(artifacts) != {'probe', 'tests-0', 'tests-1', 'tests-2'} or not all(valid_digest(value) for value in artifacts.values()):
        raise ValueError('CI compiled artifact evidence is incomplete')
    tests = sample.get('tests', [])
    packages = {'./coordinator/protocol', './coordinator/sandboxhost', './coordinator/sandboxcontrol'}
    if not isinstance(tests, list) or len(tests) != 3 or not all(isinstance(test, dict) for test in tests) or {test.get('package') for test in tests} != packages:
        raise ValueError('CI unit-test package evidence is incomplete')
    if any(test.get('package_passed') is not True or type(test.get('skipped')) is not int or test.get('skipped') != 0 or
           type(test.get('passed')) is not int or test['passed'] <= 0 for test in tests):
        raise ValueError('CI unit tests failed, skipped work, or produced no cases')
    if not valid_digest(sample.get('evidence_sha256')):
        raise ValueError('CI raw evidence digest is missing')
    return sample


def summarize(pairs):
    if not pairs:
        raise ValueError('no paired CI measurements')
    ratios = {key: [] for key in ('build_seconds', 'test_seconds', 'inner_seconds')}
    for pair in pairs:
        host, guest = pair['host'], pair['guest']
        for key in ('manifest_sha256', 'artifacts_sha256', 'tests', 'go_version', 'goos', 'goarch', 'gomaxprocs'):
            if host[key] != guest[key]:
                raise ValueError('host and guest CI workload or compiled results differ')
        for key in ratios:
            ratios[key].append(guest[key] / host[key])
    return {'pair_count': len(pairs), 'median_guest_over_host': {key: statistics.median(values) for key, values in ratios.items()},
            'median_guest_api_wall_seconds': statistics.median(pair['guest']['caller_wall_seconds'] for pair in pairs),
            'median_host_caller_wall_seconds': statistics.median(pair['host']['caller_wall_seconds'] for pair in pairs),
            'timing_scope': 'inner_seconds includes only probe/test compilation and probe/test execution; transport, unpacking, hashing, and evidence archiving excluded'}


def verify_evidence_archive(path, sample):
    """Independently hash retained binaries instead of trusting result labels."""
    found = {}
    total = 0
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive:
            if len(found) >= 128:
                raise ValueError('CI evidence archive has too many members')
            if not member.isfile() or PurePosixPath(member.name).name != member.name or member.name in found:
                raise ValueError('unsafe or duplicate CI evidence archive member')
            total += member.size
            if member.size < 0 or total > 256 * 1024 * 1024:
                raise ValueError('CI evidence archive exceeds byte limit')
            with archive.extractfile(member) as content:
                if member.name == 'sample.json':
                    if member.size > 64 * 1024:
                        raise ValueError('CI sample metadata exceeds byte limit')
                    retained = json.load(content)
                    for key in ('workload', 'status', 'manifest_sha256', 'run_id', 'artifacts_sha256', 'tests', 'build_seconds', 'test_seconds'):
                        if retained.get(key) != sample.get(key):
                            raise ValueError('retained CI sample differs from runner response')
                    found[member.name] = True
                else:
                    found[member.name] = hashlib.file_digest(content, 'sha256').hexdigest()
    if 'sample.json' not in found or any(found.get(name) != expected for name, expected in sample['artifacts_sha256'].items()):
        raise ValueError('compiled CI artifact content does not match retained evidence')
