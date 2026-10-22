"""Check actual native policy parsing without model, collective, or GPU work."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parent


def main():
    binary = ROOT / 'build/workspace/libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release/GemmaResidentBenchmark'
    identity = hashlib.sha256(binary.read_bytes()).hexdigest()
    build = json.loads((ROOT / 'build/GemmaResidentBenchmark-build-4.json').read_bytes())
    assert build['exitCode'] == 0 and build['nativeSHA256'] == identity
    fresh = ROOT / 'metadata-checks/guard-metrics-native-v1'
    fresh.mkdir(mode=0o700)
    job = json.loads((ROOT / 'metadata-checks/arguments/accepted.json').read_bytes())
    job.update(buildIdentitySHA256=identity, chunkSize=64, cut=8,
               outputDirectory=str(fresh / 'must-not-create-sidecars'))
    (fresh / 'base.json').write_text(json.dumps(job) + '\n')
    generator = ROOT.parent / 'gemma4-prefill-lookahead-20260920/Tests/make_policy_jobs.py'
    subprocess.run(['/usr/bin/python3', '-B', str(generator), str(fresh / 'base.json'), str(fresh / 'cases')], check=True, timeout=10)
    rows = []
    for case in json.loads((fresh / 'cases/cases.json').read_bytes()):
        for action in ['--check-arguments', '--describe']:
            result = subprocess.run([str(binary), action, case['job']], capture_output=True, timeout=15)
            prefix = fresh / (case['name'] + action)
            Path(str(prefix) + '.stdout').write_bytes(result.stdout)
            Path(str(prefix) + '.stderr').write_bytes(result.stderr)
            accepted = result.returncode == 0
            row = dict(case=case['name'], action=action, exitCode=result.returncode,
                       accepted=accepted, expectedAccepted=case['expectedAccepted'],
                       stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(),
                       stderrSHA256=hashlib.sha256(result.stderr).hexdigest())
            rows.append(row)
            assert accepted == case['expectedAccepted'], row
            if accepted:
                assert not result.stderr
                value = json.loads(result.stdout)
                assert value['metadataOnly'] is True and value['runtimeExecutionAuthorized'] is False
                assert value['servingEnabled'] is False
                policy = value['job'].get('prefillPolicy', 'serial')
                for target in value['targets']:
                    extra = policy == 'oneChunkLookahead' and target['target'] != 'full'
                    expected_native = 64 * 2816 * 4 if extra and target['target'] == 'stage0' else 0
                    expected_host = expected_native + 65_536 if extra else 0
                    assert target['extraPrefillNativeBytes'] == expected_native
                    assert target['extraPrefillHostBytes'] == expected_host
    assert not (fresh / 'must-not-create-sidecars').exists()
    receipt = dict(status='passed', nativeSHA256=identity, calls=rows,
                   modelOrCollectiveOrGPUActivated=False)
    (fresh / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(dict(status='passed', cases=len(rows), nativeSHA256=identity)))


if __name__ == '__main__':
    main()
