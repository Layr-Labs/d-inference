"""V3 outer admission only: request/source agreement, completion and retirement."""
from .common import FLOATS,canonical,digest,envelope,exact,flags,integer,require,sha
from . import request

FLOW='bounded_prefill_measurement_v1'
POLICIES=('serial_v1','prompt_lookahead_one_v1')
READY='qwen_layer_stage_prefill_rank_ready'
TERMINAL='qwen_layer_stage_prefill_rank_report'
MAX_STDOUT=64*1024**2
MAX_LINE=60*1024**2
HASH_KEYS=('storageCommitmentSHA256','planFingerprint','producerStageFingerprint','consumerStageFingerprint',
           'producerConstructionConfigurationSHA256','consumerConstructionConfigurationSHA256')


def validate_options(policy,dtype):
    require(policy in POLICIES,'Explicit supported stage prefill policy required')
    require(dtype in FLOATS,'Explicit native logits dtype required')


def agreement(record,epoch,context):
    value=record['agreement'];require(isinstance(value,dict),'Missing v3 agreement')
    baseline=context['baseline_admission'];recorded=context['request'];spec=recorded['request']
    validate_options(context['stage_prefill_policy'],context['stage_logits_dtype'])
    known=dict(version=3,flow=FLOW,schedulingPolicy=context['stage_prefill_policy'],epoch=epoch,
        requestID=spec['requestID'],requestFingerprint=context['request_fingerprint'],
        recordedRequestFingerprint=recorded['fingerprint'],promptCount=65,chunkSize=32,outputCount=1,
        batchSize=1,frameCount=3,vocabularySize=context['vocabulary'],hiddenSize=context['text']['hidden_size'],
        promptTokenIDsSHA256=digest(','.join(map(str,recorded['promptTokenIDs'])).encode()),
        sourceConfigurationSHA256=context['configuration_sha256'],artifactAggregateSHA256=context['artifact'],
        bf16ConversionEnabled=True,nativeDType=baseline['native_dtype'],logitsDType=context['stage_logits_dtype'],
        selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1')
    require(set(value)==set(known)|set(HASH_KEYS),'V3 agreement schema differs')
    for key,expected in known.items():exact(value[key],expected,'V3 agreement differs: '+key)
    for key in HASH_KEYS:sha(value[key])
    exact(value['planFingerprint'],baseline['source']['planSHA256'],'V3 plan differs from pinned baseline')
    require(record['agreementFingerprint']==digest(b'qwen-prefill-start-agreement-v1\n'+canonical(value)),
            'V3 agreement fingerprint differs')


def validate(record,rank,epoch,context):
    kind=record.get('kind');require(kind in(READY,TERMINAL),'Wrong prefill evidence namespace')
    envelope(record,kind,rank,epoch)
    exact(record['flow'],FLOW,'Wrong prefill flow');exact(record['envelopeVersion'],3,'Wrong prefill envelope version')
    agreement(record,epoch,context)
    if kind==READY:
        flags(record,modelsReadyAgreementValidated=True,freshRequestStateCreated=False);return
    flags(record,completed=True,correctnessOnly=True,throughputMeasurementValid=False,modelForwardCompared=False,
          physicalTransferQualified=False,allRequestStateRetired=True,modelReleased=True)
    integer(record['conservativeStateAndBoundaryBytes'],1,512*1024**2)
    request.validate(record['request'],context['request'])
    source=record['sourceLoad'];require(isinstance(source,dict),'Missing verified stage source receipt')
    baseline=context['baseline_admission']['source'];descriptor=record['agreement']
    known=dict(schemaVersion=1,stageIndex=rank,verifiedAggregateSHA256=context['artifact'],
        sourceConfigurationSHA256=context['configuration_sha256'],planSHA256=baseline['planSHA256'],
        sourceParameterLayoutSHA256=baseline['sourceParameterLayoutSHA256'],bf16ConversionEnabled=True,
        sourceModelTensorBytes=baseline['sourceModelTensorBytes'],embeddingActivationDType=descriptor['nativeDType'],
        storageCommitmentSHA256=descriptor['storageCommitmentSHA256'],
        stagePlanSHA256=descriptor['producerStageFingerprint' if rank==0 else 'consumerStageFingerprint'],
        constructionConfigurationSHA256=descriptor['producerConstructionConfigurationSHA256' if rank==0 else 'consumerConstructionConfigurationSHA256'])
    for key,value in known.items():exact(source[key],value,'Loaded source differs: '+key)
    # Native executes and releases before this record. The independent auditor
    # owns execution actions, selected token, final state/logits and timer math.
    require(isinstance(record['execution'],dict) and record['execution'],'Missing opaque native execution evidence')


def transition(first,terminal,context):
    exact(first['agreement'],terminal['agreement'],'Ready/final agreement changed')
    exact(first['agreementFingerprint'],terminal['agreementFingerprint'],'Ready/final fingerprint changed')


def progress(readers,context):
    if all(reader.rows for reader in readers):
        a,b=(reader.rows[0] for reader in readers)
        exact(a['agreement'],b['agreement'],'Peer ready agreement differs')
        exact(a['agreementFingerprint'],b['agreementFingerprint'],'Peer ready fingerprint differs')


def pair(records,context):
    a,b=records
    exact(a['agreement'],b['agreement'],'Peer final agreement differs')
    exact(a['agreementFingerprint'],b['agreementFingerprint'],'Peer final fingerprint differs')
    exact(a['request'],b['request'],'Peer recorded request differs')
    return dict(namespace=TERMINAL,schema_version=1,envelope_version=3,outer_identity_and_completion_validated=True,
        scheduling_policy=context['stage_prefill_policy'],baseline_evidence_sha256=context['baseline_admission']['evidence_sha256'],
        numerical_audit_performed=False,action_wire_timing_audit_performed=False,
        throughput_qualification=False,physical_transfer_qualification=False)
