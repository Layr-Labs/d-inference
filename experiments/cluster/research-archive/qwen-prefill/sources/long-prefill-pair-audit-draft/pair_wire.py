"""Independent v4 canonical-envelope recipes; no transport or residual bytes."""
import re

FLOW = 'profiled_prefill_measurement_v1'
SELECTION = 'mlx_argmax_all_axes_with_finite_guard_v1'


def fingerprint(a, domain, value):
    return a.sha(domain.encode() + b'\n' + a.canonical(value))


def agreement(a, actual, reference, summary, loads):
    a.require(type(actual) is dict and type(actual.get('epoch')) is str
              and re.fullmatch('[0-9a-f]{32}', actual['epoch']), 'Fresh canonical epoch required')
    spec = reference['execution']['request']['request']
    expected = dict(version=4, flow=FLOW, profile=a.PROFILE, profileFingerprint=summary['profileFingerprint'],
        schedulingPolicy='serial_v1', epoch=actual['epoch'], requestID=spec['requestID'].lower(),
        requestFingerprint=summary['requestFingerprint'], recordedRequestFingerprint=summary['recordedRequestFingerprint'],
        promptCount=8192, chunkSize=512, outputCount=1, batchSize=1, frameCount=16,
        promptTokenIDsSHA256=summary['promptTokenIDsSHA256'], sourceConfigurationSHA256=a.CONFIG_SHA,
        artifactAggregateSHA256=a.ARTIFACT_SHA, storageCommitmentSHA256=loads[0]['storageCommitmentSHA256'],
        planFingerprint=loads[0]['planSHA256'], producerStageFingerprint=loads[0]['stagePlanSHA256'],
        consumerStageFingerprint=loads[1]['stagePlanSHA256'],
        producerConstructionConfigurationSHA256=loads[0]['constructionConfigurationSHA256'],
        consumerConstructionConfigurationSHA256=loads[1]['constructionConfigurationSHA256'],
        bf16ConversionEnabled=True, arithmeticEnvironmentSHA256=summary['arithmeticEnvironmentSHA256'],
        hiddenSize=4096, nativeDType='bfloat16', logitsDType='bfloat16', vocabularySize=248320, selectionPolicy=SELECTION)
    a.exact(actual, expected, 'v4 agreement')
    return fingerprint(a, 'qwen-profiled-prefill-start-agreement-v1', expected)


def commit(identity, history, frame, consumer=False):
    final = frame['finalPromptChunk']
    return dict(identity=identity, recordedRequestFingerprint=history, frame=frame,
        committedTokens=frame['tokenOffset'] + frame['tokenCount'],
        outputKind=('logits' if final else 'evaluation_handle') if consumer else 'hidden',
        outputShape=[1,248320 if final else 1] if consumer else [1,512,4096], outputDType='bfloat16')


def check_frames(a, frames, reference, summary, loads, identities, agreement_fp):
    steps = reference['execution']['request']['steps']
    a.require(type(frames) is list and len(frames) == 16, 'Exactly sixteen paired frames required')
    headers = []
    for actual, step in zip(frames, steps):
        a.require(type(actual) is dict and type(actual.get('boundary')) is dict, 'Missing actual frame/header')
        frame = step['frame']; payload_sha = a.sha_string(actual['boundary'].get('payloadSHA256'))
        expected = dict(version=2, profile=a.PROFILE, profileFingerprint=summary['profileFingerprint'],
            requestFingerprint=summary['requestFingerprint'], recordedRequestFingerprint=summary['recordedRequestFingerprint'],
            sourceConfigurationSHA256=a.CONFIG_SHA, artifactAggregateSHA256=a.ARTIFACT_SHA,
            storageCommitmentSHA256=loads[0]['storageCommitmentSHA256'], planFingerprint=loads[0]['planSHA256'],
            producerStageFingerprint=loads[0]['stagePlanSHA256'], frame=frame,
            tokenIDsSHA256=a.sha(','.join(map(str,step['tokenIDs'])).encode()), payloadSHA256=payload_sha,
            shape=[1,512,4096], dtype='bfloat16', byteCount=4194304)
        envelope = dict(version=4, flow=FLOW, kind='boundary', agreementFingerprint=agreement_fp, boundary=expected)
        raw = a.canonical(envelope)
        a.require(len(raw) <= 16384, 'Derived canonical v4 envelope exceeds wire bound')
        envelope_fp = fingerprint(a, 'qwen-profiled-prefill-boundary-envelope-v1', envelope)
        wanted = dict(producer=commit(identities[0], summary['recordedRequestFingerprint'], frame),
            consumer=commit(identities[1], summary['recordedRequestFingerprint'], frame, True), boundary=expected,
            envelopeFingerprint=envelope_fp, envelopeWireBytesSHA256=a.sha(raw))
        a.exact(actual, wanted, 'paired frame ' + str(frame['sequence']))
        a.require(envelope_fp != a.sha(raw), 'Domain fingerprint confused with raw byte hash')
        headers.append(dict(sequence=frame['sequence'], wireBytesSHA256=a.sha(raw), fingerprint=envelope_fp))
    return headers


def token(identity, summary, final_frame):
    return dict(kind='qwen_layer_stage_prefill_local_token', identity=identity,
        recordedRequestFingerprint=summary['recordedRequestFingerprint'], frame=final_frame,
        committedTokens=8192, vocabularySize=248320, outputOrdinal=0, selectionPolicy=SELECTION,
        tokenID=summary['argmaxTokenID'], logitsShape=[1,248320], logitsDType='bfloat16',
        selectionDType='uint32', allLogitsFinite=True)
