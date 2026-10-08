#!/usr/bin/env python3
"""Export only the frozen, CPU-validated baseline's integer-only descriptor."""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / 'qwen-layer-stage-solo-prefill-reference-20260914.json'
RECEIPT = ROOT / 'qwen-layer-stage-solo-prefill-reference-export-20260914.json'
BASELINE_FINGERPRINT = '54213f9c90b92033cf9ea78976f3cd8f6af355dc45930f6432a49351f97bc1a8'
POLICY = 'mlx_argmax_all_axes_with_finite_guard_v1'
MAX_DESCRIPTOR_BYTES = 128 * 1024
PINS = {
    'qwen_layer_stage_prefill_audit.py': '4bc20dfff992f6c7c8085a8f60bb565b34d883e6a9578e79db8c8ef963bc494c',
    'qwen_layer_stage_recorded_audit.py': 'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4',
    'qwen-layer-stage-prefill-cpu-validator-tests-20260914.json': '797f5990994085abd3e28a9fb88fdc43e299ed8c9bb5a664bc3e94d8977cb78e',
    'qwen-layer-stage-prefill-peer24-independent-cpu-comparison-20260914.json': 'a85b412eb9065276ba55f42d8e0f61678fb2f5efde45dc4753326e2f62d5ac73',
    'qwen-layer-stage-real9b-expected-20260913.json': 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99',
    'runs/qwen-layer-stage-prefill-peer24-20260914/native/stdout.jsonl': '10971a2556dbbfecf6557ba67375646a035483b4c3cbe937a67b7f22adfb8597',
    'runs/qwen-layer-stage-real9b-20260913/native/stdout.txt': 'dac1248a0b02ffa6010cd641834d2a43e1e7c5e92634bc28613fc7f73aaaf551',
    'prefill-solo-reference-descriptor-schema-20260914.swift': 'c2d65c183928a5b0ed8c1fbc43801f6ff0d2e241b80eb04f43caf254748708e8',
}
CURRENT = ROOT / 'runs/qwen-layer-stage-prefill-peer24-20260914/native/stdout.jsonl'
HISTORICAL = ROOT / 'runs/qwen-layer-stage-real9b-20260913/native/stdout.txt'
EXPECTED = ROOT / 'qwen-layer-stage-real9b-expected-20260913.json'
COMPARISON = ROOT / 'qwen-layer-stage-prefill-peer24-independent-cpu-comparison-20260914.json'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def verify_pins():
    records = []
    for relative, expected in PINS.items():
        path = ROOT / relative
        with path.open('rb') as stream:
            data = stream.read(32 * 1024**2 + 1)
        require(len(data) <= 32 * 1024**2 and sha(data) == expected, 'Frozen input differs: ' + relative)
        records.append(dict(path=str(path), sha256=expected, byteCount=len(data)))
    return records


def load_helper():
    path = ROOT / 'qwen_layer_stage_prefill_audit.py'
    require(sha(path.read_bytes()) == PINS[path.name], 'Frozen prefill helper differs')
    spec = importlib.util.spec_from_file_location('solo_export_frozen_prefill_audit', path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper


def derive_descriptor(helper, rows, expected, summary):
    """Take state/logits from the validated full baseline only, not its candidate."""
    control = helper.check_baseline(rows[0], expected)
    require(control['baselineSHA256'] == BASELINE_FINGERPRINT, 'Baseline evidence fingerprint differs')
    baseline = rows[0]['baseline']
    recorded = baseline['request']
    request = recorded['request']
    final = baseline['frames'][-1]
    values = final['logits']['values']
    require(len(values) == recorded['vocabularySize'] and all(type(x) in (int, float) and math.isfinite(x) for x in values),
            'Expected the complete finite baseline vocabulary row')
    maximum = max(values)
    token = next(index for index, value in enumerate(values) if value == maximum)
    ties = sum(value == maximum for value in values)
    helper.exact(summary['argmaxTokenID'], token, 'audited baseline argmax')
    helper.exact(summary['maximumTieCount'], ties, 'audited baseline maximum tie count')
    helper.exact(summary['maximumLogit'], maximum, 'audited baseline maximum')
    require(summary['finalNativeLogitsSHA256'] == sha(control['nativeLogits']), 'Reconstructed baseline logit SHA differs')
    descriptor = dict(schemaVersion=1, kind='qwen_layer_stage_solo_prefill_reference',
        baselineEvidenceFingerprint=control['baselineSHA256'], source=baseline['source'],
        request=dict(baselineRequestFingerprint=control['simple'],
            baselineRecordedRequestFingerprint=control['requestSHA256'],
            promptCount=request['promptCount'], chunkSize=request['chunkSize'], outputCount=request['outputCount'],
            vocabularySize=recorded['vocabularySize'],
            promptTokenIDsSHA256=sha(','.join(map(str, recorded['promptTokenIDs'])).encode()),
            finalFrame=final['frame'], committedTokens=final['committedTokens']),
        finalState=final['state'],
        finalLogits={key: final['logits'][key] for key in ('shape', 'dtype', 'byteCount', 'logicalBytesSHA256')},
        selection=dict(policy=POLICY, tokenID=token, maximumTieCount=ties, allLogitsFinite=True))
    require(descriptor['finalLogits']['logicalBytesSHA256'] == sha(control['nativeLogits']), 'Descriptor byte identity differs')
    data = canonical(descriptor) + b'\n'
    validate_descriptor_bytes(data, descriptor, helper)
    return descriptor, data, dict(maximumLogit=maximum, argmaxTokenID=token, maximumTieCount=ties,
        baselineNativeBytes=len(control['nativeLogits']), baselineNativeLogitValues=len(values),
        reconstructedBaselineRows=1, reconstructedCandidateRows=0)


def validate_descriptor_bytes(data, expected, helper):
    require(type(data) is bytes and 0 < len(data) <= MAX_DESCRIPTOR_BYTES, 'Descriptor exceeds its bounded bytes')
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate descriptor key')
            result[key] = value
        return result
    def reject_float(_):
        raise ValueError('Descriptor numbers must use integer JSON lexemes')
    value = json.loads(data.decode('utf-8'), object_pairs_hook=object_pairs,
        parse_float=reject_float, parse_constant=reject_float)
    helper.exact(value, expected, 'closed solo descriptor')
    return value


def prepare():
    before = verify_pins()
    helper = load_helper()
    tests = json.loads((ROOT / 'qwen-layer-stage-prefill-cpu-validator-tests-20260914.json').read_text())
    require(tests['status'] == 'passed' and tests['exitCode'] == 0 and tests['testsPassed'] == 34,
            'Frozen prefill helper test receipt differs')
    prior = json.loads(COMPARISON.read_text())
    require(prior['status'] == 'passed' and prior['exitCode'] == 0 and prior['actualModeNativeEvidenceChecked'] is True,
            'Frozen actual comparison did not pass')
    summary = helper.validate(CURRENT, HISTORICAL, EXPECTED)
    helper.exact(summary, prior['comparison'], 'full replay of frozen actual CPU comparison')
    require(summary['baselineEvidenceSHA256'] == BASELINE_FINGERPRINT, 'Pinned baseline evidence differs')
    rows, current_sha = helper.read_rows(CURRENT)
    require(current_sha == PINS[str(CURRENT.relative_to(ROOT))], 'Current baseline bytes changed')
    expected = helper.base_helper().parse_json(EXPECTED.read_text())
    descriptor, data, derived = derive_descriptor(helper, rows, expected, summary)
    after = verify_pins()
    helper.exact(after, before, 'source pins after derivation')
    return helper, descriptor, data, derived, before, after


def main():
    require(len(sys.argv) == 1, 'No input overrides: this exporter has fixed prospective source pins')
    require(not OUTPUT.exists() and not RECEIPT.exists(), 'Preserve existing descriptor/export receipt')
    _, descriptor, data, derived, before, after = prepare()
    with OUTPUT.open('xb') as stream:
        stream.write(data)
    OUTPUT.chmod(0o600)
    require(OUTPUT.read_bytes() == data, 'Exported descriptor bytes changed')
    receipt = dict(kind='qwen_layer_stage_solo_prefill_reference_export', schemaVersion=1,
        status='passed', exitCode=0, cpuOnly=True, exportedAtUTC=datetime.now(timezone.utc).isoformat(),
        exporterPath=str(Path(__file__)), exporterSHA256=sha(Path(__file__).read_bytes()),
        descriptorPath=str(OUTPUT), descriptorSHA256=sha(data), descriptorByteCount=len(data),
        baselineEvidenceFingerprint=descriptor['baselineEvidenceFingerprint'],
        baselineRequestFingerprint=descriptor['request']['baselineRequestFingerprint'],
        baselineRecordedRequestFingerprint=descriptor['request']['baselineRecordedRequestFingerprint'],
        promptTokenIDsSHA256=descriptor['request']['promptTokenIDsSHA256'],
        finalFrame=descriptor['request']['finalFrame'],
        finalStateFingerprint=descriptor['finalState']['fingerprint'],
        finalStateComponents=len(descriptor['finalState']['entries']),
        finalStateLogicalByteCount=descriptor['finalState']['logicalByteCount'],
        finalLogits=descriptor['finalLogits'], selection=descriptor['selection'], derived=derived,
        comparisonReceiptSHA256=PINS[COMPARISON.name], inputPinsBefore=before, inputPinsAfter=after,
        inputPinsUnchanged=True, fixedInputsOnly=True, nativeExecutions=0, builds=0,
        SSHExecutions=0, processInventoryCalls=0, modelPayloadBytesRead=0,
        descriptorIncludesRawLogitValues=False, descriptorIncludesRawStateBytes=False,
        scope='Fixed separately recorded full-model baseline descriptor; no candidate byte reconstruction',
        limitations=[
            'Only the exported full baseline vocabulary values permit independent native BF16 byte reconstruction, including signed zero.',
            'Final state is the complete exported metadata/digest inventory; raw baseline state arrays were not exported.',
            'The historical one-process candidate private-byte comparison remains its native assertion and is not re-created by this descriptor.',
            'This exporter replays frozen CPU evidence and binds the draft Swift schema snapshot; it does not execute the Swift decoder, a timed solo request, a build, or remote artifact verification.'])
    with RECEIPT.open('x') as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write('\n')
    RECEIPT.chmod(0o600)
    print(json.dumps(dict(status='passed', descriptor=str(OUTPUT), descriptorSHA256=sha(data),
        descriptorBytes=len(data), receipt=str(RECEIPT), receiptSHA256=sha(RECEIPT.read_bytes())), sort_keys=True))


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    main()
