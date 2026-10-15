#!/usr/bin/env python3
"""Expected identity from a prior source-qualified constructor, never a generation candidate."""
import argparse
import os
from pathlib import Path
from recorded_math import canonical, digest, parse_json, require, flags
from snapshot import snapshot

BASE = Path(__file__).resolve().parent
PINS = {
    'constructor.stdout.jsonl':'563414858fcec6228884c13b9b1aa8669d1c22097bd10b848a60f820aca51794',
    'constructor-receipt.json':'e1e86cc81db61832e9755d5fd1740f6d829fbf39799e0402b8c015f78ecd9183',
    'constructor-audit.json':'b41bd0c7105f4e1632b1cf449452147d38d851e0f7b8300a313b525a057b5184',
    'recording-metadata.json':'d1828272d22d62bd4573cf0da04aa7797e2b18aa59286bd34916cf77c7b8b9d4',
    'owner-rank0.json':'46e693fc2df0601503c515c5fa8aabd3a74312830d09be55f9fe5288f78ade08',
    'owner-rank1.json':'0e7937a9f441515f8badbc8948fbc473e5105fe401775f459b366a6e016e133a',
}


def load_inputs():
    saved = {}
    for name, expected in PINS.items():
        item = snapshot(BASE/'inputs'/name, 2*1024*1024)
        require(item['sha256'] == expected, 'Pinned input differs: ' + name)
        saved[name] = item
    return {name:parse_json(item['raw'].decode()) for name,item in saved.items()}, saved


def derive(values):
    report = values['constructor.stdout.jsonl']
    parent = values['constructor-receipt.json']
    audit = values['constructor-audit.json']
    metadata = values['recording-metadata.json']
    require(parent['status'] == 'completed' and parent['nativeExitCode'] == 0
            and parent['nativeReaped'] is True and not parent['cleanupErrors'] and not parent['postRunErrors'],
            'Prior constructor completion differs')
    require(audit['passed'] is True and audit['stdoutSHA256'] == PINS['constructor.stdout.jsonl']
            and audit['rawMetadataIdentitiesAndCanonicalInventoryMatched'] is True
            and audit['halfOwnershipIndependentlyReplayed'] is True, 'Prior independent metadata audit differs')
    require(report['kind'] == 'qwen_dense_constructor_report' and report['schemaVersion'] == 1
            and report['scope'] == 'registered_dense_constructor_metadata_only_v1'
            and report['model'] == metadata['modelID'] == 'registered_qwen38_27b', 'Wrong constructor scope')
    flags(report, completed=True, allConstructorModelsReleased=True, verifiedFileOwnerReleased=True,
          cacheClearCompleted=True, sourceTensorPayloadsMaterialized=False, parameterValuesEvaluated=False,
          forwardExecuted=False, requestStateCreated=False, loadedStageReceiptProduced=False,
          numericalParityEstablished=False, physicalTransferQualified=False)
    for report_key, metadata_key in [('configurationSHA256','configurationSHA256'),
            ('manifestSHA256','manifestSHA256'),('verifiedAggregateSHA256','artifactSHA256'),
            ('planSHA256','planSHA256')]:
        require(report[report_key] == metadata[metadata_key], 'Current/prior identity differs: ' + report_key)
    require(metadata['stageCut'] == 32 and report['constructorsInspected'] == 3, 'Wrong cut/constructor count')
    tensors = report['sourceTensors']
    require(len(tensors) == report['sourceTensorCount'] == 1847
            and digest(canonical(tensors)) == report['sourceTensorManifestSHA256'], 'Source descriptor manifest differs')
    by_name = {t['sourceName']:t for t in tensors}
    require(len(by_name) == len(tensors) and len({t['canonicalPartName'] for t in tensors}) == len(tensors),
            'Source inventory is not one-part and disjoint')
    require(sum(t['byteCount'] for t in tensors) == report['sourceTensorBytes'] == 15_132_802_048
            and max(t['byteCount'] for t in tensors) == report['largestSourceTensorBytes'] == 635_699_200,
            'Source byte conservation differs')
    summaries = []
    coverage = []
    require(len(report['stages']) == 2, 'Exactly two compact inventories required')
    for rank, stage in enumerate(report['stages']):
        summary, active = stage['expectedPostLoadSummary'], stage['expectedActiveTensors']
        require(summary['stageIndex'] == rank and summary['stagePlanSHA256'] == metadata['stagePlanSHA256'][rank]
                and summary['constructionConfigurationSHA256'] == metadata['constructionConfigurationSHA256'][rank]
                and summary['activeTensorCount'] == metadata['canonicalCounts'][rank] == len(active)
                and summary['loadedTensorBytes'] == metadata['activeBytes'][rank]
                and digest(canonical(active)) == summary['activeMappingSHA256'], 'Current compact summary differs')
        for entry in active:
            source = by_name[entry['sourceName']]
            require(all(entry[k] == source[k] for k in ['shape','sourceDType','loadedDType','byteCount']),
                    'Active mapping changed its full source tensor')
            coverage.append(entry['sourceName'])
        require(sum(t['byteCount'] for t in active) == summary['loadedTensorBytes'], 'Active byte total differs')
        summaries.append(summary)
    require(len(coverage) == len(tensors) and set(coverage) == set(by_name), 'Compact inventories overlap or omit source')
    # Exact QwenLayerStageStorageCommitment DTO and existing assembly fields.
    commitment = dict(schemaVersion=1, verifiedAggregateSHA256=report['verifiedAggregateSHA256'],
        sourceConfigurationSHA256=report['configurationSHA256'], planSHA256=report['planSHA256'],
        sourceTensorManifestSHA256=report['sourceTensorManifestSHA256'], sourceModelTensorBytes=report['sourceTensorBytes'],
        largestSourceTensorBytes=report['largestSourceTensorBytes'], sourceTensorCount=report['sourceTensorCount'],
        canonicalTensorCount=len(tensors), bf16ConversionEnabled=True, stages=summaries)
    arithmetic = report['arithmeticEnvironment']
    require(arithmetic['contract'] == 'qwen_cbv2_query128_bf16_tf32_default_v1', 'Wrong arithmetic contract')
    for rank in (0, 1):
        owner = values['owner-rank%d.json' % rank]
        environment = owner['workerEnvironment']
        require(owner['stageCut'] == 32 and all(environment.get(k) == v for k,v in arithmetic['requiredValues'].items())
                and all(k not in environment for k in arithmetic['requiredAbsentNames']), 'Owner arithmetic environment differs')
    return dict(schema='qwen27b_expected_generation_identity_v1', source='prior constructor metadata plus identical shared assembly',
        modelID=metadata['modelID'], planSHA256=metadata['planSHA256'], nativeBinarySHA256=metadata['nativeBinarySHA256'],
        constructorStdoutSHA256=PINS['constructor.stdout.jsonl'], storageCommitment=commitment,
        storageCommitmentSHA256=digest(canonical(commitment)), arithmeticEnvironment=arithmetic,
        arithmeticSHA256=digest(canonical(arithmetic)), candidateGenerationDataRead=False,
        actualLoadedInventoryEstablished=False, parameterValuesVerifiedByThisHelper=False,
        currentNativeExecutionBindingVerified=False, providerEligibilityEstablished=False,
        numericalQualification=False, physicalQualification=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    values, saved = load_inputs()
    result = derive(values)
    for name, item in saved.items():
        require(snapshot(BASE/'inputs'/name, 2*1024*1024, keep=False)
                == {k:v for k,v in item.items() if k!='raw'}, 'Input changed during identity preparation')
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(canonical(result)+b'\n')
        stream.flush()
        os.fsync(stream.fileno())
    print('prepared: ' + result['storageCommitmentSHA256'] + ' ' + result['arithmeticSHA256'])


if __name__ == '__main__':
    main()
