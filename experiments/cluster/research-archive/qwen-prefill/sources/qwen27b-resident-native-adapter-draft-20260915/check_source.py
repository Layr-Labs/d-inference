#!/usr/bin/env python3
"""Source/package checks and independent retained-metadata integer replay only."""
import base64
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = Path('/Users/developer/DarkbloomDev/d-inference')
PRIOR = ROOT.parent / 'registered-dense-resource-profile-draft-20260915'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(*args, cwd):
    value = subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)
    assert not value.stdout and not value.stderr, (args, value.stdout, value.stderr)

def main():
    checks = []
    def check(name, value):
        if not value:
            raise AssertionError(name)
        checks.append(name)
    integration = json.loads((ROOT / 'integration.json').read_text())
    changes = integration['runtimeChanges'] + integration['privateWorkerReplacements']
    for item in changes:
        proposed = ROOT / item.get('source', 'proposed/' + item['path'])
        check('proposed pin: ' + item['path'], sha(proposed) == item['newSHA256'])
        if item['oldSHA256']:
            if 'source' in item:
                original = proposed.with_name(proposed.stem + '.original.swift')
            else:
                original = ROOT / 'originals' / item['path']
            check('exact original: ' + item['path'], sha(original) == item['oldSHA256'] == sha(REPO / item['path']))
    for path in sorted((ROOT / 'baseline').glob('*.swift')):
        check('retained baseline: ' + path.name, path.read_bytes() == (PRIOR / 'baseline' / path.name).read_bytes())
    for name in ['retained-inputs.json', 'TestSupport.swift', 'QwenRegisteredDenseProfileCheck.swift']:
        check('prior fixture: ' + name, (ROOT / 'Tests' / name).read_bytes() == (PRIOR / 'Tests' / name).read_bytes())
    for item in json.loads((ROOT / 'unchanged-source-pins.json').read_text())['files']:
        check('unchanged dependency: ' + item['path'], sha(REPO / item['path']) == item['sha256'])
    for item in json.loads((ROOT / 'lineage.json').read_text()).values():
        if isinstance(item, dict) and 'path' in item and 'sha256' in item:
            check('lineage: ' + item['path'], sha(Path(item['path'])) == item['sha256'])
    with tempfile.TemporaryDirectory(prefix='qwen27b-source-check-') as temporary:
        tree = Path(temporary)
        shutil.copytree(ROOT / 'originals', tree, dirs_exist_ok=True)
        for item in integration['privateWorkerReplacements']:
            target = tree / item['path']; target.parent.mkdir(parents=True, exist_ok=True)
            source = ROOT / item['source']
            shutil.copy2(source.with_name(source.stem + '.original.swift'), target)
        for patch in ['runtime.patch', 'private-worker.patch', 'native-tests.patch']:
            run('git', 'apply', '--check', '--whitespace=error', str(ROOT / patch), cwd=tree)
            run('git', 'apply', '--whitespace=error', str(ROOT / patch), cwd=tree)
        for item in changes:
            check('applied exact bytes: ' + item['path'], sha(tree / item['path']) == item['newSHA256'])
        for item in integration['stagedNativeTests']:
            check('applied staged test: ' + item['destination'],
                  (tree / item['destination']).read_bytes() == (ROOT / item['source']).read_bytes())
        for patch in ['native-tests.patch', 'private-worker.patch', 'runtime.patch']:
            run('git', 'apply', '--reverse', '--whitespace=error', str(ROOT / patch), cwd=tree)
        for item in changes:
            path = tree / item['path']
            check('inverse patch: ' + item['path'],
                  sha(path) == item['oldSHA256'] if item['oldSHA256'] else not path.exists())
    run('bash', '-n', str(ROOT / 'Tests/run.sh'), cwd=ROOT)
    checks.append('Foundation runner shell syntax only')
    raw = (ROOT / 'Tests/retained-inputs.json').read_bytes()
    check('retained metadata raw SHA', hashlib.sha256(raw).hexdigest() ==
          '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25')
    fixture = json.loads(raw)['twentySeven']
    config = base64.b64decode(fixture['configuration'])
    manifest = base64.b64decode(fixture['manifest'])
    check('retained27B exact local config/manifest',
          config == (Path('/Users/developer/DarkbloomDev/models/Qwen3.8-27B/config.json')).read_bytes()
          and hashlib.sha256(manifest).hexdigest() == 'd1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc')
    text = json.loads(config)['text_config']
    tensors = fixture['canonicalTensors']
    expected = {4: ([118, 1729], [1571565888, 13561236160]),
                8: ([233, 1614], [2427970176, 12704831872]),
                12: ([348, 1499], [3284374464, 11848427584]),
                16: ([463, 1384], [4140778752, 10992023296]),
                32: ([923, 924], [7566395904, 7566406144])}
    partitions = {}
    for cut, (counts, sizes) in expected.items():
        actual_count = [0, 0]; actual_bytes = [0, 0]; fusion = [0, 0]
        for tensor in tensors:
            name = tensor['name']
            layer = re.fullmatch(r'language_model\.model\.layers\.(\d+)\.(.+)', name)
            if layer:
                rank = int(int(layer[1]) >= cut)
                if re.fullmatch(r'linear_attn\.in_proj_(qkv|z|b|a)\.(weight|scales|biases)', layer[2]):
                    fusion[rank] += tensor['byteCount']
            elif name.startswith('language_model.model.embed_tokens.'):
                rank = 0
            else:
                check('only norm/head outside layers and embedding: ' + name,
                      name == 'language_model.model.norm.weight' or name.startswith('language_model.lm_head.'))
                rank = 1
            actual_count[rank] += 1; actual_bytes[rank] += tensor['byteCount']
        check('independent27B partition: ' + str(cut), actual_count == counts and actual_bytes == sizes)
        partitions[str(cut)] = {'tensorCounts': actual_count, 'activeBytes': actual_bytes,
                                'fusionReplacementBytes': fusion}
    g = text
    conv = 4 * (g['linear_conv_kernel_dim'] - 1) * (2 * g['linear_num_key_heads'] * g['linear_key_head_dim']
                + g['linear_num_value_heads'] * g['linear_value_head_dim'])
    ssm = 4 * g['linear_num_value_heads'] * g['linear_value_head_dim'] * g['linear_key_head_dim']
    attention = g['num_hidden_layers'] // g['full_attention_interval']
    recurrent = g['num_hidden_layers'] - attention
    kv = 2 * 4 * 8320 * g['num_key_value_heads'] * g['head_dim']
    boundary = 512 * g['hidden_size'] * 4
    terms = {'threeRecurrentGenerations': 3 * recurrent * (conv + ssm),
             'allKVCapacityAndOffsets': attention * (kv + 4), 'largestSingleHostStateComponent': max(conv, ssm, kv // 2),
             'twoBoundaryArrays': 2 * boundary}
    check('independent maximum state vector', sum(terms.values()) == 1616248896)
    check('independent cut4 fusion', partitions['4']['fusionReplacementBytes'] == [142387200, 2135808000])
    result = {'schema': 'qwen27b_native_adapter_source_checks_v1', 'passed': True,
              'checks': checks, 'checkCount': len(checks), 'retainedMetadataReplay': {'partitions': partitions,
              'maximumStateTerms': terms, 'maximumStateBytes': sum(terms.values())},
              'swiftCompilerRun': False, 'swiftFixtureExecuted': False, 'nativeExecuted': False,
              'modelPayloadRead': False, 'remoteOperations': False}
    print(json.dumps(result, sort_keys=True, indent=2))

if __name__ == '__main__':
    main()
