#!/usr/bin/env python3
"""Root-owned, prospectively fixed fresh-cohort diagnostic; never a speedup gate."""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent / 'd-inference'
PLAN = ROOT / 'prefill-counterbalanced-study-plan-20260914.json'
OUT = ROOT / 'runs/qwen-prefill-cold-cohort-study-20260914'
CHILD = None
COMMAND_CLEANUP_ERRORS = []


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def write_new(path, value):
    with Path(path).open('x') as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write('\n')
    Path(path).chmod(0o600)


def load_oracle(path):
    spec = importlib.util.spec_from_file_location('frozen_prefill_rank_study_oracle', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_pins(plan):
    for row in plan['pinnedFiles']:
        if sha(row['path']) != row['sha256']:
            raise ValueError('Prospective pinned file changed: ' + row['path'])


def stop_child():
    global CHILD
    if CHILD is None or CHILD.poll() is not None:
        return
    try:
        os.killpg(CHILD.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        CHILD.wait(timeout=45)
    except subprocess.TimeoutExpired:
        os.killpg(CHILD.pid, signal.SIGKILL)
        CHILD.wait(timeout=5)
        raise RuntimeError('Owned child required SIGKILL; remote cleanup needs inspection')


def command(args, log, seconds):
    global CHILD
    with log.open('x') as stream:
        CHILD = subprocess.Popen([str(value) for value in args], stdout=stream,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = CHILD.wait(timeout=seconds)
            if code:
                raise RuntimeError('Owned command failed with exit ' + str(code) + ': ' + str(log))
        except BaseException as error:
            stream.write('\nRoot command error: ' + type(error).__name__ + ': ' + str(error) + '\n')
            stream.flush()
            try:
                stop_child()
            except BaseException as cleanup:
                COMMAND_CLEANUP_ERRORS.append(type(cleanup).__name__ + ': ' + str(cleanup))
            raise
        finally:
            if CHILD is not None and CHILD.poll() is not None:
                CHILD = None


def interrupted(signum, _frame):
    raise RuntimeError('Root study interrupted by signal ' + str(signum))


def trial(plan, item, oracle):
    verify_pins(plan)
    name = 'trial-%02d-%s-%s' % (item['index'], item['role'], item['label'])
    run = OUT / name
    launcher = ROOT / 'remote-prefill-rank-launcher-draft/launch_remote_prefill_ranks.py'
    command([sys.executable, '-B', launcher,
        '--release', REPO / 'experiments/cluster/inference/.build/release',
        '--runtime', REPO / 'experiments/cluster/runtime', '--output', run,
        '--input-origin', ROOT / 'runs/qwen9-output-boundaries-20260913',
        '--expected-inventory', ROOT / 'qwen-layer-stage-real9b-expected-20260913.json',
        '--host', plan['host'], '--remote-model-dir', plan['remoteModelDirectory'],
        '--artifact-aggregate-sha256', plan['artifactSHA256'],
        '--expected-native-sha256', plan['nativeSHA256'],
        '--stage-prefill-policy', item['policy'], '--timeout-seconds', '180'],
        OUT / (name + '-launch.log'), 600)
    receipt_path = run / 'receipt.json'
    launch = read(receipt_path)
    assert launch['passed'] is True and launch['cohort']['exit_codes'] == [0, 0]
    assert launch['cohort']['validation']['records_per_rank'] == [2, 2]
    postflight = OUT / (name + '-postflight.json')
    command([sys.executable, '-B', ROOT / 'postflight-remote-prefill-ranks-20260914.py', run, postflight],
            OUT / (name + '-postflight.log'), 30)
    receipt_pin = sha(receipt_path)
    provenance = run / 'independent-provenance-audit.json'
    command([sys.executable, '-B', ROOT / 'verify-remote-prefill-rank-provenance-20260914.py', run,
        '--policy', item['policy'], '--receipt-sha256', receipt_pin,
        '--postflight', postflight, '--postflight-sha256', sha(postflight), '--output', provenance],
        OUT / (name + '-provenance.log'), 60)
    compared = oracle.validate([run / ('rank-%d/stdout.jsonl' % rank) for rank in (0, 1)],
        ROOT / 'runs/qwen-layer-stage-prefill-peer24-20260914/native/stdout.jsonl',
        ROOT / 'qwen-layer-stage-real9b-expected-20260913.json', launch['epoch'], item['policy'])
    assert compared['status'] == 'passed' and compared['throughputQualified'] is False
    assert sha(receipt_path) == receipt_pin
    comparison_path = run / 'independent-cpu-comparison.json'
    write_new(comparison_path, dict(status='passed', cpuOnly=True,
        planSHA256=sha(PLAN), launcherReceiptSHA256=receipt_pin, comparison=compared))
    verify_pins(plan)
    result = dict(item, epoch=launch['epoch'], run=str(run),
        launcherReceiptSHA256=receipt_pin, provenanceSHA256=sha(provenance),
        comparisonSHA256=sha(comparison_path), postflightSHA256=sha(postflight),
        elapsedNanoseconds=compared['timing']['elapsedNanoseconds'],
        diagnosticPromptTokensPerFirstTokenSecond=compared['timing']['diagnosticPromptTokensPerFirstTokenSecond'])
    write_new(OUT / (name + '-result.json'), result)
    print(json.dumps(result, sort_keys=True), flush=True)
    return result


def main():
    assert len(sys.argv) == 2 and sha(PLAN) == sys.argv[1], 'Supply frozen prospective plan SHA'
    plan = read(PLAN)
    verify_pins(plan)
    assert not OUT.exists(), 'Preserve previous complete or partial study'
    assert len(plan['trials']) == 14 and plan['replacementPointsAllowed'] is False
    OUT.mkdir(mode=0o700)
    write_new(OUT / 'plan.json', plan)
    handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    result = dict(kind='prefill_fresh_cohort_counterbalanced_diagnostic', schemaVersion=1,
        planSHA256=sha(PLAN), scriptSHA256=sha(Path(__file__)), startedAtUTC=datetime.now(timezone.utc).isoformat(),
        passed=False, throughputQualified=False, physicalTwoMachineExecution=False,
        residentWarmthQualified=False, completedTrials=[], error=None, cleanupError=None,
        commandCleanupErrors=COMMAND_CLEANUP_ERRORS)
    try:
        oracle = load_oracle(ROOT / 'qwen_layer_stage_prefill_rank_audit.py')
        tick = time.monotonic()
        for item in plan['trials']:
            if time.monotonic() - tick > 2700:
                raise RuntimeError('Study total elapsed admission deadline exceeded')
            result['completedTrials'].append(trial(plan, item, oracle))
        result['passed'] = True
    except BaseException as error:
        result['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            stop_child()
        except BaseException as error:
            result['cleanupError'] = type(error).__name__ + ': ' + str(error)
            result['passed'] = False
        result['finishedAtUTC'] = datetime.now(timezone.utc).isoformat()
        write_new(OUT / 'study-receipt.json', result)
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    print(json.dumps(dict(passed=result['passed'], completedTrials=len(result['completedTrials']),
        error=result['error'], cleanupError=result['cleanupError'], receiptSHA256=sha(OUT / 'study-receipt.json')), sort_keys=True), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    raise SystemExit(main())
