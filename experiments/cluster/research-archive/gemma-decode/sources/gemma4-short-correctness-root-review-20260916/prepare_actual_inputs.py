"""Tokenize verified local metadata, describe the actual native, then bind inputs."""
import hashlib
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parent
RESEARCH = ROOT.parent
SOURCE = RESEARCH / 'gemma4-short-physical-reviewed-source-20260917'
SOURCE_SHA = 'a5f09155ff91016c197a6bc4c1dc62757b82f3589dd53879dab2c46eba7f952d'
BUILD = RESEARCH / 'gemma4-short-correctness-draft-20260916/build'
LOCAL = RESEARCH / 'gemma4-artifact-local-verification-20260917'
OUTPUT = ROOT / 'actual-inputs-1'
sys.path.insert(0, str(RESEARCH / 'cluster-native-member-invocation-draft-20260916/Tests'))
from check_process import run_owned


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')


def check_source():
    assert sha(SOURCE / 'manifest.json') == SOURCE_SHA
    for row in json.loads((SOURCE / 'manifest.json').read_text())['files']:
        path = SOURCE / row['path']
        assert not path.is_symlink() and sha(path) == row['sha256']


def main():
    check_source()
    verification = json.loads((LOCAL / 'receipt.json').read_text())
    assert verification['status'] == 'passed'
    assert verification['staging']['wholePayloadVerified'] is True
    stage = Path(verification['stageDirectory'])
    assert stage == LOCAL / 'model'
    build_receipt = BUILD / 'native-1/receipt.json'
    assert sha(build_receipt) == '5d2864b022c95d2b6541c0f111ac85fca5ac736dba202f05e3b20d3ec0da1330'
    build = json.loads(build_receipt.read_text())
    native = Path(build['binary']['path'])
    assert sha(native) == '4c163b22a63a201a2b3a312cc7e59e7c22014bc08298d33cba3663b84bde3411'
    metadata = Path('/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Tests/StageMetadataChecks/Inputs')
    for row in json.loads((SOURCE / 'metadata-controls.json').read_text()):
        assert sha(metadata / row['path']) == row['sha256']
    OUTPUT.mkdir(mode=0o700)
    steps = []
    steps.append(run_owned([
        '/Users/developer/.local/share/uv/tools/vllm-mlx/bin/python', '-B',
        str(SOURCE / 'prepare_prompt.py'), '--model-directory', str(stage),
        '--output', str(OUTPUT / 'prompt-1')], OUTPUT, 'tokenize', 30))
    prompt = OUTPUT / 'prompt-1/prompt.ids.json'
    job = {
        'schema': 'gemma4_short_native_check_v1', 'mode': 'full',
        'modelDirectory': '/Users/developer/DarkbloomDev/models/Gemma4-26B',
        'metadataDirectory': str(metadata), 'promptFile': str(prompt),
        'promptFileSHA256': sha(prompt),
        'outputDirectory': str(OUTPUT / 'prospective-sidecars'),
        'requestID': str(uuid.uuid4()), 'membershipEpoch': str(uuid.uuid4()),
        'buildIdentitySHA256': build['binary']['sha256'],
        'residualDType': 'bfloat16', 'timeoutSeconds': 300,
    }
    save(OUTPUT / 'described-job.json', job)
    steps.append(run_owned([str(native), '--describe', str(OUTPUT / 'described-job.json')],
                           OUTPUT, 'describe', 10))
    references = {
        'buildReceipt': build_receipt,
        'sourceSnapshot': BUILD / 'source-snapshot-1.json',
        'dependencySnapshot': BUILD / 'dependency-snapshot-1.json',
        'describeReceipt': OUTPUT / 'describe.json',
        'expected': OUTPUT / 'describe.stdout',
        'prompt': prompt,
        'promptReceipt': OUTPUT / 'prompt-1/prompt-receipt.json',
        'jobTemplate': OUTPUT / 'described-job.json',
    }
    packet = {name: {'path': str(path), 'sha256': sha(path)} for name, path in references.items()}
    packet.update(schema='gemma_short_root_build_inputs_v1', metadataDirectory=str(metadata))
    save(OUTPUT / 'inputs.json', packet)
    steps.append(run_owned(['/usr/bin/python3', '-B', str(SOURCE / 'bind_build.py'),
        '--inputs', str(OUTPUT / 'inputs.json'), '--inputs-sha256', sha(OUTPUT / 'inputs.json'),
        '--output', str(OUTPUT / 'bound')], OUTPUT, 'bind', 30))
    check_source()
    assert sha(native) == build['binary']['sha256']
    save(OUTPUT / 'receipt.json', dict(status='passed', steps=steps,
        sourceManifestSHA256=SOURCE_SHA, localVerificationSHA256=sha(LOCAL / 'receipt.json'),
        bindingReceiptSHA256=sha(OUTPUT / 'bound/binding-receipt.json'),
        modelOrGPUExecuted=False, remoteExecuted=False))
    print(json.dumps(dict(status='passed', bound=str(OUTPUT / 'bound'),
        bindingSHA256=sha(OUTPUT / 'bound/binding-receipt.json'))))


if __name__ == '__main__':
    main()
