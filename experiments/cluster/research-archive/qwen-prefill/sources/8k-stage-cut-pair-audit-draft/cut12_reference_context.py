"""One fixed 12/20 metadata expectation; no numerical candidate is read here."""
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PINNED = {
    'short-stage-cut-audit-draft/cut12_expected.py': 'f8e47fc3f976dc352e9a6152b974dc797fbdec02e0400aae50f40e41ae0acf82',
    'short-stage-cut-audit-draft/cut12-expected.json': '3f0d18b1d47eeb1e7eadff19fd813e92a4b3b0eab12ceac2360bfc5c716fb3c3',
    'short-stage-cut-audit-draft/qwen_layer_stage_cut12_audit.py': '00e07565fab523fded70caa3aabbcaa2064ede8291e1886e9701b455c446c2fe',
    'short-stage-cut-audit-draft/manifest.json': 'a2a6226f75af7e0ace942d0b5e965d583d9fc8b9518c62f338c62090a523f46a',
    'runs/stage-cut-plan-control-20260914/stdout.json': 'e6e062466026e921502e85159cdce293bbd6570cb4c6de6c6b4026c6bf006b89',
    'runs/stage-cut-plan-control-20260914/receipt.json': 'a252ab6be2a17177438b7cb5403735010c27750f558cc203add7ce1c53edcd41',
    'qwen-layer-stage-real9b-expected-20260913.json': 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99',
    '8k-stage-cut-extension-draft/manifest.json': '426943e284b57a6c7e0d4780615659df7bf02930845c0a3b0351e0929d15dcbc',
}
PLAN_SHA = '8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed'
RANGES = ((0, 12), (12, 32))


def raw(name):
    with (ROOT/name).open('rb') as stream:
        data = stream.read(2*1024**2+1)
    if not 0 < len(data) <= 2*1024**2 or hashlib.sha256(data).hexdigest() != PINNED[name]:
        raise ValueError('Frozen cut12 metadata dependency differs: '+name)
    return data


def verify_pins():
    found = {name: {'sha256': pin, 'byteCount': len(raw(name))} for name, pin in PINNED.items()}
    manifest_name = '8k-stage-cut-extension-draft/manifest.json'
    members = [x for x in json.loads(raw(manifest_name))['files'] if x['path'].startswith('proposed/')]
    if len(members) != 19:
        raise ValueError('Frozen native cut source inventory differs')
    for item in members:
        path = ROOT/'8k-stage-cut-extension-draft'/item['path']
        with path.open('rb') as stream: data = stream.read(2*1024**2+1)
        if len(data) != item['size_bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('Frozen native cut source member differs')
        found[str(path.relative_to(ROOT))] = {'sha256': item['sha256'], 'byteCount': len(data)}
    return found


def metadata(configuration):
    """Derive and match the retained canonical inventory and exact Plan control."""
    verify_pins()
    name = 'short-stage-cut-audit-draft/cut12_expected.py'
    spec = importlib.util.spec_from_file_location('long_pair_cut12_metadata_deriver', ROOT/name)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    expected = helper.derive(raw('qwen-layer-stage-real9b-expected-20260913.json'), configuration,
        raw('runs/stage-cut-plan-control-20260914/stdout.json'))
    retained = helper.parse(raw('short-stage-cut-audit-draft/cut12-expected.json'))
    helper.same(expected, retained, 'Derived fixed cut12 expected inventory differs')
    helper.require(expected['planSHA256'] == PLAN_SHA, 'Fixed cut12 Plan identity differs')
    # A narrow facade for the unchanged consumers, derived only from verified
    # control fields. It does not serialize or relabel a numerical reference.
    plan = dict(configurationSHA256=helper.CONFIG_SHA256, planSHA256=PLAN_SHA,
        mappedTextParameters=927, stages=[dict(configurationSHA256=s['constructionConfigurationSHA256'],
            fingerprint=s['stagePlanSHA256'], mappedParameters=s['activeTensorCount']) for s in expected['stages']])
    helper.require([s['mappedParameters'] for s in plan['stages']] == [348,579], 'Fixed cut12 counts differ')
    return expected, plan
