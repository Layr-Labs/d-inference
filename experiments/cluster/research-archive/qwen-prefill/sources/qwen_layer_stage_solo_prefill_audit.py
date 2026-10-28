"""Prospective CPU oracle for fixed9B solo prefill; no candidate raw bytes exist.

The caller supplies the independently admitted SHA of the actual staged reference
file. Its bytes may differ from origin782... through JSON reserialization, but
its closed integer-only content must be exactly the frozen baseline descriptor.
"""
import hashlib
import importlib.util
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent
EXPORTER_SHA = 'd5571a1c3ccb3071e2c271fedd76b938eaae3096e88872da80790c68fd1514fc'
ORIGIN_SHA = '782138cb276748af1b4a8d9f2d5d76461ae9973a5919e4f4317035c551b2976b'
EXPORT_RECEIPT_SHA = 'a44a4ea710f9ed49338aa523fb647779cb7c031d1201716a1f179f26b05f3f72'
EXPORT_TESTS_SHA = 'a0778524e82e940d73c06c78936ebf1238f591808c88d426d78cad326076cec1'
MAX_STDOUT_BYTES = 512 * 1024
UINT64_MAX = 2**64 - 1
MAX_REQUEST_NS = 180 * 10**9
_CONTEXT = None


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_bounded(path, limit):
    with Path(path).open('rb') as stream:
        data = stream.read(limit + 1)
    require(0 < len(data) <= limit, 'Empty or oversized input: ' + str(path))
    return data


def context():
    global _CONTEXT
    if _CONTEXT is None:
        path = ROOT / 'export_prefill_solo_reference_20260914.py'
        require(sha(path.read_bytes()) == EXPORTER_SHA, 'Frozen descriptor exporter differs')
        for filename, pin in [
            ('qwen-layer-stage-solo-prefill-reference-export-20260914.json', EXPORT_RECEIPT_SHA),
            ('prefill-solo-reference-export-cpu-tests-20260914.json', EXPORT_TESTS_SHA),
        ]:
            require(sha(read_bounded(ROOT / filename, 128 * 1024)) == pin, 'Frozen export provenance differs')
        spec = importlib.util.spec_from_file_location('solo_output_frozen_reference_exporter', path)
        exporter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(exporter)
        helper, descriptor, derived_bytes, derived, _, _ = exporter.prepare()
        original = read_bounded(exporter.OUTPUT, exporter.MAX_DESCRIPTOR_BYTES)
        require(sha(original) == ORIGIN_SHA and original == derived_bytes, 'Origin descriptor differs from its baseline derivation')
        receipt = json.loads(exporter.RECEIPT.read_text())
        require(receipt['status'] == 'passed' and receipt['exitCode'] == 0 and receipt['inputPinsUnchanged'] is True,
                'Origin export did not complete')
        helper.exact(receipt['selection'], descriptor['selection'], 'export selection')
        helper.exact(receipt['derived'], derived, 'export CPU derivation')
        helper.exact(receipt['descriptorSHA256'], ORIGIN_SHA, 'export origin hash')
        expected = helper.base_helper().parse_json(exporter.EXPECTED.read_text())
        baseline_rows, _ = helper.read_rows(exporter.CURRENT)
        named_bytes = baseline_rows[1]['conservativeStateAndBoundaryBytes']
        _CONTEXT = exporter, helper, descriptor, derived, expected, named_bytes
    return _CONTEXT


def check_reference_bytes(data, expected_reference_sha256):
    exporter, helper, descriptor, _, _, _ = context()
    helper.base_helper().sha_string(expected_reference_sha256)
    require(type(data) is bytes and sha(data) == expected_reference_sha256, 'Actual staged reference SHA differs from caller pin')
    return exporter.validate_descriptor_bytes(data, descriptor, helper)


def parse_rows(data):
    require(type(data) is bytes and 0 < len(data) <= MAX_STDOUT_BYTES, 'Solo stdout exceeds its byte bound')
    lines = data.splitlines()
    require(len(lines) == 2 and all(lines), 'Solo requires exactly ready and terminal records')
    base = context()[1].base_helper()
    rows = []
    for line in lines:
        quoted, escaped, depth = False, False, 0
        for byte in line:
            if quoted:
                if escaped: escaped = False
                elif byte == 92: escaped = True
                elif byte == 34: quoted = False
            elif byte == 34: quoted = True
            elif byte in (91, 123):
                depth += 1
                require(depth <= 16, 'Solo JSON nesting exceeds bound')
            elif byte in (93, 125):
                depth -= 1
                require(depth >= 0, 'Unbalanced solo JSON')
        require(depth == 0 and not quoted, 'Unterminated solo JSON')
        value = base.parse_json(line.decode('utf-8'))
        require(type(value) is dict, 'Solo record must be an object')
        rows.append(value)
    return rows


def uint64(value, label):
    require(type(value) is int and 0 <= value <= UINT64_MAX, 'Invalid UInt64: ' + label)
    return value


def check_timing(timing, prompt_count, helper):
    require(type(timing) is dict, 'Timing must be an object')
    variable = {'startUptimeNanoseconds', 'stopUptimeNanoseconds', 'elapsedNanoseconds',
        'promptTokensPerFirstTokenSecond', 'postStopThroughRequestCloseNanoseconds'}
    flags = dict(includesFreshRequestState=True, includesFiniteArgmaxAndScalarReadback=True,
        includesBoundedCommitMetadata=True, includesTransport=False,
        excludesLoadReadinessFinalCaptureAndRetirement=True)
    require(set(timing) == variable | set(flags), 'Solo timing fields differ')
    helper.exact({key: timing[key] for key in flags}, flags, 'timing scope')
    start = uint64(timing['startUptimeNanoseconds'], 'start')
    stop = uint64(timing['stopUptimeNanoseconds'], 'stop')
    elapsed = uint64(timing['elapsedNanoseconds'], 'elapsed')
    post = uint64(timing['postStopThroughRequestCloseNanoseconds'], 'post-stop close')
    require(stop > start and stop - start == elapsed and 0 < elapsed <= MAX_REQUEST_NS,
            'Solo clock interval or subtraction differs')
    require(post <= MAX_REQUEST_NS and elapsed + post <= MAX_REQUEST_NS and stop + post <= UINT64_MAX,
            'Solo post-stop close exceeds clock/deadline bounds')
    rate = timing['promptTokensPerFirstTokenSecond']
    require(type(rate) in (float, int) and math.isfinite(rate) and rate > 0,
            'Solo rate must be finite and positive')
    derived = float(prompt_count) * 1e9 / float(elapsed)
    require(rate == derived, 'Solo rate differs from exact native duration arithmetic')
    return dict(startUptimeNanoseconds=start, stopUptimeNanoseconds=stop, elapsedNanoseconds=elapsed,
        postStopThroughRequestCloseNanoseconds=post, diagnosticPromptTokensPerFirstTokenSecond=derived)


def check_memory(memory, helper):
    phases = ['before_solo_model_load', 'solo_model_loaded_no_request_state',
        'solo_request_retired_weights_resident', 'solo_model_released_cache_cleared']
    require(type(memory) is list and len(memory) == len(phases), 'Solo memory phase count differs')
    previous_peak = 0
    for row, phase in zip(memory, phases):
        require(type(row) is dict and set(row) == {'phase', 'activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart'},
                'Solo memory fields differ')
        helper.exact(row['phase'], phase, 'memory phase order')
        active = uint64(row['activeMLXBytes'], 'active MLX bytes')
        uint64(row['cachedMLXBytes'], 'cached MLX bytes')
        peak = uint64(row['peakMLXBytesSinceProcessStart'], 'cumulative MLX peak')
        require(peak >= max(active, previous_peak), 'Solo cumulative MLX peak is inconsistent')
        previous_peak = peak
    helper.exact(memory[-1]['cachedMLXBytes'], 0, 'released model cache')
    return dict(observations=memory, isRSS=False, nativeModelReleaseAssertion=True)


def validate_reports(rows, reference_data, expected_reference_sha256):
    """Pure record checker; tests may provide synthetic candidate dictionaries."""
    exporter, helper, origin, derived, expected, named_bytes = context()
    reference = check_reference_bytes(reference_data, expected_reference_sha256)
    require(type(rows) is list and len(rows) == 2, 'Solo requires two records')
    ready, report = rows
    require(type(ready) is dict and type(report) is dict and type(ready.get('request')) is dict,
            'Solo outer record/request types differ')
    recorded = ready['request']
    simple, recorded_fp = helper.request_identity(recorded)
    require(simple != origin['request']['baselineRequestFingerprint']
            and recorded_fp != origin['request']['baselineRecordedRequestFingerprint'],
            'Solo reused the separately recorded baseline request')
    helper.exact(recorded['steps'][-1]['frame'], origin['request']['finalFrame'], 'reference final frame')
    helper.exact(sha(','.join(map(str, recorded['promptTokenIDs'])).encode()),
        origin['request']['promptTokenIDsSHA256'], 'actual prompt SHA')
    helper.exact(ready, dict(kind='qwen_layer_stage_solo_prefill_ready', schemaVersion=1,
        verifiedModelLoaded=True, freshRequestStateCreated=False,
        referenceFileSHA256=expected_reference_sha256,
        baselineEvidenceFingerprint=origin['baselineEvidenceFingerprint'], request=recorded, source=origin['source']),
        'solo ready')
    require(type(report.get('execution')) is dict, 'Missing solo execution')
    execution = report['execution']
    commits = []
    for step in recorded['steps']:
        f = step['frame']
        commits.append(dict(frame=f, committedTokens=f['tokenOffset'] + f['tokenCount'],
            outputKind='logits' if f['finalPromptChunk'] else 'evaluation_handle',
            outputShape=[1, recorded['vocabularySize']] if f['finalPromptChunk'] else [1, 1],
            outputDType=origin['finalLogits']['dtype']))
    final_frame = origin['request']['finalFrame']
    selection = dict(requestFingerprint=simple, recordedRequestFingerprint=recorded_fp,
        frame=final_frame, committedTokens=origin['request']['committedTokens'],
        vocabularySize=recorded['vocabularySize'], outputOrdinal=0, policy=origin['selection']['policy'],
        tokenID=origin['selection']['tokenID'], logitsShape=origin['finalLogits']['shape'],
        logitsDType=origin['finalLogits']['dtype'], selectionDType='uint32', allLogitsFinite=True)
    require('timing' in execution and 'finalState' in execution, 'Solo final state/timing missing')
    timing = check_timing(execution['timing'], recorded['request']['promptCount'], helper)
    helper.check_state(execution['finalState'], recorded['request']['promptCount'], expected)
    expected_execution = dict(kind='qwen_layer_stage_solo_prefill_request_result', schemaVersion=1,
        correctnessOnly=True, throughputMeasurementValid=False, matchedChunkSolo=True, physicalTransferQualified=False,
        referenceFileSHA256=expected_reference_sha256, baselineEvidenceFingerprint=origin['baselineEvidenceFingerprint'],
        source=origin['source'], request=recorded, commits=commits, selection=selection,
        referenceSelectedTokenID=origin['selection']['tokenID'], referenceMaximumTieCount=origin['selection']['maximumTieCount'],
        finalLogits=origin['finalLogits'], finalState=origin['finalState'], timing=execution['timing'],
        completedFrames=len(commits), committedTokens=origin['request']['committedTokens'],
        stateMetadataAndDigestsExact=True, logitMetadataAndDigestExact=True, selectedTokenExact=True,
        nativeLogitBytesCompared=False, perFrameStateCaptures=0, perFrameLogitCaptures=0,
        finalStateCaptures=1, finalLogitCaptures=1, nativeTokenSelections=1, allRequestStateRetired=True)
    helper.exact(execution, expected_execution, 'solo complete execution')
    require('memory' in report, 'Solo memory observations missing')
    memory = check_memory(report['memory'], helper)
    # The frozen baseline oracle independently recomputed this model/config
    # formula during context admission; it is not process memory accounting.
    helper.exact(report, dict(kind='qwen_layer_stage_solo_prefill_report', schemaVersion=1,
        completed=True, correctnessOnly=True, throughputMeasurementValid=False,
        interprocessTransportUsed=False, physicalTransferQualified=False, allRequestStateRetired=True,
        modelReleased=True, conservativeStateAndBoundaryBytes=named_bytes, execution=execution, memory=report['memory']),
        'solo terminal report')
    return dict(status='passed', scope='registered_real9b_natural65_chunk32_output1_solo',
        requestFingerprint=simple, recordedRequestFingerprint=recorded_fp,
        referenceOriginSHA256=ORIGIN_SHA, stagedReferenceSHA256=expected_reference_sha256,
        stagedReferenceContentExactOrigin=True, baselineEvidenceFingerprint=origin['baselineEvidenceFingerprint'],
        baselineExportReceiptSHA256=EXPORT_RECEIPT_SHA, baselineExportTestsSHA256=EXPORT_TESTS_SHA,
        source=origin['source'], completedFrames=len(commits), committedTokens=origin['request']['committedTokens'],
        finalStateComponents=len(origin['finalState']['entries']), finalStateLogicalBytes=origin['finalState']['logicalByteCount'],
        finalStateSHA256=origin['finalState']['fingerprint'], finalLogits=origin['finalLogits'],
        finalLogitDigestAgreement=True, finalStateMetadataAndDigestAgreement=True,
        argmaxTokenID=origin['selection']['tokenID'], referenceMaximumTieCount=origin['selection']['maximumTieCount'],
        referenceMaximumLogit=derived['maximumLogit'], candidateNativeLogitBytesCompared=False,
        reconstructedCandidateNativeRows=0, perFrameCandidateStateCaptures=0, perFrameCandidateLogitCaptures=0,
        timing=timing, memory=memory, throughputQualified=False, physicalTransferQualified=False,
        allRequestStateRetiredNativeAssertion=True, modelReleasedNativeAssertion=True,
        limitations=[
            'Candidate exports final logit metadata/SHA, not raw values; only the separately recorded baseline values are independently reconstructed.',
            'Candidate and baseline state comparisons use all72 component metadata/SHA entries; raw state arrays are not exported.',
            'Native scalar selection, commit, interval ordering, retirement and model release are source-bound assertions. This CPU oracle validates their records and arithmetic, not an independent native trace.',
            'The reported post-stop duration ends after request close; later model release/cache clearing and report serialization are outside that field.',
            'MLX allocator observations are not RSS or whole-process memory, and this one fresh-process diagnostic does not establish equivalent cache warmth or qualified speedup.'])


def validate(stdout_path, staged_reference_path, expected_reference_sha256):
    exporter = context()[0]
    before = exporter.verify_pins()
    stdout = read_bounded(stdout_path, MAX_STDOUT_BYTES)
    reference = read_bounded(staged_reference_path, exporter.MAX_DESCRIPTOR_BYTES)
    result = validate_reports(parse_rows(stdout), reference, expected_reference_sha256)
    require(read_bounded(stdout_path, MAX_STDOUT_BYTES) == stdout
        and read_bounded(staged_reference_path, exporter.MAX_DESCRIPTOR_BYTES) == reference,
        'Candidate/reference files changed during audit')
    require(exporter.verify_pins() == before, 'Frozen baseline inputs changed during audit')
    result.update(stdoutSHA256=sha(stdout), stdoutBytes=len(stdout), stagedReferenceBytes=len(reference),
        helperSHA256=sha(Path(__file__).read_bytes()), frozenInputsUnchanged=True)
    return result


if __name__ == '__main__':
    import sys
    require(len(sys.argv) == 4, 'Usage: qwen_layer_stage_solo_prefill_audit.py STDOUT STAGED_REFERENCE EXPECTED_REFERENCE_SHA256')
    print(json.dumps(validate(*sys.argv[1:]), sort_keys=True, indent=2, allow_nan=False))
