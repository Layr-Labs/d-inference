"""Read saved receipts and source only; no oracle, native, model or remote work."""
import hashlib
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parent
RUN = RESEARCH / 'runs/qwen-long-prefill-solo-phase-peer24-20260914'
SIDECAR = RESEARCH / 'runs/qwen-long-prefill-solo-phase-sidecar-20260914'
PUBLIC = RESEARCH.parent / 'd-inference/experiments/cluster/inference'
DOC = HERE / 'QWEN_PREFILL_PHASE_VALIDATION.md'
NATIVE = '1d373d352a3f580043cbd6e20d354d6b1b8085ffc10e07874b5bd7bf9a5425ce'
PINS = {
    'build': (RESEARCH / 'qwen-prefill-phase-build-checkpoint-20260914.json', '77098ee041df2a6a8cd812fb5ebfb65e61ae2a8ab1b5ca1adcc9df29eeb9fb68'),
    'source_manifest': (RUN / 'source-manifest.json', 'b93dd1d94a6cb99fa2d5fdc69eb900182b6c2676b8e9a2f4e9dd7fefc9ae2f48'),
    'launcher': (RUN / 'receipt.json', 'c803dcb49f24d361f23e037b2084f1c7de6095868c1c435c2868660762769742'),
    'numerical': (RUN / 'independent-cpu-audit.json', '6e5616825b4ce3f637193e60f4bddde582582c33de16d9c25f9a9623e8b0593f'),
    'numerical_receipt': (RUN / 'independent-cpu-audit-receipt.json', 'f695a261ee9d755c18d840052af4c39cef2109868b4871bb17e3f54ab1ccc5f9'),
    'retrieval': (SIDECAR / 'receipt.json', '0e3411da0234330738a2bafcbc2e841ded1c641b0bed58b64a38a729281bcb69'),
    'trace': (SIDECAR / 'phase-trace.json', 'db96ed0144059987d878a8a1c4ed1d18608eb9edc80832a6ac28cb1d1b122f78'),
    'phase_audit': (SIDECAR / 'phase-audit.json', '1af25dfeac3df6977d0ddf2b6052d8883f8274ab8983ab66222d82e3b103e9a4'),
    'audit_manifest': (RESEARCH / 'phase-clock-audit-draft/manifest.json', 'a540ab7a9ddf115ea3e34712fe152dbcb21d532f03a3e0749b6fd347645e6176'),
}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read(path, maximum=1024 * 1024):
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    require(0 < len(data) <= maximum, 'Oversized/empty saved input')
    return data


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check():
    raw = {name: read(path) for name, (path, _) in PINS.items()}
    for name, (_, pin) in PINS.items():
        require(sha(raw[name]) == pin, 'Evidence pin changed: ' + name)
    data = {name: json.loads(value) for name, value in raw.items()}
    text = read(DOC, 32768).decode('utf8')
    require(text.splitlines()[2] == '> Last updated: 2026-09-14 · commit `e4df336bc`', 'Freshness stamp differs')
    require(len(text.splitlines()) < 150, 'Public record exceeds bounded length')
    require(not re.search(r'/Users/developer/tmp/|100\.\d+\.\d+\.\d+|darkbloom-24|peer24|password|ssh\s+\S+@', text, re.I), 'Private access detail in public document')
    require(not re.search(r'(?m)^\s*```', text), 'No runnable public launcher promised')
    links = re.findall(r'\[[^\]]+\]\(([^)]+)\)', text)
    for link in links:
        require(not link.startswith(('/', 'http:', 'https:')) and (PUBLIC / link).is_file(), 'Broken public source/document link')
    for _, pin in PINS.values():
        require(pin in text, 'Missing public evidence pin')
    require(NATIVE in text, 'Missing executable pin')

    build = data['build']
    require(build['passed'] is True and build['nativeSHA256'] == NATIVE and build['buildSeconds'] == 69.39, 'Build claim differs')
    require((build['adapterRecords'], build['recorderAccepted'], build['recorderRejected'], build['outputCases']) == (33, 6, 47, 20), 'Build/check counts differ')
    launch = data['launcher']
    require(launch['passed'] is True and launch['expected_native_sha256'] == NATIVE and launch['source_file_count'] == 317, 'Launcher identity claim differs')
    require(launch['source_bundle_raw_inputs_and_remote_model_unchanged_after_run'] is True, 'Saved recheck did not pass')
    require(launch['primary_failure'] is None and launch['cleanup_errors'] == [] and launch['post_run_errors'] == [], 'Saved launcher error')
    require(launch['execution']['exit_code'] == 0 and launch['execution']['validated_outer_records'] == 2 and launch['execution']['local_ssh_client_reaped'] is True, 'Completion claim differs')
    require(launch['execution']['remote_process_reaping_independently_verified'] is False, 'Remote waitpid scope changed')
    require(launch['remote_after']['memory']['remote_pid_inventory']['observed_processes'] == [], 'Final owned process observation not empty')
    samples = launch['remote_memory_samples']
    require(len(samples) == 24 and all(s['pressure_level'] == 1 and float(s['swap_used_bytes']) == 0 for s in samples), 'Resource observation claim differs')
    require((RUN / 'native/stderr.log').read_bytes() == b'', 'Native stderr is not empty')

    numeric = data['numerical']
    require(numeric['status'] == 'passed' and numeric['selectedTokenID'] == 271 and numeric['baselineMaximumTieCount'] == 1, 'Numerical/token claim differs')
    require(numeric['candidateStateMetadataAndDigestsExact'] is True and numeric['candidateLogitMetadataAndDigestExact'] is True, 'Digest equality claim differs')
    require(numeric['candidateFullVocabularyValuesExported'] is False and numeric['candidateNativeBytesIndependentlyReconstructed'] is False, 'Candidate byte scope differs')
    require((numeric['finalStateComponents'], numeric['finalStateLogicalBytes'], numeric['independentlyReconstructedStateOffsets'], numeric['opaqueNumericalStateComponents']) == (72, 319946784, 8, 64), 'State metadata claim differs')
    require(numeric['baselineFinalLogits']['shape'] == [1, 248320] and numeric['baselineFinalLogits']['dtype'] == 'bfloat16' and numeric['baselineFinalLogits']['byteCount'] == 496640, 'Logit metadata claim differs')
    memory = numeric['memory'][-1]
    require((memory['peakMLXBytesSinceProcessStart'], memory['activeMLXBytes'], memory['cachedMLXBytes']) == (6500375576, 4016, 0), 'MLX observation claim differs')

    retrieval, trace, audit = data['retrieval'], data['trace'], data['phase_audit']
    require(retrieval['passed'] is True and retrieval['remote_file_modified'] is False and retrieval['remote_process_reaping_verified'] is False, 'Read-only retrieval scope differs')
    require(len(raw['trace']) == 5505 and len(trace['events']) == 41 and trace['maximumEvents'] == 512, 'Sidecar bounds differ')
    require(trace['identity']['requestFingerprint'] == numeric['recordedRequestFingerprint'] == audit['recordedRequestFingerprint'], 'Recorded history identity differs')
    require(audit['status'] == 'passed' and audit['runtimeProvenanceRequiredSeparately'] is True and audit['baseOutputFullyValidated'] is False, 'Phase audit scope differs')
    events = {(e['phase'], e.get('frameSequence')): e for e in trace['events']}
    spans = [events[('prefill.committed', i)]['localUptimeNanoseconds'] - events[('prefill.begin', i)]['localUptimeNanoseconds'] for i in range(16)]
    require(sum(spans) == 18598524833, 'Chunk total differs')
    require(spans == [i['elapsedNanoseconds'] for i in audit['intervalGroups'][0]['intervals']], 'Saved audit chunk spans differ')
    for span in spans:
        require(f'{span // 10**9}.{span % 10**9:09d}' in text, 'Missing exact chunk duration')
    expected_groups = [18598524833, 797416, 2299084, 115931833, 136333]
    require([g['totalNanoseconds'] for g in audit['intervalGroups']] == expected_groups, 'Phase interval summary differs')
    clock = audit['localPrimaryClock']
    require(clock['stop'] - clock['start'] == numeric['timing']['elapsedNanoseconds'] == 18601628709, 'Main interval differs')
    for duration in ['18.601628709 s', '18.598524833 s', '0.797416 ms', '2.299084 ms', '115.931833 ms', '0.136333 ms']:
        require(duration in text, 'Missing interval claim')

    inventory = {f['path']: f for f in data['source_manifest']['files']}
    source_pins = {}
    for link in links:
        if not link.startswith('Sources/'):
            continue
        key = 'experiments/cluster/inference/' + link
        content = read(RUN / 'source' / key)
        require(sha(content) == inventory[key]['sha256'] and len(content) == inventory[key]['size_bytes'], 'Archived source link differs')
        source_pins[link] = sha(content)
    for phrase in ['no separate postflight or comprehensive provenance audit', 'not isolated GPU or kernel timings', 'does not measure recorder overhead', 'after this native execution had begun']:
        require(phrase in text, 'Required scope statement missing')
    require(data['audit_manifest']['frozenBeforeFirstCandidateAccess'] is True and data['audit_manifest']['frozenBeforeNativeInvocation'] is False and data['audit_manifest']['testsPassed'] == 72, 'Audit freeze chronology differs')
    require(all(read(path) == raw[name] for name, (path, _) in PINS.items()), 'Saved evidence changed during document check')
    return dict(status='passed', scope='saved_receipt_source_and_public_claim_check', documentSHA256=sha(text.encode()),
        lineCount=len(text.splitlines()), wordCount=len(text.split()), relativeLinksChecked=len(links),
        evidencePins={k: pin for k, (_, pin) in PINS.items()}, archivedSourcePins=source_pins,
        chunkSpanNanoseconds=spans, mainIntervalNanoseconds=18601628709,
        numericalOracleRerun=False, nativeOrRemoteExecution=False, modelPayloadRead=False,
        noNewComprehensiveProvenanceAudit=True)


if __name__ == '__main__':
    result = check()
    output = json.dumps(result, indent=2, sort_keys=True) + '\n'
    (HERE / 'source-claim-check.json').write_text(output)
    print(output, end='')
