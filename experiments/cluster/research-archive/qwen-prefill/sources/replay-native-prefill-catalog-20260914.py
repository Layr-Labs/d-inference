"""Root-owned Foundation export, CPU measurement replay and exact metadata join."""
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent
REPO = BASE.parent / 'd-inference'
OUT = BASE / 'runs/native-prefill-catalog-replay-20260914'
MEASUREMENTS = BASE / 'runs/public-prefill-measurements-replay-v2-20260914'
sha = lambda raw: hashlib.sha256(raw).hexdigest()


def write(name, raw):
    if not isinstance(raw, bytes):
        raw = (json.dumps(raw, sort_keys=True, indent=2) + '\n').encode()
    path = OUT / name
    with path.open('xb') as stream:
        stream.write(raw)
    path.chmod(0o600)
    return sha(raw)


def run(name, command, cwd=REPO, timeout=90):
    result = subprocess.run(command, cwd=cwd, capture_output=True, timeout=timeout)
    output_sha = write(name + '.stdout', result.stdout)
    stderr_sha = write(name + '.stderr', result.stderr)
    assert result.returncode == 0 and not result.stderr, result.stderr.decode()[-3000:]
    return json.loads(result.stdout), dict(command=command, exit=result.returncode,
                                        stdoutSHA256=output_sha, stderrSHA256=stderr_sha)


def main():
    OUT.mkdir(mode=0o700)
    retained_path = REPO / 'experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json'
    retained_raw = retained_path.read_bytes()
    assert sha(retained_raw) == '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25'
    retained = json.loads(retained_raw)
    fixture = json.loads((BASE / 'runs/public-candidate-export-check-20260914/execution.json').read_bytes())
    pins = fixture['sourcePins'] | {str(p.relative_to(REPO)): sha(p.read_bytes())
                                   for p in (REPO / 'experiments/cluster/planning').rglob('*.py')}
    assert all(sha((REPO / path).read_bytes()) == expected for path, expected in pins.items())
    sys.path.insert(0, str(REPO / 'experiments/cluster'))
    from planning.catalog import native_candidates
    from planning.measurements.projection import assumed_profile
    from planning.rank import analyze
    exports, receipts = {}, {}
    for key, count in [('nine', 7), ('twentySeven', 15)]:
        model = retained[key]
        config = base64.b64decode(model['configuration'], validate=True)
        names = [row['name'] for row in model['canonicalTensors']]
        config_sha = write(key + '.config.json', config)
        names_sha = write(key + '.names.json', names)
        catalog, receipt = run(key + '.catalog', [
            'bash', 'experiments/cluster/inference/Tools/LayerStageCandidates/run.sh',
            '--config', str(OUT / (key + '.config.json')), '--config-sha256', config_sha,
            '--canonical-names', str(OUT / (key + '.names.json')), '--canonical-names-sha256', names_sha])
        parsed = native_candidates(catalog)
        assert len(parsed) == count
        assert catalog['canonicalNameCount'] == len(names)
        exports[key] = catalog
        receipts[key] = dict(receipt, candidates=count, canonicalNames=len(names),
                             sourceConfigurationSHA256=config_sha)
    migration, migration_receipt = run('measurement-replay', [
        sys.executable, '-B', str(BASE / 'replay-public-prefill-measurements-v2-20260914.py')])
    joins = []
    for name, cut, ideal in [('balanced_phase', 16, 10005707250), ('cut12_phase_owner', 12, 12091115957)]:
        packet = MEASUREMENTS / (name + '.packet.json')
        catalog_path = OUT / 'nine.catalog.stdout'
        result, receipt = run(name + '.association', [
            sys.executable, '-B', '-m', 'planning.measurements', str(packet),
            '--catalog', str(catalog_path), '--catalog-sha256', sha(catalog_path.read_bytes())],
            cwd=REPO / 'experiments/cluster', timeout=30)
        observed = [row for row in result['candidates'] if row['measurement_status'] == 'observed_metadata_match']
        assert len(observed) == 1 and observed[0]['cut'] == cut
        assert result['reported_parameter_ownership_matched'] is True
        assert all(row['measurement_status'] == 'unmeasured' for row in result['candidates'] if row['cut'] != cut)
        services = json.loads((MEASUREMENTS / (name + '.services.json')).read_bytes())
        mapping_counts = [len(row['active_mappings']) for row in services['source']['reported_stage_ownership']]
        assert sum(mapping_counts) == 927
        profile = assumed_profile(services, ['hypothetical-a', 'hypothetical-b'], 'prompt_lookahead_one_v1')
        profile_sha = write(name + '.assumed-costs.json', profile)
        analysis = analyze(profile)
        analysis_sha = write(name + '.analysis.json', analysis)
        assert analysis['candidates'][0]['zero_overhead_scenario_ns']['typical'] == ideal
        assert analysis['candidates'][0]['ttft_ns'] is None and analysis['comparisons'] == []
        joins.append(dict(cohort=name, cut=cut, mappingCounts=mapping_counts,
                          association=receipt, assumedProfileSHA256=profile_sha,
                          analysisSHA256=analysis_sha, zeroOverheadAssumedNanoseconds=ideal,
                          fullEstimate=None, ranking=[], passed=True))
    assert all(sha((REPO / path).read_bytes()) == expected for path, expected in pins.items())
    receipt = dict(atUTC=datetime.now(timezone.utc).isoformat(), passed=True, sourcePins=pins,
                   sourceUnchanged=True, exports=receipts, migration=migration_receipt, joins=joins,
                   foundationCompilerExecuted=True, mlxModelOrSSHExecution=False,
                   numericalAuditReplayed=False, physicalPerformanceQualified=False,
                   unmeasured27BCandidates=15)
    receipt_sha = write('execution.json', receipt)
    print(json.dumps(dict(output=str(OUT), receiptSHA256=receipt_sha,
                          exports={key: value['candidates'] for key,value in receipts.items()},
                          joinedCuts=[row['cut'] for row in joins], passed=True), indent=2))


if __name__ == '__main__':
    main()
