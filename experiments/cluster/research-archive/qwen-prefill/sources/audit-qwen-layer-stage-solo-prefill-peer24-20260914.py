#!/usr/bin/env python3
"""Apply the unchanged prospective oracle to one completed, pinned solo run."""
from contextlib import redirect_stdout, redirect_stderr
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parent
RUN = ROOT / 'runs/qwen-layer-stage-solo-prefill-peer24-20260914'
HELPER = ROOT / 'qwen_layer_stage_solo_prefill_audit.py'
HELPER_SHA = '71ce8176280c795bcfebec27c63cea6d5b71f98a89bff12113507c6b515c4443'
STAGED_SHA = '8a61a536778b1988196ec3621c83210859055c414d2c29b5d8abcf80933eb22a'
NAME = 'qwen-layer-stage-solo-prefill-peer24-independent-cpu-comparison-20260914'
OUTPUT = ROOT / (NAME + '.json')
LOG = ROOT / (NAME + '.log')
PINS = {
    HELPER: HELPER_SHA,
    ROOT / 'test_qwen_layer_stage_solo_prefill_audit.py': '95b2dec9e015b51a50788331d8f48da44acd4a1827a2876c80f1fbd90a73a0f8',
    ROOT / 'qwen-layer-stage-solo-prefill-cpu-validator-tests-20260914.json': 'eefa7701fbb13a436999a44de10413e38141a882bab3d09f8b643616771edbb3',
    RUN / 'receipt.json': 'e1081799689c20aed672c0f6dda5b0cbf5edee5ca8f750d72cd8a4da4aa3ef43',
    RUN / 'native/stdout.jsonl': 'f89fc0c1c2c1cf9c657441fcdc379d44a4a77d290150c8378da2b7629943c942',
    RUN / 'remote-metadata/solo-reference.final.json': STAGED_SHA,
    RUN / 'inputs/solo-reference.staged.json': STAGED_SHA,
    RUN / 'inputs/solo-reference.origin.json': '782138cb276748af1b4a8d9f2d5d76461ae9973a5919e4f4317035c551b2976b',
}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pins():
    rows = []
    for path, expected in PINS.items():
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('Completed input/prospective oracle pin differs: ' + str(path))
        rows.append(dict(path=str(path), sha256=expected, byteCount=len(data)))
    return rows


def main():
    if len(sys.argv) != 1 or OUTPUT.exists() or LOG.exists():
        raise ValueError('Fixed run only; preserve existing comparison/log')
    receipt = dict(kind='qwen_layer_stage_solo_prefill_independent_cpu_comparison', schemaVersion=1,
        status='failed', exitCode=1, cpuOnly=True, comparison=None, error=None,
        startedAtUTC=datetime.now(timezone.utc).isoformat(), auditScriptSHA256=sha(Path(__file__)),
        helperPath=str(HELPER), helperSHA256=HELPER_SHA, logPath=str(LOG),
        actualModeNativeEvidenceChecked=True, newNativeExecutions=0, newBuilds=0,
        newSSHCalls=0, newProcessInventoryCalls=0, newModelPayloadReads=0,
        rewrittenPriorArtifacts=0, prospectiveOracleModified=False,
        provenanceScope='Pins complete actual stdout, retrieved/staged/origin descriptor, completed launcher and frozen CPU validation chain. Root separately verifies native build/archive, remote model attestations and process/resource postflight.')
    tick = time.monotonic()
    with LOG.open('x') as log, redirect_stdout(log), redirect_stderr(log):
        try:
            receipt['inputPinsBefore'] = pins()
            launch = json.loads((RUN / 'receipt.json').read_text())
            if not (launch['kind'] == 'remote_qwen_layer_stage_solo_prefill_launcher'
                    and launch['passed'] is True and launch['native_execution_attempted'] is True
                    and launch['execution']['exit_code'] == 0 and launch['execution']['passed'] is True
                    and launch['execution']['validated_outer_records'] == 2
                    and launch['primary_failure'] is None and launch['post_run_errors'] == []
                    and launch['cleanup_errors'] == [] and launch['native_baseline_forward'] is False):
                raise ValueError('Frozen launcher did not complete cleanly')
            tests = json.loads((ROOT / 'qwen-layer-stage-solo-prefill-cpu-validator-tests-20260914.json').read_text())
            if not (tests['status'] == 'passed' and tests['exitCode'] == 0 and tests['testsPassed'] == 54
                    and tests['actualSoloCandidateRead'] is False and tests['helperSHA256'] == HELPER_SHA):
                raise ValueError('Prospective oracle test receipt differs')
            spec = importlib.util.spec_from_file_location('frozen_solo_output_oracle_actual', HELPER)
            helper = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(helper)
            helper.context()
            receipt['baselinePinsBefore'] = helper.context()[0].verify_pins()
            comparison = helper.validate(RUN / 'native/stdout.jsonl',
                RUN / 'remote-metadata/solo-reference.final.json', STAGED_SHA)
            receipt['baselinePinsAfter'] = helper.context()[0].verify_pins()
            receipt['inputPinsAfter'] = pins()
            if receipt['inputPinsBefore'] != receipt['inputPinsAfter'] or receipt['baselinePinsBefore'] != receipt['baselinePinsAfter']:
                raise ValueError('Pinned inputs changed during independent audit')
            receipt.update(status='passed', exitCode=0, comparison=comparison,
                inputPinsUnchanged=True, launcherNativeExitCode=0, prospectiveTestsPassed=54)
            print(json.dumps(comparison, sort_keys=True, indent=2, allow_nan=False))
        except BaseException as error:
            receipt['error'] = type(error).__name__ + ': ' + str(error)
            traceback.print_exc()
    receipt['wallSeconds'] = time.monotonic() - tick
    receipt['logSHA256'] = sha(LOG)
    with OUTPUT.open('x') as stream:
        json.dump(receipt, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write('\n')
    print(json.dumps(dict(status=receipt['status'], exitCode=receipt['exitCode'],
        receipt=str(OUTPUT), receiptSHA256=sha(OUTPUT), error=receipt['error']), sort_keys=True))
    return receipt['exitCode']


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    raise SystemExit(main())
