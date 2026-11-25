"""Pure loader checks adapted from validate-qwen-layer-stage.py, without imports
of its native launcher/support modules. Its source pin is saved in the manifest.
"""
from profiled_tiny_expected import canonical, configuration, exact, fingerprint, integer, require, sha

PROOF_FLAGS = ['allActiveShapesDTypesAndBytesMatchOrdinary', 'activeNamesAndBytesConserveCanonicalSource',
    'independentCompactZeroOffsetActiveBuffersBeforeForward', 'previouslyLoadedParameterHandlesUnchangedOnRejection',
    'inactiveParametersCheckedSeparately', 'sourceFilesCorruptedAndDeleted', 'loaderProofPrecedesAnyTransformerForward']


def validate_loader(loader, dtype):
    exact(loader.get('kind'), 'qwen_layer_stage_loader_check', 'Wrong loader record')
    exact(loader.get('syntheticDType'), dtype, 'Loader dtype differs')
    exact(loader.get('wrapped'), dtype == 'bfloat16', 'Loader wrapper differs')
    exact(loader.get('fp16LayerMetadata'), False, 'Unexpected F16 metadata fixture')
    for key, value in [('fp16MetadataTensorCount', 0), ('tensorChecks', 237), ('tensorChecksAfterSourceDeletion', 237)]:
        exact(loader.get(key), value, 'Wrong loader count: ' + key)
    for key in PROOF_FLAGS: exact(loader.get(key), True, 'Missing loader proof: ' + key)
    exact(loader.get('modelForwardCompared'), False, 'Loader proof includes transformer execution')
    exact(loader.get('badAggregateRejectedStages'), [0, 1], 'Bad aggregate was not rejected by both stages')
    exact(loader.get('corruptedSourceRejectedStages'), [0, 1], 'Corrupt source was not rejected by both stages')
    source_bytes = integer(loader.get('sourceTensorBytes'), 1, 8 * 1024**2, 'Wrong tiny source byte bound')
    receipts = loader.get('receipts')
    require(type(receipts) is list and len(receipts) == 2, 'Expected two stage load receipts')
    require(type(loader.get('activeTensorBytes')) is list and len(loader['activeTensorBytes']) == 2
            and type(loader.get('inertTensorBytes')) is list and len(loader['inertTensorBytes']) == 2, 'Wrong stage byte list')
    all_names, totals = set(), []
    source_hash = sha(canonical(configuration(dtype)))
    for index, receipt in enumerate(receipts):
        exact(receipt.get('schemaVersion'), 1, 'Receipt schema differs')
        exact(receipt.get('stageIndex'), index, 'Receipt rank differs')
        exact(receipt.get('sourceConfigurationSHA256'), source_hash, 'Source config/profile/context pin differs')
        exact(receipt.get('embeddingActivationDType'), dtype, 'Receipt activation dtype differs')
        exact(receipt.get('bf16ConversionEnabled'), True, 'Required loader conversion policy differs')
        exact(receipt.get('sourceModelTensorBytes'), source_bytes, 'Source byte commitment differs')
        for key in ['verifiedAggregateSHA256', 'sourceConfigurationSHA256', 'constructionConfigurationSHA256',
            'planSHA256', 'stagePlanSHA256', 'sourceTensorManifestSHA256', 'sourceParameterLayoutSHA256',
            'parameterLayoutSHA256', 'activeParameterLayoutSHA256', 'activeMappingSHA256', 'storageCommitmentSHA256']:
            fingerprint(receipt.get(key), 'Malformed receipt hash: ' + key)
        active = receipt.get('activeTensors')
        require(type(active) is list and len(active) == [118, 119][index], 'Wrong active tensor inventory')
        local_names, total = set(), 0
        for entry in active:
            source, local = entry.get('sourceName'), entry.get('localName')
            require(type(source) is str and source and source not in all_names
                    and type(local) is str and local and local not in local_names, 'Duplicate or missing active tensor ownership')
            all_names.add(source); local_names.add(local)
            shape = entry.get('shape')
            require(type(shape) is list and 1 <= len(shape) <= 4, 'Bad active tensor shape')
            elements = 1
            for dimension in shape: elements *= integer(dimension, 1, 8192, 'Invalid tensor dimension')
            require(entry.get('sourceDType') == entry.get('loadedDType')
                    and entry['loadedDType'] in ('uint32', dtype), 'Native fixture tensor dtype differs')
            byte_count = elements * (4 if entry['loadedDType'] in ('uint32', 'float32') else 2)
            exact(entry.get('byteCount'), byte_count, 'Active tensor byte geometry differs')
            total += byte_count
        exact(receipt.get('loadedTensorBytes'), total, 'Receipt active bytes differ')
        exact(loader['activeTensorBytes'][index], total, 'Loader active bytes differ')
        integer(loader['inertTensorBytes'][index], 1, 65536, 'Invalid inert parameter byte bound')
        exact(receipt.get('inertTensorBytes'), loader['inertTensorBytes'][index], 'Inert byte commitment differs')
        commitment = receipt.get('storageCommitment')
        require(type(commitment) is dict, 'Missing common storage commitment')
        exact(sha(canonical(commitment)), receipt['storageCommitmentSHA256'], 'Storage commitment digest differs')
        for key in ('verifiedAggregateSHA256', 'sourceConfigurationSHA256', 'planSHA256', 'sourceTensorManifestSHA256'):
            exact(commitment.get(key), receipt[key], 'Common receipt storage identity differs')
        exact(commitment.get('sourceModelTensorBytes'), source_bytes, 'Common source bytes differ')
        totals.append(total)
    require(len(all_names) == 237 and sum(totals) == source_bytes, 'Canonical active tensor bytes/names are not conserved')
    for key in ['verifiedAggregateSHA256', 'planSHA256', 'sourceParameterLayoutSHA256', 'sourceTensorManifestSHA256', 'storageCommitmentSHA256']:
        exact(receipts[0][key], receipts[1][key], 'Two stages disagree on source identity: ' + key)
    exact(receipts[0]['storageCommitment'], receipts[1]['storageCommitment'], 'Stage storage commitments differ')
    return dict(artifact=receipts[0]['verifiedAggregateSHA256'], configuration=source_hash,
                plan=receipts[0]['planSHA256'], sourceTensorBytes=source_bytes)
