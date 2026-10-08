#!/usr/bin/env python3
"""Apply the frozen CPU oracle to completed saved peer24 output; no native IO."""
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import time
import traceback

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
RUN = ROOT / 'runs/qwen-layer-stage-prefill-peer24-20260914'
OUTPUT = ROOT / 'qwen-layer-stage-prefill-peer24-independent-cpu-comparison-20260914.json'
LOG = ROOT / 'qwen-layer-stage-prefill-peer24-independent-cpu-comparison-20260914.log'
PINS = {
    ROOT / 'qwen_layer_stage_prefill_audit.py': '4bc20dfff992f6c7c8085a8f60bb565b34d883e6a9578e79db8c8ef963bc494c',
    ROOT / 'qwen_layer_stage_recorded_audit.py': 'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4',
    ROOT / 'test_qwen_layer_stage_prefill_audit.py': '5b5ff6639cfd3f7b3cef90b0c1ac28de872793688c3e0ae8646e17dc76b48d57',
    ROOT / 'qwen-layer-stage-prefill-cpu-validator-tests-20260914.json': '797f5990994085abd3e28a9fb88fdc43e299ed8c9bb5a664bc3e94d8977cb78e',
    ROOT / 'runs/qwen-layer-stage-real9b-20260913/native/stdout.txt': 'dac1248a0b02ffa6010cd641834d2a43e1e7c5e92634bc28613fc7f73aaaf551',
    ROOT / 'qwen-layer-stage-real9b-expected-20260913.json': 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99',
    RUN / 'native/stdout.jsonl': '10971a2556dbbfecf6557ba67375646a035483b4c3cbe937a67b7f22adfb8597',
    RUN / 'receipt.json': '74065cafc7e9341707dc25cd1e90b3ccc5ed65c8a47ffa77712ceeaf889ff752',
}


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert not OUTPUT.exists() and not LOG.exists(), 'Preserve completed independent audit artifacts'
    for path, pin in PINS.items(): assert digest(path) == pin, 'Pinned evidence changed: ' + str(path)
    launch = json.loads((RUN / 'receipt.json').read_text())
    assert launch['passed'] is True and launch['execution']['passed'] is True
    assert launch['execution']['exit_code'] == 0 and launch['execution']['validated_outer_records'] == 2
    helper = ROOT / 'qwen_layer_stage_prefill_audit.py'
    spec = importlib.util.spec_from_file_location('frozen_peer24_prefill_oracle', helper)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    tick = time.monotonic(); started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    summary, error, code = None, None, 0
    try:
        summary = module.validate(RUN / 'native/stdout.jsonl',
            ROOT / 'runs/qwen-layer-stage-real9b-20260913/native/stdout.txt',
            ROOT / 'qwen-layer-stage-real9b-expected-20260913.json')
    except Exception:
        error, code = traceback.format_exc(), 1
    elapsed = time.monotonic() - tick
    for path, pin in PINS.items(): assert digest(path) == pin, 'Pinned evidence changed during audit: ' + str(path)
    transcript = ('Frozen CPU prefill validator on completed peer24 evidence.\n'
        'Same-run baseline is primary; historical cross-machine exactness remains required.\n'
        + (error if error else json.dumps(summary, indent=2, sort_keys=True, allow_nan=False)) + '\n')
    with LOG.open('x') as stream: stream.write(transcript)
    result = dict(schemaVersion=1, status='passed' if code == 0 else 'failed', cpuOnly=True,
        startedAtUTC=started, wallSeconds=elapsed, exitCode=code, auditScriptSHA256=digest(Path(__file__)),
        helperPath=str(helper), helperSHA256=PINS[helper], logPath=str(LOG), logSHA256=digest(LOG),
        pinnedInputs=[dict(path=str(path), sha256=pin, byteCount=path.stat().st_size) for path, pin in PINS.items()],
        launcherExitCode=launch['execution']['exit_code'], actualModeNativeEvidenceChecked=True,
        comparison=summary, error=error, newNativeExecutions=0, newBuilds=0, newModelPayloadReads=0,
        newSSHCalls=0, newProcessInventoryCalls=0, rewrittenPriorArtifacts=0,
        provenanceScope='Binds completed launcher receipt and exact stdout plus frozen CPU helpers/reference metadata. Root separately audits source/binary/model provenance and remote postflight.')
    with OUTPUT.open('x') as stream: json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status=result['status'], exitCode=code, receiptPath=str(OUTPUT),
        receiptSHA256=digest(OUTPUT), logSHA256=digest(LOG), auditScriptSHA256=digest(Path(__file__)),
        argmaxTokenID=summary['argmaxTokenID'] if summary else None), sort_keys=True))
    if error: print(error)
    return code


if __name__ == '__main__': raise SystemExit(main())
