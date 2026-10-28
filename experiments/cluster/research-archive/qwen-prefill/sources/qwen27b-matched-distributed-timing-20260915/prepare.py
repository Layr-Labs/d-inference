"""Prepare two private timing configurations; no artifact copy, compiler or remote call."""
from pathlib import Path
import copy
import difflib
import hashlib
import json
import uuid

BASE = Path(__file__).resolve().parent
RESEARCH = BASE.parent
OLD = RESEARCH / 'qwen27b-8k-lookahead-owner-qualification-20260915'
TIMING = RESEARCH / 'qwen9b-balanced-prefill-candidate-20260915/timing'
SHARED = RESEARCH / 'qwen27b-matched-timing-inputs-draft-20260915/bound-inputs-1/shared-inputs.json'
OLD_REMOTE = '/Users/developer/DarkbloomDev/qwen27b-8k-lookahead-owner-validation-20260915'
NATIVE = 'c35c585cfcd31e54e9635253e74a74fac35e704d83619b50aff007bac1f3f830'
CONTROLLER = 'c4483d8ce5e86f73986cdd7fb1a26e0053428883275b2de3850ea5f89bb88b1c'
UNCHANGED = ('assemble.py', 'parent_cleanup.py', 'parent_settings.py', 'probe_postflight.py',
             'lease_source.py', 'monitor.py', 'reference_resources.py', 'stage_checks/__init__.py',
             'stage_checks/common.py', 'preflight.py', 'copy_owned.py', 'deploy_copy_only.py')


def pin(path):
    raw = path.read_bytes()
    return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def load(path):
    return json.loads(path.read_bytes())


def write(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open('xb') as stream:
        stream.write(raw)
    path.chmod(0o600)


def document(path, value, compact=False):
    text = json.dumps(value, sort_keys=True, separators=(',', ':') if compact else None,
                      indent=None if compact else 2) + '\n'
    write(path, text.encode())


def main():
    assert pin(OLD / 'manifest.json')['sha256'] == 'f1df7e5da9c3da4a5e46f3b56b5aed70a5bf56745f517b7a43771f030dfe2b1a'
    assert pin(SHARED)['sha256'] == '512c48b972c8292d677efdc97d1cab17f53c3df4cb38ff67a1aa6d1697909bf8'
    shared = load(SHARED)
    assert shared['referenceValidated'] is True
    source = load(OLD / 'manifest.json')['files']
    timing_bundle = load(TIMING / 'bundle.json')
    assert next(x for x in timing_bundle['files'] if x['path'] == 'owner-timing-controller')['sha256'] == CONTROLLER
    # Read only small, retained source/metadata. Executable and metallib hashes
    # below are declared from their qualified bundles, not newly measured here.
    for name in UNCHANGED + ('run_physical.py', 'install_new_tree.py', 'preparation/remote_preflight.py'):
        got = pin(OLD / name)
        assert (got['bytes'], got['sha256']) == (source[name]['bytes'], source[name]['sha256'])
    old_deployment = load(OLD / 'deployment.json')
    cases = {}
    for name, policy in [('serial', 'serial_v1'), ('lookahead', 'one_chunk_lookahead_v1')]:
        case = BASE / name
        case.mkdir(mode=0o700)
        remote = '/Users/developer/DarkbloomDev/qwen27b-8k-' + name + '-timing-20260915'
        epoch = str(uuid.uuid4())
        for filename in UNCHANGED:
            write(case / filename, (OLD / filename).read_bytes())
        patch = []
        for filename in ('run_physical.py', 'install_new_tree.py', 'preparation/remote_preflight.py'):
            original = (OLD / filename).read_text()
            updated = original.replace(OLD_REMOTE, remote)
            if filename == 'run_physical.py':
                updated = updated.replace('ROOT = BASE.parent\n', 'ROOT = BASE.parent.parent\n')
                updated = updated.replace("CONTROLLER = ROOT / 'cluster-owner-diagnostic-drain-draft-20260915/local-bundle/owner-controller'",
                    "CONTROLLER = ROOT / 'qwen9b-balanced-prefill-candidate-20260915/timing/runtime/owner-timing-controller'")
            write(case / filename, updated.encode())
            patch.extend(difflib.unified_diff(original.splitlines(True), updated.splitlines(True),
                                             fromfile='a/' + filename, tofile='b/' + filename))
        write(case / 'binding.patch', ''.join(patch).encode())
        config = load(OLD / 'configuration/controller.json')
        del config['requestID']  # The existing timing controller creates four fresh UUIDs.
        config.update(schema='darkbloom_owner_timing_cohort_v1', membershipEpoch=epoch,
                      cohortLabel='qwen27b_cut16_' + name, policyLabel=policy, warmupCount=1, measuredCount=3)
        assert config['promptTokenIDs'] == shared['promptTokenIDs']
        assert config['expectedTokenIDs'] == shared['expectedTokenIDs']
        for peer in config['peers']:
            peer['installedOwner'] = peer['installedOwner'].replace(OLD_REMOTE, remote)
        document(case / 'configuration/controller.json', config, True)
        for rank in (0, 1):
            owner = load(OLD / ('configuration/owner-rank' + str(rank) + '.json'))
            owner['workerExecutable'] = owner['workerExecutable'].replace(OLD_REMOTE, remote)
            owner['workerEnvironment'] = {k: v.replace(OLD_REMOTE, remote) for k, v in owner['workerEnvironment'].items()}
            owner['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY'] = policy
            document(case / ('configuration/owner-rank' + str(rank) + '.json'), owner, True)
        for filename in ('configuration/matrix.json', 'inputs/prompt.ids.json', 'inputs/expected-token-ids.json',
                         'inputs/request.json', 'provenance/recording-metadata.json', 'provenance/expected-identity.json'):
            write(case / filename, (OLD / filename).read_bytes())
        declaration = dict(schema='private_qwen27b_matched_timing_case_v1', case=name, remoteRoot=remote,
            membershipEpoch=epoch, nativeSHA256=NATIVE, controllerSHA256=CONTROLLER, policyLabel=policy,
            stageCut=16, warmupCount=1, measuredCount=3, promptCount=8192, chunkSize=512, outputCount=128,
            stopTokenIDs=[], mtpEnabled=False, sharedInputs=pin(SHARED),
            requestIDs='four fresh UUIDs generated by unchanged TimingCohort',
            diagnosticEOFCompletenessProven=False, fullNumericalComparisonPerformed=False,
            externalTTFTMeasured=False, encryptedRDMAQualified=False, performanceQualified=False)
        document(case / 'case.json', declaration)
        deployment = copy.deepcopy(old_deployment)
        deployment['localController'] = dict(path=str(TIMING / 'runtime/owner-timing-controller'),
            **{k:v for k,v in next(x for x in timing_bundle['files'] if x['path']=='owner-timing-controller').items() if k!='path'})
        deployment['localControlBundle'] = pin(TIMING / 'bundle.json')
        deployment['nativeBinaryChanged'] = False
        deployment['requiredRootGates'] = ['matched 27B 8K correctness passed for c35c lookahead and serial ancestry',
            'exact 14-file tree; canonical empty lease, no workers, unchanged resource guards',
            'exclusive physical window; all four requests and cleanup before aggregates']
        for rank, entry in enumerate(deployment['ranks']):
            entry['remoteRoot'] = remote
            for row in entry['files']:
                path = Path(row['source'])
                if path.is_relative_to(OLD):
                    row['source'] = str(case / path.relative_to(OLD))
                if row['path'] == 'owner.json':
                    actual = pin(case / ('configuration/owner-rank' + str(rank) + '.json'))
                    row.update(source=actual['path'], bytes=actual['bytes'], sha256=actual['sha256'])
            document(case / ('deployment-rank' + str(rank) + '.json'),
                dict(schema='qwen27b_load_operands_copy_only_tree_v1', files={
                    'owner/' + row['path']:dict(source=row['source'], bytes=row['bytes'], sha256=row['sha256'], mode=int(row['mode'],8))
                    for row in entry['files']}), True)
        document(case / 'deployment.json', deployment)
        pins = {str(p):pin(p) for p in case.rglob('*') if p.is_file()}
        for row in timing_bundle['files']:
            path = TIMING / 'runtime' / row['path']
            pins[str(path)] = dict(path=str(path), bytes=row['bytes'], sha256=row['sha256'])
        for path in (TIMING / 'bundle.json', SHARED, BASE / 'check_source.py'):
            pins[str(path)] = pin(path)
        for entry in deployment['ranks']:
            for row in entry['files']:
                pins[row['source']] = dict(path=row['source'], bytes=row['bytes'], sha256=row['sha256'])
        document(case / 'run-pins.json', dict(files=sorted(pins.values(), key=lambda x:x['path'])))
        members = {str(p.relative_to(case)):{k:v for k,v in pin(p).items() if k!='path'}
                   for p in sorted(case.rglob('*')) if p.is_file()}
        document(case / 'manifest.json', dict(files=members))
        cases[name] = dict(directory=str(case), manifest=pin(case/'manifest.json'),
                          controllerConfiguration=pin(case/'configuration/controller.json'), **declaration)
    document(BASE / 'prepared.json', dict(schema='private_qwen27b_matched_timing_preparation_v1',
        cases=cases, sourceParent=pin(OLD/'manifest.json'), timingBundle=pin(TIMING/'bundle.json'),
        unchangedRuntimeFiles=list(UNCHANGED), newExecutableOrModelExecuted=False,
        externalArtifactBytesRead=False, remoteActionsExecuted=False))
    print(json.dumps({k:dict(manifest=v['manifest']['sha256'], configuration=v['controllerConfiguration']['sha256']) for k,v in cases.items()}))


if __name__ == '__main__':
    main()
