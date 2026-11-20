"""Small in-memory wrapper contracts; no compiler, children or filesystem writes."""
from go_coverage import API, PACKAGES, combine, completed, discover, exact_filter


def refused(body):
    try:
        body()
    except ValueError:
        return
    raise AssertionError('malformed or incomplete coverage admitted')


def run_checks():
    events = []
    for package in PACKAGES:
        names = ['TestAlpha', 'ExampleBeta', 'FuzzGamma', 'TestDelta', 'BenchmarkIgnored']
        events += [{'Action': 'output', 'Package': package, 'Output': name + '\n'} for name in names]
        events += [{'Action': 'pass', 'Package': package}]
    catalog = discover(events)
    assert catalog['packages'][API] == ['ExampleBeta', 'FuzzGamma', 'TestAlpha', 'TestDelta']
    assert catalog['excludedBenchmarks'][API] == ['BenchmarkIgnored']
    assert all(len(batch) == 1 for batch in catalog['apiBatches'])
    assert exact_filter(['TestA', 'TestAB']) == '^(TestA|TestAB)$'
    refused(lambda: exact_filter(['TestA', 'TestA']))
    refused(lambda: exact_filter(['TestA|TestB']))
    refused(lambda: discover(events + [{'Action': 'output', 'Package': API, 'Output': 'TestAlpha\n'}]))
    expected = {API: ['TestAlpha', 'ExampleBeta', 'FuzzGamma']}
    outcomes = [{'Action': status, 'Package': API, 'Test': name}
                for name, status in [('TestAlpha', 'pass'), ('ExampleBeta', 'skip'), ('FuzzGamma', 'pass')]]
    outcomes += [{'Action': 'pass', 'Package': API}]
    result = completed(outcomes, expected)
    assert result[API]['ExampleBeta'] == 'skip'
    refused(lambda: completed(outcomes[1:], expected))
    refused(lambda: completed(outcomes + [{'Action': 'pass', 'Package': API, 'Test': 'TestOther'}], expected))
    refused(lambda: completed(outcomes + [outcomes[0]], expected))
    refused(lambda: completed(outcomes + [{'Action': 'fail', 'Package': API}], expected))
    assert combine([{API: {'TestAlpha': 'pass'}}, {API: {'ExampleBeta': 'skip', 'FuzzGamma': 'pass'}}], expected) == result
    refused(lambda: combine([result, result], expected))
    refused(lambda: combine([{API: {'TestAlpha': 'pass'}}], expected))
    return {'passed': True, 'testExampleFuzzIncluded': True, 'benchmarksExcluded': True,
            'skipRetained': True, 'missingUnexpectedDuplicateFailOverlappingRefused': True,
            'compilerOrChildExecuted': False}


if __name__ == '__main__':
    import json
    print(json.dumps(run_checks(), sort_keys=True))
