"""Check retained completed metadata and public prose; never rerun an oracle."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parent
DESTINATION = RESEARCH.parent / 'd-inference/experiments/cluster/inference'
RUN = RESEARCH / 'runs/qwen-long-prefill-solo-peer24-20260914'
PINS = {
    'receipt.json': '4f8f98c9bdfb39d58ac9e1ce1027ecfc86dc6ae322963fe5b9f0e25b30395680',
    'independent-cpu-audit.json': 'b1473d9625e528501d4be686386bcd0f20a55918b7f219a8b77f5ccd984a0d11',
    'provenance-audit.json': 'e4742931354579669c15bd3a44d0bbc3756cf58468b533277128686c9246ade9',
    'source-manifest.json': '68dea3f5cff28eb641c31512b16d97eec046fbd692b58fcafd4f3bba4125c168',
    'native/stdout.jsonl': '2e4b6f707d87484fdd389d160890861a33707c992885495414e94c601f14d963',
}


def read(path):
    with path.open('rb') as stream: raw = stream.read(8 * 1024**2 + 1)
    assert len(raw) <= 8 * 1024**2
    return raw


def sha(raw): return hashlib.sha256(raw).hexdigest()


def check():
    document = HERE / 'QWEN_LONG_PREFILL_SOLO_VALIDATION.md'
    text = document.read_text()
    assert text.splitlines()[2] == '> Last updated: 2026-09-14 · commit `e4df336bc`'
    assert not any(value in text for value in ['/Users/', 'peer24', '100.109.', 'password', 'cluster-research/'])
    links = re.findall(r'\]\(([^)]+)\)', text)
    assert all((DESTINATION / link).is_file() for link in links)
    for name, pin in PINS.items():
        assert sha(read(RUN / name)) == pin and pin in text
    audit = json.loads(read(RUN / 'independent-cpu-audit.json'))
    provenance = json.loads(read(RUN / 'provenance-audit.json'))
    receipt = json.loads(read(RUN / 'receipt.json'))
    solo = json.loads(read(RUN / 'native/stdout.jsonl').splitlines()[1])
    assert audit['status'] == provenance['status'] == 'passed' and receipt['passed'] is True
    assert receipt['execution']['exit_code'] == 0 and read(RUN / 'native/stderr.log') == b''
    assert receipt['source_file_count'] == 300 and audit['completedFrames'] == 16
    assert audit['finalStateComponents'] == 72 and audit['finalStateLogicalBytes'] == 319946784
    assert audit['finalStateSHA256'] in text and audit['baselineFinalLogits']['logicalBytesSHA256'] in text
    assert audit['selectedTokenID'] == 271 and audit['baselineMaximumLogit'] == 21.25
    assert audit['candidateNativeBytesIndependentlyReconstructed'] is False
    assert audit['candidateFullVocabularyValuesExported'] is False
    values = provenance['resources']
    assert (values['samples'], values['nativeRSSObservationCount'], values['pressureLevels']) == (24, 19, [1])
    for key in ['initialActualFreeBytes', 'posthashActualFreeBytes', 'posthashReclaimableBytes', 'maximumSampledNativeRSSBytes']:
        assert format(values[key], ',') in text
    assert float(values['reportedSwapBaselineBytes']) == float(values['maximumReportedSwapIncreaseBytes']) == 0
    for row in audit['memory'][2:]:
        for key in ['activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart']:
            assert format(row[key], ',') in text
    postflight_path = RESEARCH / 'qwen-long-prefill-solo-peer24-postflight-20260914.json'
    postflight_pin = 'b6c3fc6f3d7286c24467b5a75138afd89cee125623d1a6c8efebeb951bf35395'
    assert sha(read(postflight_path)) == provenance['rootPostflightSHA256'] == postflight_pin and postflight_pin in text
    chronology = []
    for kind in ['serial', 'lookahead', 'solo']:
        folder = RUN if kind == 'solo' else RESEARCH / ('runs/qwen-long-prefill-ranks-' + kind + '-peer24-20260914')
        rows = read(folder / ('native/stdout.jsonl' if kind == 'solo' else 'rank-0/stdout.jsonl')).splitlines()
        report = json.loads(rows[1]); timing = report['execution']['timing']
        parent = json.loads(read(folder / 'receipt.json'))
        assert parent['expected_native_sha256'] == provenance['nativeBinarySHA256']
        assert parent['source_manifest_sha256'] == provenance['sourceManifestSHA256']
        assert report['promptFileSHA256'] == solo['promptFileSHA256']
        assert report['arithmeticEnvironmentSHA256'] == solo['arithmeticEnvironmentSHA256']
        assert format(timing['elapsedNanoseconds'] / 1e9, '.9f') + ' s' in text
        assert format(timing['promptTokensPerFirstTokenSecond'], '.6f') in text
        chronology.append(datetime.fromisoformat(parent['remote_initial_free_screen']['timestamp_utc']))
    assert chronology == sorted(chronology) and len(set(chronology)) == 3
    return dict(kind='long_solo_validation_document_checks', passed=True,
        documentSHA256=sha(read(document)), lineCount=len(text.splitlines()), wordCount=len(text.split()),
        relativeLinks=links, completedSoloInputPins=PINS, postflightSHA256=postflight_pin,
        chronologicalThreeObservationMetadataChecked=True, numericalOracleRerun=False,
        nativeExecuted=False, SSHExecuted=False, modelPayloadRead=False)


if __name__ == '__main__':
    print(json.dumps(check(), indent=2, sort_keys=True))
