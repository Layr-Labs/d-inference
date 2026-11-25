"""CPU migration check: public adapter against two frozen native phase cohorts."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

BASE = Path(__file__).resolve().parent
REPO = BASE.parent / 'd-inference'
OUT = BASE / 'runs/public-prefill-measurements-replay-20260914'


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def write(name, value):
    raw = value if isinstance(value, bytes) else (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
    with (OUT / name).open('xb') as stream:
        stream.write(raw)
    (OUT / name).chmod(0o600)
    return digest(raw)


def reference(path):
    return dict(path=str(path), sha256=digest(path.read_bytes()))


def main():
    raw = (BASE / 'prefill-phase-service-map-draft/service-vectors.json').read_bytes()
    assert digest(raw) == 'a0d47de163a4fb09851a9de88a1d704250a28b0597a71ff3801d31720d562cce'
    vectors = json.loads(raw)
    OUT.mkdir(mode=0o700)
    inspection_path = BASE / 'qwen9-peer24-readonly-inspection-20260913.json'
    display_path = BASE / 'qwen9-peer24-gpu-20260913.json'
    inspection = json.loads(inspection_path.read_bytes())
    display = json.loads(display_path.read_bytes())['SPDisplaysDataType'][0]
    hardware = dict(cpu=inspection['cpu'], memoryBytes=inspection['physical_memory_bytes'],
                    os=inspection['os'], gpu=display['sppci_model'], gpuCores=int(display['sppci_cores']),
                    sourceReferences=[reference(inspection_path), reference(display_path)],
                    observationAt=inspection['at'], currentHardwareIndependentlyVerified=False)
    hardware_sha = write('declared-hardware.json', hardware)
    source_paths = sorted((REPO / 'experiments/cluster/planning').rglob('*.py'))
    source_pins = {str(p.relative_to(REPO)): digest(p.read_bytes()) for p in source_paths}
    summaries = []
    for cohort in vectors['cohorts']:
        parent_path = Path(cohort['parentPath'])
        run = parent_path.parent
        parent = json.loads(parent_path.read_bytes())
        assert parent['passed'] is True
        assert reference(run / 'source-manifest.json')['sha256'] == parent['source_manifest_sha256']
        prompt = run / 'inputs/prompt.json'
        assert reference(prompt)['sha256'] == cohort['promptFileSHA256']
        files = dict(prompt=reference(prompt))
        for rank in range(2):
            files[f'rank{rank}_stdout'] = reference(Path(cohort['rankStdoutPaths'][rank]))
            files[f'rank{rank}_trace'] = reference(Path(cohort['rankPhasePaths'][rank]))
        packet = dict(schema='cluster_qwen_prefill_measurement_packet_v1',
                      stage_cut=12 if cohort['label'] == 'cut12_phase_owner' else None, files=files,
                      provenance=dict(native_sha256=parent['expected_native_sha256'],
                                      runtime_source_sha256=parent['source_manifest_sha256'],
                                      numerical_audit_sha256=reference(Path(cohort['numericalAuditPath']))['sha256'],
                                      runtime_audit_sha256=reference(parent_path)['sha256'],
                                      devices=[dict(id=parent['execution_host'], hardware_sha256=hardware_sha)
                                               for _ in range(2)]))
        name = cohort['label']
        packet_sha = write(name + '.packet.json', packet)
        command = [sys.executable, '-B', '-m', 'planning.measurements', str(OUT / (name + '.packet.json'))]
        result = subprocess.run(command, cwd=REPO / 'experiments/cluster', capture_output=True, timeout=30)
        services_sha = write(name + '.services.json', result.stdout)
        write(name + '.stderr', result.stderr)
        assert result.returncode == 0 and result.stderr == b'', result.stderr.decode()
        services = json.loads(result.stdout)
        assert services['packet_sha256'] == packet_sha and services['local_phase_replayed'] is True
        for rank, key in ((0, 'producerPrepareNanoseconds'), (1, 'consumerConsumeAndFinalSelectionNanoseconds')):
            extracted = services['phase']['ranks'][rank]['services']
            assert len(extracted) == len(cohort['frames']) == 16
            for expected, actual in zip(cohort['frames'], extracted):
                for field in ('frameSequence', 'tokenOffset', 'tokenCount', 'committedTokens'):
                    assert actual[field] == expected[field]
                assert actual['elapsedNanoseconds'] == expected[key]
        header = services['phase']['ranks'][0]['serialPreHeaderServices']
        assert [row['elapsedNanoseconds'] for row in header] == [row['producerPreHeaderLocalNanoseconds'] for row in cohort['frames']]
        summaries.append(dict(cohort=name, packetSHA256=packet_sha, servicesSHA256=services_sha,
                              exactPrimaryServices=32, exactPreHeaderServices=16, passed=True))
    assert all(digest((REPO / name).read_bytes()) == sha for name, sha in source_pins.items())
    result = dict(atUTC=datetime.now(timezone.utc).isoformat(), passed=True, cohorts=summaries,
                  sourcePins=source_pins, sourceUnchanged=True,
                  comparedAgainstFrozenVectorSHA256=digest(raw), nativeOrModelOrSSHExecutionPerformed=False,
                  actualPhysicalPerformanceQualified=False)
    receipt_sha = write('execution.json', result)
    print(json.dumps(dict(output=str(OUT), receiptSHA256=receipt_sha, cohorts=summaries), indent=2))


if __name__ == '__main__':
    main()
