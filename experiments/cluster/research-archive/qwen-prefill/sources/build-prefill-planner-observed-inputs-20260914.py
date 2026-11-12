"""Replay pinned local services and exercise public planning with unknown overhead.

CPU-only; predictions explicitly assume service transfer to independent devices.
No invented network latency, hardware memory budget or complete TTFT estimate.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

BASE = Path(__file__).resolve().parent
REPO = BASE.parent / 'd-inference'
PACKAGE = BASE / 'prefill-phase-service-map-draft'
OUT = BASE / 'runs/prefill-planner-observed-inputs-20260914'
MANIFEST_SHA = '60d386e9e6ddaaedabf9ab0c23bea16a63f4d9bd9750730c474041fdc330af5a'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(name, data):
    if not isinstance(data, bytes):
        data = (json.dumps(data, indent=2, sort_keys=True, allow_nan=False) + '\n').encode()
    path = OUT / name
    with path.open('xb') as stream:
        stream.write(data)
    path.chmod(0o600)
    return sha(data)


def point(value):
    # A single observed service is not a statistical confidence range.
    return dict(low=value, typical=value, high=value)


def main():
    assert not OUT.exists()
    manifest_raw = (PACKAGE / 'manifest.json').read_bytes()
    assert sha(manifest_raw) == MANIFEST_SHA
    manifest = json.loads(manifest_raw)
    for name, pin in manifest['members'].items():
        data = (PACKAGE / name).read_bytes()
        assert len(data) == pin['byteCount'] and sha(data) == pin['sha256']
    source_receipt = json.loads((BASE / 'runs/prefill-planner-cpu-20260914/execution.json').read_text())
    for name, digest in source_receipt['sourcePins'].items():
        assert sha((REPO / name).read_bytes()) == digest
    OUT.mkdir(mode=0o700)
    replay = subprocess.run([sys.executable, '-B', str(PACKAGE / 'extract_services.py')],
                            capture_output=True, cwd=PACKAGE, timeout=30)
    save('extraction.stdout', replay.stdout)
    save('extraction.stderr', replay.stderr)
    assert replay.returncode == 0 and replay.stderr == b''
    vectors_raw = (PACKAGE / 'service-vectors.json').read_bytes()
    vectors = json.loads(vectors_raw)
    summaries = []
    for cohort in vectors['cohorts']:
        candidates = []
        for policy in ('serial_v1', 'prompt_lookahead_one_v1'):
            candidates.append(dict(
                id=cohort['label'] + '-' + policy, plan_sha256=cohort['planFingerprint'],
                devices=['assumed-independent-a', 'assumed-independent-b'],
                resource_layout='independent_devices', policy=policy,
                evidence_kind='assumed', source_sha256=[sha(vectors_raw), MANIFEST_SHA],
                memory=[dict(peak_bytes=None, budget_bytes=None) for _ in range(2)],
                startup_ns=None, return_token_ns=None,
                frames=[dict(prepare_ns=point(frame['producerPrepareNanoseconds']),
                             consume_ns=point(frame['consumerConsumeAndFinalSelectionNanoseconds']),
                             handoff_ns=None, completion_ns=None) for frame in cohort['frames']]))
        document = dict(schema='cluster_prefill_costs_v1',
                        workload=dict(artifact_sha256=cohort['artifactAggregateSHA256'],
                                      tokens_sha256=cohort['promptFileSHA256'],
                                      arithmetic=cohort['arithmeticEnvironmentSHA256'],
                                      prompt_tokens=8192, chunk_tokens=512, batch_size=1,
                                      cache_mode='uncached'), baseline=None, candidates=candidates)
        name = cohort['label']
        input_sha = save(name + '.input.json', document)
        command = [sys.executable, '-B', '-m', 'planning', str(OUT / (name + '.input.json'))]
        run = subprocess.run(command, cwd=REPO / 'experiments/cluster',
                             capture_output=True, timeout=30)
        output_sha = save(name + '.analysis.json', run.stdout)
        save(name + '.stderr', run.stderr)
        assert run.returncode == 0 and run.stderr == b''
        analysis = json.loads(run.stdout)
        assert analysis['input_sha256'] == input_sha and analysis['comparisons'] == []
        for item in analysis['candidates']:
            assert item['status'] == 'missing_costs' and item['ttft_ns'] is None
            assert item['prefill_tps'] is None and len(item['missing_costs']) == 34
            assert len(item['memory_issues']) == 4
        summaries.append(dict(
            cohort=name, sourceNativeSHA256=cohort['nativeSHA256'],
            sourceLayerRanges=cohort['sourceLayerRanges'],
            sourceWasSharedGPU=True, sourceOwnerTrace=cohort['ownerFrame7InstrumentationEnabled'],
            inputSHA256=input_sha, analysisSHA256=output_sha,
            zeroOverheadScenarios=[dict(policy=item['policy'],
                                       elapsedNanoseconds=item['zero_overhead_scenario_ns']['typical'])
                                   for item in analysis['candidates']],
            fullTTFTEstimated=False, physicalPerformanceQualified=False))
    for name, digest in source_receipt['sourcePins'].items():
        assert sha((REPO / name).read_bytes()) == digest
    result = dict(atUTC=datetime.now(timezone.utc).isoformat(), passed=True,
                  sourcePackageManifestSHA256=MANIFEST_SHA,
                  serviceVectorsSHA256=sha(vectors_raw),
                  publicPlannerSourcePins=source_receipt['sourcePins'], cohorts=summaries,
                  scope='Point services transferred by assumption to two independent devices; all overhead and memory unknown',
                  crossCohortCausalComparison=False, sourceUnchanged=True,
                  nativeModelOrSSHExecutionPerformed=False)
    digest = save('execution.json', result)
    print(json.dumps(dict(output=str(OUT), executionSHA256=digest, cohorts=summaries), indent=2))


if __name__ == '__main__':
    main()
