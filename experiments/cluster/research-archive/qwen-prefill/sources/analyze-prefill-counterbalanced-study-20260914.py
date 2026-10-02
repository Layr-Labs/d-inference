#!/usr/bin/env python3
"""Descriptive analysis fixed before prospective fresh-cohort observations."""
import hashlib
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parent
STUDY = ROOT / 'runs/qwen-prefill-cold-cohort-study-20260914'
PLAN_SHA = '5c139f3cac933564717cef67e32256d12010a91ae14c5c2f195fe63bf46af107'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summarize(plan, receipt):
    assert receipt['passed'] is True and receipt['error'] is None
    assert receipt['cleanupError'] is None and receipt['commandCleanupErrors'] == []
    assert receipt['throughputQualified'] is False and receipt['residentWarmthQualified'] is False
    assert receipt['physicalTwoMachineExecution'] is False
    trials = receipt['completedTrials']
    assert len(trials) == len(plan['trials']) == 14
    assert len({row['epoch'] for row in trials}) == len({row['run'] for row in trials}) == 14
    for expected, actual in zip(plan['trials'], trials):
        assert all(actual[key] == value for key, value in expected.items())
        assert type(actual['elapsedNanoseconds']) is int and actual['elapsedNanoseconds'] > 0
    pairs = []
    for index in range(1, 7):
        rows = [row for row in trials if row['role'] == 'measured' and row['pair'] == index]
        assert len(rows) == 2 and {row['label'] for row in rows} == {'A', 'B'}
        a, b = [next(row for row in rows if row['label'] == label)['elapsedNanoseconds'] for label in ('A', 'B')]
        pairs.append(dict(pair=index, order=''.join(row['label'] for row in rows),
            serialNanoseconds=a, lookaheadNanoseconds=b,
            serialMinusLookaheadNanoseconds=a-b, serialDurationDividedByLookaheadDuration=a/b))
    def stats(values):
        return dict(count=len(values), median=statistics.median(values), minimum=min(values), maximum=max(values))
    return dict(kind='prefill_fresh_cohort_descriptive_analysis', schemaVersion=1,
        pairedObservationCount=6, excludedPrimingTrialsByDesign=2,
        chronologicalTrials=trials, pairs=pairs,
        measuredDurationNanoseconds={label: stats([row['elapsedNanoseconds'] for row in trials
            if row['role'] == 'measured' and row['label'] == label]) for label in ('A', 'B')},
        pairedDurationRatios=stats([row['serialDurationDividedByLookaheadDuration'] for row in pairs]),
        pairedDurationRatiosByOrder={order: stats([row['serialDurationDividedByLookaheadDuration']
            for row in pairs if row['order'] == order]) for order in ('AB', 'BA')},
        throughputQualified=False, residentWarmthQualified=False, physicalTwoMachineExecution=False,
        samplesTrimmed=0, significanceTestPerformed=False,
        interpretation='Short fresh-process diagnostic on one GPU. Ratios do not qualify causal scheduling acceleration, resident throughput or physical-cluster performance.')


def main():
    plan_path = ROOT / 'prefill-counterbalanced-study-plan-20260914.json'
    assert sha(plan_path) == PLAN_SHA
    plan = json.loads(plan_path.read_text())
    assert (STUDY / 'plan.json').read_bytes() == plan_path.read_bytes()
    receipt_path = STUDY / 'study-receipt.json'
    receipt = json.loads(receipt_path.read_text())
    assert receipt['planSHA256'] == PLAN_SHA
    for row in receipt['completedTrials']:
        run = Path(row['run'])
        assert run.parent == STUDY
        for filename, key in [('receipt.json', 'launcherReceiptSHA256'),
                              ('independent-provenance-audit.json', 'provenanceSHA256'),
                              ('independent-cpu-comparison.json', 'comparisonSHA256')]:
            assert sha(run / filename) == row[key]
        assert sha(STUDY / (run.name + '-postflight.json')) == row['postflightSHA256']
        assert json.loads((STUDY / (run.name + '-result.json')).read_text()) == row
    value = summarize(plan, receipt)
    value.update(planSHA256=PLAN_SHA, studyReceiptSHA256=sha(receipt_path), analysisScriptSHA256=sha(Path(__file__)))
    out = STUDY / 'descriptive-analysis.json'
    with out.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write('\n')
    print(json.dumps(dict(output=str(out), sha256=sha(out), measuredDurationNanoseconds=value['measuredDurationNanoseconds'],
        pairedDurationRatios=value['pairedDurationRatios'], pairedDurationRatiosByOrder=value['pairedDurationRatiosByOrder']), sort_keys=True))


if __name__ == '__main__':
    main()
