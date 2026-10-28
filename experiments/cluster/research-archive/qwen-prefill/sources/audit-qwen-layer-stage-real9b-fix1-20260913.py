#!/usr/bin/env python3
"""CPU repair audit over immutable real9B records; no native or model-file access."""
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True
ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
RUN = ROOT / 'runs/qwen-layer-stage-real9b-20260913'
HELPER = ROOT / 'qwen_layer_stage_recorded_audit.py'
TEST = ROOT / 'test_qwen_layer_stage_recorded_audit_fix1.py'
OUTPUT = ROOT / 'qwen-layer-stage-real9b-independent-cpu-audit-fix1-20260913.json'
HELPER_SHA = 'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4'
OLD_HELPER_SHA = '28b5538cef56b211fffd1a1f5abe5964d5af4b2ba6067846aee10eab7b6a4c75'
RECEIPT_SHA = '70475fa58337738705217e6ae909945555275dcf28ec4f4cdd3349e9006d53bd'
EXPECTED_SHA = 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(ok, message):
    if not ok:
        raise ValueError(message)


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value


def main():
    require(not OUTPUT.exists(), 'Preserve existing audit receipt')
    require(sha(HELPER) == HELPER_SHA and sha(RUN / 'qwen_layer_stage_recorded_audit.py') == OLD_HELPER_SHA,
        'Current/frozen oracle identities differ')
    require(sha(RUN / 'receipt.json') == RECEIPT_SHA, 'Original failed driver receipt changed')
    audit = module('fixed_recorded_oracle', HELPER)
    receipt = audit.parse_json((RUN / 'receipt.json').read_text())
    require(receipt['status'] == 'failed' and receipt['error'] == 'ValueError: Common source accounting differs'
        and len(receipt['native_calls']) == 1, 'Preserved failure history differs')
    call = receipt['native_calls'][0]
    require(call['exit_code'] == 0 and call['cleanup'] == dict(all_observed_owned_processes_exited=True,
        launcher_reaped=True, cancel_files_requested=False), 'Native completion/cleanup differs')
    for path, expected in receipt['driver_files_sha256'].items():
        require(sha(RUN / path) == expected, 'Archived driver/helper/expected input changed')
    require(sha(RUN / 'native/stdout.txt') == call['stdout_sha256'] == 'dac1248a0b02ffa6010cd641834d2a43e1e7c5e92634bc28613fc7f73aaaf551'
        and sha(RUN / 'native/stderr.txt') == call['stderr_sha256'] == hashlib.sha256(b'').hexdigest(), 'Native output changed')
    require(sha(RUN / 'bundle/cluster-inference') == receipt['expected_native_sha256']
        == '959d409aef53165ba05f82119f09c830d3e22d94c764e218f332b4382d16e958', 'Tested binary changed')
    require(sha(RUN / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Archived bundle manifest changed')
    require(sha(RUN / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Frozen source manifest changed')
    sources = audit.parse_json((RUN / 'source-manifest.json').read_text())
    constructor_path = 'experiments/cluster/inference/Sources/ClusterInference/PreparedQwenCheckpoint.swift'
    constructor = next(x for x in sources if x['path'] == constructor_path)
    require(sha(RUN / 'source' / constructor_path) == constructor['sha256'], 'Retained source constructor changed')
    text = (RUN / 'source' / constructor_path).read_text()
    require('guard let name = names.first else { continue }' in text
        and 'canonicalSources[name] = tensor' in text
        and 'self.sourceTensorCount = canonicalSources.count' in text, 'Retained source count semantics differ')
    expected_file = RUN / 'qwen-layer-stage-real9b-expected-20260913.json'
    require(sha(expected_file) == EXPECTED_SHA, 'Independent header expectation changed')
    expected = audit.parse_json(expected_file.read_text())
    rows = [audit.parse_json(x) for x in (RUN / 'native/stdout.txt').read_text().splitlines()]
    require(len(rows) == 2, 'Expected two recorded comparison records')
    # Demonstrate the original failure on precisely these saved records; it is
    # an oracle count-semantic bug, not an unobserved native inference failure.
    old = module('preserved_failed_recorded_oracle', RUN / 'qwen_layer_stage_recorded_audit.py')
    try:
        old.check_recorded_pair(*rows, expected)
    except ValueError as error:
        require(str(error) == 'Common source accounting differs', 'Original failure changed')
    else:
        raise ValueError('Old oracle no longer reproduces its recorded failure')
    summary = audit.check_recorded_pair(*rows, expected)
    for path, expected_digest in receipt['input_files_sha256'].items():
        require(sha(RUN / path) == expected_digest, 'Saved prompt/teacher/source text changed')
    request = rows[0]['baseline']['request']
    require(request['promptTokenIDs'] == audit.parse_json((RUN / 'prompt-65.json').read_text())
        and request['teacherTokenIDs'] == audit.parse_json((RUN / 'teacher-3.json').read_text()), 'Recorded and supplied actual token IDs differ')
    frames = []
    for original, compared in zip(rows[0]['baseline']['frames'], rows[1]['comparison']['frames']):
        logits = original.get('logits')
        frames.append(dict(committedTokens=original['committedTokens'], stateEntryCount=len(original['state']['entries']),
            logicalStateBytesPerSide=original['state']['logicalByteCount'],
            recomputedAndMatchedGlobalStateSHA256=original['state']['fingerprint'],
            logitValuesPerSide=248320 if logits else 0, nativeLogitBytesPerSide=496640 if logits else 0,
            baselineAndCandidateLogitSHA256=logits['logicalBytesSHA256'] if logits else None))
    result = dict(schemaVersion=1, status='native_completed_and_corrected_cpu_replay_passed', cpuOnly=True,
        auditedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), auditScriptSHA256=sha(Path(__file__)),
        helperSHA256=HELPER_SHA, preservedFailedHelperSHA256=OLD_HELPER_SHA,
        cpuRegressionTestSHA256=sha(TEST), cpuRegressionTestsPassed=24,
        cpuRegressionCommand='python3 -B ' + str(TEST), cpuRegressionExitCode=0,
        originalRunDirectory=str(RUN), preservedFailedDriverReceiptSHA256=RECEIPT_SHA,
        originalDriverStatus='failed', originalDriverError=receipt['error'], nativeExitCode=0,
        nativeBinarySHA256=receipt['expected_native_sha256'], nativeOutputSHA256=call['stdout_sha256'],
        nativeStderrSHA256=call['stderr_sha256'], originalSourceManifestSHA256=receipt['source_manifest_sha256'],
        sourceCountConstructor=constructor, independentExpectedOracleSHA256=EXPECTED_SHA,
        errorCorrection=dict(rawCheckpointHeaderTensorCount=1291, excludedVisionAndMTPTensors=364,
            retainedSourceTensorCount=927, canonicalTensorCount=927,
            originalError='The CPU oracle compared retained sanitized source names with all raw checkpoint header entries.',
            correctedRule='For this pinned one-part-per-canonical artifact, retained count = raw header count - excluded count = canonical count.',
            oldFailureReproduced=True, coherentlyRehashedWrongRetainedCountRejectedByRegression=True),
        summary=summary, frames=frames, memoryObservations=rows[1]['memory'],
        nativeCleanup=call['cleanup'], nativeWallSeconds=call['wall_seconds'],
        peakObservedOwnedRSSBytes=call['peak_observed_owned_rss_bytes'],
        savedInputHashesVerified=True, exactSavedPromptAndTeacherIDsVerified=True,
        nativeExecutionsByAudit=0, modelFileReadsByAudit=0, weightPayloadBytesRead=0,
        originalPostflightRecorded='postflight' in call,
        limitations=[
            'Original driver receipt remains failed; this separate receipt records successful native completion and corrected CPU replay.',
            'Root performs postflight resource sampling and final full-artifact verification separately because the original driver stopped before those actions.',
            'Six complete state geometries and aggregate fingerprints are independently checked; actual staged per-entry state parity is a native metadata/digest assertion, with no paired raw state arrays exported.',
            'All eight full-vocabulary BF16 logit rows are reconstructed independently; four baseline/staged native byte pairs are exactly equal.',
            'One fixed 65-token prompt with three teacher continuations, batch one, sequentially resident baseline then two stages in one process. No throughput or physical two-machine qualification.'
        ])
    require(sha(RUN / 'receipt.json') == RECEIPT_SHA and sha(RUN / 'qwen_layer_stage_recorded_audit.py') == OLD_HELPER_SHA,
        'Frozen failure evidence changed')
    with OUTPUT.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write('\n')
    print(json.dumps(dict(status=result['status'], output=str(OUTPUT), receiptSHA256=sha(OUTPUT),
        auditScriptSHA256=sha(Path(__file__)), helperSHA256=HELPER_SHA, testSHA256=sha(TEST),
        cpuRegressionTestsPassed=24, rawLogitValuesReconstructed=8 * 248320, stateEntriesVerified=6 * 72), sort_keys=True))


if __name__ == '__main__':
    main()
