"""Reuse the pinned full-width loader oracle; close the new receipt schemas."""
import json

RECEIPT_KEYS = set('schemaVersion stageIndex verifiedAggregateSHA256 sourceConfigurationSHA256 constructionConfigurationSHA256 planSHA256 stagePlanSHA256 sourceTensorManifestSHA256 sourceParameterLayoutSHA256 parameterLayoutSHA256 activeParameterLayoutSHA256 activeMappingSHA256 embeddingActivationDType bf16ConversionEnabled sourceModelTensorBytes loadedTensorBytes largestHostTensorBytes activeTensors inertModules inertTensorBytes storageCommitment storageCommitmentSHA256'.split())
STORAGE_KEYS = set('schemaVersion verifiedAggregateSHA256 sourceConfigurationSHA256 planSHA256 sourceTensorManifestSHA256 sourceModelTensorBytes largestSourceTensorBytes sourceTensorCount canonicalTensorCount bf16ConversionEnabled stages'.split())
SUMMARY_KEYS = set('stageIndex constructionConfigurationSHA256 stagePlanSHA256 activeMappingSHA256 activeParameterLayoutSHA256 parameterLayoutSHA256 loadedTensorBytes activeTensorCount inertTensorBytes inertTensorCount'.split())


def pinned_metadata(a, name):
    raw = a.read_bounded(a.ROOT / name, 2 * 1024**2)
    a.require(a.sha(raw) == a.PINNED[name], 'Pinned loader/plan metadata changed')
    return json.loads(raw)


def check_storage(a, loads, source):
    a.require(type(loads) is list and len(loads) == 2, 'Two actual stage loads required')
    expected = a.context()['expected']
    plan = a.context()['plan']
    for rank, load in enumerate(loads):
        a.require(type(load) is dict and set(load) == RECEIPT_KEYS, 'Stage-load fields differ')
        for key in ('schemaVersion', 'stageIndex', 'sourceModelTensorBytes', 'loadedTensorBytes', 'largestHostTensorBytes', 'inertTensorBytes'):
            a.integer(load[key])
        a.exact(load['bf16ConversionEnabled'], True, 'load conversion')
        a.exact(load['constructionConfigurationSHA256'], plan['stages'][rank]['configurationSHA256'], 'stage configuration')
        a.exact(load['stagePlanSHA256'], plan['stages'][rank]['fingerprint'], 'stage plan')
        storage = load['storageCommitment']
        a.require(type(storage) is dict and set(storage) == STORAGE_KEYS, 'Storage fields differ')
        for key in ('schemaVersion', 'sourceModelTensorBytes', 'largestSourceTensorBytes', 'sourceTensorCount', 'canonicalTensorCount'):
            a.integer(storage[key])
        a.exact(storage['bf16ConversionEnabled'], True, 'storage conversion')
        a.require(type(storage['stages']) is list and len(storage['stages']) == 2, 'Two storage summaries required')
        for summary in storage['stages']:
            a.require(type(summary) is dict and set(summary) == SUMMARY_KEYS, 'Storage-summary fields differ')
            for key in ('stageIndex', 'loadedTensorBytes', 'activeTensorCount', 'inertTensorBytes', 'inertTensorCount'):
                a.integer(summary[key])
    result = a.context()['base'].stage_inventory(source, loads, expected)
    return result, plan


def identity(a, rank, load, summary):
    return dict(stageIndex=rank, requestFingerprint=summary['requestFingerprint'],
        artifactAggregateSHA256=load['verifiedAggregateSHA256'], storageCommitmentSHA256=load['storageCommitmentSHA256'],
        bf16ConversionEnabled=True, sourceConfigurationSHA256=load['sourceConfigurationSHA256'],
        constructionConfigurationSHA256=load['constructionConfigurationSHA256'], planFingerprint=load['planSHA256'],
        stageFingerprint=load['stagePlanSHA256'], activationDType='bfloat16')


def compute_source(a, rank, load, summary):
    return dict(stageIndex=rank, artifactAggregateSHA256=load['verifiedAggregateSHA256'],
        sourceConfigurationSHA256=load['sourceConfigurationSHA256'], sourceParameterLayoutSHA256=load['sourceParameterLayoutSHA256'],
        sourceModelTensorBytes=load['sourceModelTensorBytes'], loadedTensorBytes=load['loadedTensorBytes'],
        planSHA256=load['planSHA256'], storageCommitmentSHA256=load['storageCommitmentSHA256'],
        sourceLoadReceiptSHA256=a.sha(a.canonical(load)), arithmeticEnvironmentSHA256=summary['arithmeticEnvironmentSHA256'],
        promptFileSHA256=summary['promptFileSHA256'], promptTokenIDsSHA256=summary['promptTokenIDsSHA256'],
        bf16ConversionEnabled=True, embeddingActivationDType='bfloat16')
