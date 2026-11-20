"""Pure Go test discovery/coverage checks; no execution or filesystem mutation."""
import re
from inputs import GO_PACKAGES, NATIVE_PAIR_METHODS

PREFIX = 'github.com/eigeninference/d-inference/'
PACKAGES = tuple(PREFIX + package for package in GO_PACKAGES)
API = PREFIX + 'coordinator/api'
API_BATCHES = 4


def package_completion(events, packages):
    if any(event.get('Action') == 'fail' for event in events):
        raise ValueError('Go reported a failure')
    complete = {event.get('Package') for event in events
                if event.get('Action') == 'pass' and 'Test' not in event}
    if complete != set(packages):
        raise ValueError('Go package completion differs from selection')


def discover(events):
    package_completion(events, PACKAGES)
    names = {package: [] for package in PACKAGES}
    benchmarks = {package: [] for package in PACKAGES}
    for event in events:
        if 'Test' in event:
            raise ValueError('Discovery unexpectedly ran a test')
        if event.get('Action') != 'output' or event.get('Package') not in names:
            continue
        for line in event.get('Output', '').splitlines():
            if not line.startswith(('Test', 'Example', 'Fuzz', 'Benchmark')):
                continue
            if not line.isidentifier():
                raise ValueError('Ambiguous compiled test-list output')
            selected = benchmarks if line.startswith('Benchmark') else names
            selected[event['Package']].append(line)
    for package in PACKAGES:
        if not names[package] or len(set(names[package])) != len(names[package]):
            raise ValueError('Empty or duplicate compiled discovery')
        if len(set(benchmarks[package])) != len(benchmarks[package]):
            raise ValueError('Duplicate compiled benchmark discovery')
        names[package].sort(); benchmarks[package].sort()
    # Round-robin a stable sorted list: exhaustive, disjoint and balanced by
    # entry count. No inferred source-name inventory or elapsed-time timeout growth.
    batches = [names[API][index::API_BATCHES] for index in range(API_BATCHES)]
    if any(not batch for batch in batches) or sorted(name for batch in batches for name in batch) != names[API]:
        raise ValueError('API batch partition is incomplete')
    for batch in batches:
        exact_filter(batch)
    return {'packages': names, 'excludedBenchmarks': benchmarks, 'apiBatches': batches}


def exact_filter(names):
    if not names or len(names) != len(set(names)) or any(not name.isidentifier() for name in names):
        raise ValueError('Invalid exact test selection')
    expression = '^(' + '|'.join(re.escape(name) for name in names) + ')$'
    if len(expression.encode()) > 65_536:
        raise ValueError('Exact test selection exceeds bounded argument')
    return expression


def completed(events, expected=None):
    packages = set(expected) if expected is not None else set(PACKAGES)
    package_completion(events, packages)
    result = {package: {} for package in packages}
    for event in events:
        name, action = event.get('Test'), event.get('Action')
        if not name or '/' in name or action not in ('pass', 'skip'):
            continue
        package = event.get('Package')
        if package not in result or name in result[package]:
            raise ValueError('Unexpected or duplicate top-level test result')
        result[package][name] = action
    if expected is not None and any(set(result[package]) != set(names) for package, names in expected.items()):
        raise ValueError('Discovered top-level test omitted or unintended test executed')
    return result


def combine(parts, expected):
    result = {package: {} for package in expected}
    for part in parts:
        for package, entries in part.items():
            if package not in result or set(entries) & set(result[package]):
                raise ValueError('Overlapping or unexpected batch coverage')
            result[package].update(entries)
    if any(set(result[package]) != set(names) for package, names in expected.items()):
        raise ValueError('Aggregate does not cover every compiled top-level entry')
    return result


def require_feature_passes(coverage, *, full=False):
    passed = {name for entries in coverage.values() for name, status in entries.items() if status == 'pass'}
    verified = {name for name in passed if name.startswith('TestVerifiedPair')}
    member = {name for name in passed if name.startswith(('TestClusterMember', 'TestMemberRole'))}
    native = {name for name in passed if name.startswith('TestNativePair')}
    if len(verified) != 15 or len(member) != 4 or native != NATIVE_PAIR_METHODS:
        raise ValueError('Required pair/member/native tests did not all pass')
    if full and not {'TestLatestProviderVersionMatchesProviderCore',
                     'TestTelemetryAllowlistThreeWayParity',
                     'TestTelemetryAllowlistKnownGapsAreStillReal'}.issubset(passed):
        raise ValueError('Real cross-language source checks did not pass')
    return {'verifiedPairMethods': len(verified), 'memberMethods': len(member),
            'nativePairMethods': len(native), 'nativePairPassed': sorted(native),
            'totalMethods': sum(len(entries) for entries in coverage.values()),
            'passedMethods': sum(status == 'pass' for entries in coverage.values() for status in entries.values()),
            'ordinaryExplicitSkips': [{'package': package, 'name': name} for package, entries in sorted(coverage.items())
                                      for name, status in sorted(entries.items()) if status == 'skip'],
            'apiHandlerPackageCompiled': True, 'apiTestsSelected': True, 'raceDetector': True}
