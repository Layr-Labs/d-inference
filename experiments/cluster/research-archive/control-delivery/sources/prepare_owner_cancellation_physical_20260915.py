from pathlib import Path
import base64, hashlib, json, shutil, uuid

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
SOURCE = ROOT / 'owner-timing-lookahead-wakeup-20260915'
DRAFT = ROOT / 'owner-cancellation-recovery-draft-20260915'
CONTROLLER = DRAFT / 'build-2/owner-cancellation-controller'
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
assert digest(DRAFT / 'manifest.json') == '0ddcf8031038ea62e08c5b4ee27ffeef5631a7bc7b8fdc01d940a60c2629434d'
manifest = json.loads((DRAFT / 'manifest.json').read_text())
members = manifest['members']
if isinstance(members, dict):
    members = [dict(path=k, **v) for k, v in members.items()]
for item in members:
    assert digest(DRAFT / item['path']) == item['sha256'], item['path']
assert digest(CONTROLLER) == 'c6c8665319ced89f5b456562f961a39d0be33dd9403c2c90865bfbb619b8cc0d'
previous = json.loads((SOURCE / 'configuration/controller.json').read_text())
for suffix, selected_case in [('before-first', 'startedBeforeFirstToken'), ('after-decode', 'afterFirstDecode')]:
    name = 'owner-cancellation-' + suffix + '-20260915'
    base = ROOT / name
    base.mkdir(mode=0o700)
    (base / 'configuration').mkdir(mode=0o700)
    remote = '/Users/developer/DarkbloomDev/' + name
    cluster = 'qwen9b-cancellation-' + suffix
    for file in ['monitor.py', 'reference_resources.py', 'lease_source.py', 'lease-lineage.json',
                 'stage_checks/common.py', 'stage_checks/__init__.py', 'configuration/matrix.json']:
        target = base / file
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(SOURCE / file, target)
    config = {key: previous[key] for key in ['readyTemplateBase64', 'promptTokenIDs', 'expectedTokenIDs',
                                            'lifetimeSeconds', 'startupSeconds', 'requestSeconds', 'peers']}
    config.update(schema='darkbloom_owner_cancellation_recovery_v1', clusterID=cluster,
                  cancellationCase=selected_case, cancellationEpoch=str(uuid.uuid4()),
                  recoveryEpoch=str(uuid.uuid4()), beforeFirstDelayMilliseconds=500)
    config['peers'] = [dict(peer, installedOwner=remote + '/darkbloom-owner-qualification') for peer in config['peers']]
    (base / 'configuration/controller.json').write_text(json.dumps(config, sort_keys=True, separators=(',', ':')) + '\n')
    for rank in range(2):
        owner = json.loads((SOURCE / f'configuration/owner-rank{rank}.json').read_text())
        template = json.loads(base64.b64decode(owner['readyTemplateBase64']))
        assert template['membershipEpoch'] == template['ready']['identity']['membershipEpoch'] == str(uuid.UUID(int=0))
        owner['clusterID'] = cluster
        owner['leaseDirectory'] = remote + '/lease'
        owner['workerEnvironment']['DARKBLOOM_BENCHMARK_EVIDENCE_DIR'] = remote + '/evidence'
        owner['workerEnvironment']['JACCL_IBV_DEVICES'] = remote + '/matrix.json'
        assert owner['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY'] == 'one_chunk_lookahead_v1'
        (base / f'configuration/owner-rank{rank}.json').write_text(json.dumps(owner, sort_keys=True, separators=(',', ':')) + '\n')
    wrapper = (SOURCE / 'run_physical.py').read_text()
    wrapper = wrapper.replace(SOURCE.name, name)
    wrapper = wrapper.replace("ROOT / 'resident-owner-timing-wakeup-bundle-20260915/build-1/owner-timing-controller'",
                              "ROOT / 'owner-cancellation-recovery-draft-20260915/build-2/owner-cancellation-controller'")
    wrapper = wrapper.replace('One correctness request over actual owner SSH', 'One cancellation and fresh-epoch recovery over actual owner SSH')
    assert str(CONTROLLER.relative_to(ROOT)) in wrapper
    (base / 'run_physical.py').write_text(wrapper)
    files = [p for p in base.rglob('*') if p.is_file()]
    files.extend([CONTROLLER] + sorted(CONTROLLER.parent.glob('*.dylib')))
    files.extend([DRAFT / 'manifest.json', DRAFT / 'artifacts.json'])
    (base / 'run-pins.json').write_text(json.dumps({'files': [{'path': str(p), 'sha256': digest(p)} for p in files]}, indent=2) + '\n')
    print(json.dumps({'directory': str(base), 'case': selected_case, 'configurationSHA256': digest(base/'configuration/controller.json'),
                      'cancellationEpoch': config['cancellationEpoch'], 'recoveryEpoch': config['recoveryEpoch']}))
