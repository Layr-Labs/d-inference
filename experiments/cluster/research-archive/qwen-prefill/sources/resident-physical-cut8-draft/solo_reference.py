"""Closed retained 8K diagnostic reference; candidate exports digests, not row values."""
import copy
import math
from pathlib import Path
import struct
import uuid
from binding_inputs import snapshot
from recorded_math import logical_bytes
from stage_checks.common import canonical, digest, exact, integer, parse, require
from stage_checks.long_identity import environment_receipt, request_identity, validate_request
from stage_checks.long_profile import PROFILE, PROFILE_SHA256

REFERENCE_PINS = {
    'stdout.jsonl': 'da85eb1e79a43c16575e6a8ffd48594ccb72306c16543a1e02c24903b89c154a',
    'prompt.json': 'ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997',
    'cpu-receipt.json': 'bff08ef62a84c2ebd950ef692989abe6c037773cb1cc2af50bf5a31acc63c14c',
    'cpu-audit.json': '4dfce50fa8be3245377a2d6926ec23b0bebb3d25c3a4fc43cb43d2b2b14619de',
    'parent.json': '02a366c7e4d5c8acd2bfb7a3b69d42fa9de7b602c3885f9c7b5a64f1a0037854',
}


def fields(value, names, label):
    require(type(value) is dict and set(value) == set(names.split()), label + ' fields differ')


def timing(value):
    flags = dict(includesFreshRequestState=True, includesFiniteArgmaxAndScalarReadback=True,
                 includesBoundedCommitMetadata=True, includesTransport=False,
                 excludesLoadReadinessFinalCaptureAndRetirement=True)
    fields(value, 'startUptimeNanoseconds stopUptimeNanoseconds elapsedNanoseconds '
           'promptTokensPerFirstTokenSecond postStopThroughRequestCloseNanoseconds ' + ' '.join(flags), 'timing')
    for key, wanted in flags.items():
        require(type(value[key]) is bool and value[key] is wanted, 'Timing flag differs: ' + key)
    start = integer(value['startUptimeNanoseconds'], 0, 2**64-1)
    stop = integer(value['stopUptimeNanoseconds'], 0, 2**64-1)
    elapsed = integer(value['elapsedNanoseconds'], 1, 300*10**9)
    post = integer(value['postStopThroughRequestCloseNanoseconds'], 0, 300*10**9)
    require(stop > start and stop-start == elapsed and stop+post <= 2**64-1, 'Timing interval differs')
    rate = value['promptTokensPerFirstTokenSecond']
    require(type(rate) in (int, float) and math.isfinite(rate) and rate == 8192e9/elapsed, 'Timing rate differs')
    return dict(start=start, stop=stop, closed=stop+post, elapsed_ns=elapsed)


class Reference:
    def __init__(self, directory=None):
        self.directory = Path(directory) if directory else Path(__file__).parent/'reference'
        self.saved, raw = {}, {}
        for name, wanted in REFERENCE_PINS.items():
            item = snapshot(self.directory/name, 8*1024**2)
            require(item['sha256'] == wanted, 'Qualified reference pin differs: ' + name)
            self.saved[name] = {k:v for k,v in item.items() if k != 'raw'}
            raw[name] = item['raw']
        self.prompt_raw = raw['prompt.json']; self.prompt = parse(self.prompt_raw)
        require(type(self.prompt) is list and len(self.prompt) == 8192, 'Reference prompt length differs')
        for token in self.prompt: integer(token, 0, 248319)
        lines = raw['stdout.jsonl'].split(b'\n')
        require(len(lines) == 3 and not lines[-1], 'Reference framing differs')
        evidence = parse(lines[1])['evidence']; execution = evidence['execution']
        audit, receipt, parent = (parse(raw[n]) for n in ('cpu-audit.json', 'cpu-receipt.json', 'parent.json'))
        require(parent['passed'] is True and receipt['exitCode'] == 0 and receipt['stderrBytes'] == 0
                and audit['status'] == 'passed' and receipt['auditSHA256'] == REFERENCE_PINS['cpu-audit.json']
                and audit['stdoutSHA256'] == REFERENCE_PINS['stdout.jsonl'], 'Reference qualification differs')
        exact(execution['request']['promptTokenIDs'], self.prompt, 'Reference prompt differs')
        exact(evidence['arithmeticEnvironment'], environment_receipt(), 'Reference arithmetic differs')
        require(evidence['profile'] == PROFILE and evidence['profileFingerprint'] == PROFILE_SHA256,
                'Reference profile differs')
        row = logical_bytes(execution['finalLogits'], 248320, 'bfloat16')
        values = execution['finalLogits']['values']; maximum = max(values)
        token = values.index(maximum)
        require(token == audit['argmaxTokenID'] == execution['selection']['tokenID']
                and maximum == audit['maximumLogit']
                and sum(v == maximum for v in values) == audit['maximumTieCount'], 'Reference argmax differs')
        self.logits = {k:v for k,v in execution['finalLogits'].items() if k != 'values'}
        exact(self.logits, audit['finalLogits'], 'Qualified reference row metadata differs')
        state = execution['finalState']
        require(state['committedTokens'] == 8192 and state['logicalByteCount'] == 319946784
                and len(state['entries']) == 72, 'Reference state coverage differs')
        offsets = [e for e in state['entries'] if e['component'] == 'kv.position_offsets']
        require(len(offsets) == 8 and all(e['sha256'] == digest(struct.pack('<i',8192)) for e in offsets),
                'Reference position offsets differ')
        material = ['cbv2-owned-state-v1','tokens=8192'] + [
            f"{e['globalLayerIndex']}|{e['component']}|{e['shape']}|{e['dtype']}|{e['byteCount']}|{e['sha256']}"
            for e in state['entries']]
        require(digest('\n'.join(material).encode()) == state['fingerprint'] == audit['finalStateSHA256'],
                'Reference state fingerprint differs')
        self.evidence, self.execution, self.token = evidence, execution, token
        self.summary = dict(referenceStdoutSHA256=REFERENCE_PINS['stdout.jsonl'],
            referenceCPUReceiptSHA256=REFERENCE_PINS['cpu-receipt.json'],
            referenceNativeSHA256=parent['expected_native_sha256'], promptSHA256=REFERENCE_PINS['prompt.json'],
            reconstructedReferenceBF16Bytes=len(row), referenceSelectedToken=token,
            originalOracleFrozenBeforeCandidateAccess=True, originalOracleFrozenBeforeNativeExecution=False)

    def recheck(self):
        for name, expected in self.saved.items():
            item = snapshot(self.directory/name, 8*1024**2, keep=False)
            require({k:v for k,v in item.items() if k != 'raw'} == expected, 'Reference changed: ' + name)

    def validate(self, execution, epoch):
        identifier, simple, history = request_identity(epoch, self.prompt)
        require(uuid.UUID(identifier) != uuid.UUID(self.execution['request']['request']['requestID']),
                'Resident request reuses the reference UUID')
        validate_request(execution.get('request'), epoch, {'prompt':self.prompt})
        selection = dict(requestFingerprint=simple, recordedRequestFingerprint=history,
            frame=self.execution['commits'][-1]['frame'], committedTokens=8192, vocabularySize=248320,
            outputOrdinal=0, policy='mlx_argmax_all_axes_with_finite_guard_v1', tokenID=self.token,
            logitsShape=[1,248320], logitsDType='bfloat16', selectionDType='uint32', allLogitsFinite=True)
        expected = dict(kind='qwen_long_prefill_solo_request', schemaVersion=1,
            correctnessOnly=True, throughputMeasurementValid=False, interprocessTransportUsed=False,
            physicalTransferQualified=False, independentNumericalComparisonPerformed=False,
            fullVocabularyValuesExported=False, nativeLogitBytesCompared=False,
            source=self.execution['source'], sourceLoad=self.execution['sourceLoad'],
            request=execution['request'], commits=self.execution['commits'], selection=selection,
            finalState=self.execution['finalState'], finalLogits=self.logits, timing=execution.get('timing'),
            completedFrames=16, committedTokens=8192, perFrameStateCaptures=0, perFrameLogitCaptures=0,
            finalStateCaptures=1, finalLogitCaptures=1, nativeTokenSelections=1, allRequestStateRetired=True)
        exact(execution, expected, 'Resident solo request, source, state/logit digest or selection differs')
        interval = timing(execution['timing'])
        return dict(**interval, selectedTokenID=self.token, recordedRequestFingerprint=history,
            referenceLogitMetadataAndDigestMatched=True, referenceStateMetadataAndDigestsMatched=True,
            candidateFullVocabularyValuesExported=False, candidateNativeBytesIndependentlyReconstructed=False,
            opaqueNumericalStateComponents=64, independentlyKnownOffsetComponents=8,
            performanceQualified=False, physicalTwoMachineExecution=False)
