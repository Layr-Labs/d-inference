"""Root integration: public scheduler + private adapter + fabricated pipe peers.

Every prompt, device, duration and callback validation here is fabricated.
No native executable, model, network or actual resource gate is invoked.
"""

import hashlib
import json
import os
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parent
DRAFT = ROOT.parent / 'resident-benchmark-worker-adapter-v2'
PUBLIC = ROOT.parents[1] / 'd-inference/experiments/cluster'
sys.path[:0] = [str(DRAFT), str(PUBLIC)]

from benchmarking.coordinator import run_study
from benchmarking.test_specification import study_document
from worker_adapter import ResidentWorkerCohort
from worker_contract import WorkerSpec


def save(path, value):
    raw = (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as handle:
        handle.write(raw)
    return hashlib.sha256(raw).hexdigest()


class Factory:
    def __init__(self, directory, failure):
        self.directory, self.failure = directory, failure
        self.cohorts, self.calls, self.gates = [], 0, []

    def __call__(self, study, cohort):
        index = len(self.cohorts)
        condition = next(row for row in study['conditions'] if row['id'] == cohort['condition_id'])
        role = 'solo' if condition['role'] == 'solo' else 'rank'
        mode = 'nonzero-exit' if self.failure == 'final-close' and index == 19 else 'success'
        specs = [WorkerSpec((sys.executable, '-B', '-u', str(DRAFT / 'fake_worker.py'), mode, role,
                             'none' if role == 'solo' else str(rank)),
                            {'PYTHONDONTWRITEBYTECODE': '1'}, role, None if role == 'solo' else rank)
                 for rank in range(1 if role == 'solo' else 2)]
        declared = [dict(request_id=row['request_id'],
                         epoch=hashlib.sha256(('fabricated:' + row['request_id']).encode()).hexdigest()[:32])
                    for row in cohort['requests']]

        def identity(spec, event, command):
            if event['type'] == 'result':
                step = event['record']['step']
                assert step['requestID'] == str(uuid.UUID(command['epoch']))
                assert type(step['ordinal']) is int and step['ordinal'] == command['sequence'] - 1
                assert type(step['excludedWarmup']) is bool and step['excludedWarmup'] == (command['sequence'] == 1)
            # Only the fake fixture's fields are checked. This cannot validate a
            # real runtime identity, resource observation or numerical result.

        def numerical(command, events):
            self.calls += 1
            if self.failure == 'warmup' and self.calls == 1:
                raise ValueError('Fabricated first warmup numerical refusal')
            assert all(row['record']['execution']['selection'] == 1 for row in events)
            digest = hashlib.sha256(json.dumps(events, sort_keys=True).encode()).hexdigest()
            return dict(elapsed_ns=1_000_000_000, prompt_tokens=8192, generated_tokens=1, source_sha256=digest)

        worker = ResidentWorkerCohort(specs, cohort['cohort_id'], declared,
            self.directory / ('cohort-%02d' % index), timeout_seconds=10,
            resource_gate=self.gates.append, identity_validator=identity, numerical_validator=numerical)
        self.cohorts.append(worker)
        return worker


def main():
    directory = ROOT / sys.argv[1]
    directory.mkdir(mode=0o700)
    results = []
    for case in ('complete', 'warmup', 'final-close'):
        case_dir = directory / case
        case_dir.mkdir(mode=0o700)
        factory = Factory(case_dir, case)
        result = run_study(study_document(), factory)
        expected_complete = case == 'complete'
        assert result['summary']['aggregate_status'] == ('complete' if expected_complete else 'incomplete')
        assert len(factory.cohorts) == (1 if case == 'warmup' else 20)
        assert factory.calls == (1 if case == 'warmup' else 80)
        evidence = [cohort.evidence() for cohort in factory.cohorts]
        assert all(all(row['returncode'] is not None for row in item['workers']) for item in evidence)
        assert all(not item['performance_qualification'] and not item['runtime_admission'] for item in evidence)
        if expected_complete:
            assert all(item['stopped'] and item['output_complete'] and not item['failed'] for item in evidence)
        completed = sum(row['status'] == 'completed' for row in result['outcomes'])
        assert completed == (0 if case == 'warmup' else 80)
        receipt = dict(case=case, fabricated=True, cpu_only=True, native_executed=False,
                       cohorts=len(factory.cohorts), coordinator_requests=factory.calls,
                       worker_processes=sum(len(item['workers']) for item in evidence),
                       aggregate_status=result['summary']['aggregate_status'], completed_outcomes=completed,
                       result_sha256=save(case_dir / 'study-result.json', result),
                       transport_evidence_sha256=save(case_dir / 'transport-evidence.json', evidence))
        results.append(receipt)
    record = dict(schema='fabricated_coordinator_pipe_integration_v1', python=sys.version,
                  cpu_only=True, native_executed=False, numerical_correctness_established=False,
                  performance_qualification=False, cases=results)
    pin = save(directory / 'execution.json', record)
    print(json.dumps(dict(execution_sha256=pin, cases=results), sort_keys=True))


if __name__ == '__main__':
    main()
