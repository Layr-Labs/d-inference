"""Prospective CPU audit: unchanged eleven-record prefix + closed tiny12 suffix."""
import argparse
import json
import math
from pathlib import Path
import sys
sys.dont_write_bytecode = True

from legacy_prefix import check_legacy_prefix
from tiny12_expected import canonical, equal, expected, require, sha
from tiny12_schema import closed_suffix, strict_scalar_types
from tiny12_recorded import check_recorded_pair

MAXIMUM_BYTES = 8 * 1024 * 1024


def parse(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    def floating(text):
        value = float(text)
        require(math.isfinite(value), 'Nonfinite JSON number')
        return value
    return json.loads(raw, object_pairs_hook=unique, parse_float=floating,
        parse_int=lambda value: -0.0 if value == '-0' else int(value),
        parse_constant=lambda _: require(False, 'Nonfinite JSON constant'))


def validate_suffix(checkpoint, wrapper):
    strict_scalar_types(checkpoint); strict_scalar_types(wrapper)
    report = closed_suffix(checkpoint, wrapper)
    reference = expected()
    source = checkpoint['baseline']['source']
    for key in ('sourceConfigurationSHA256', 'planSHA256', 'sourceParameterLayoutSHA256', 'sourceModelTensorBytes'):
        equal(source.get(key), reference[key], 'Source-derived tiny12 identity differs: ' + key)
    equal(source.get('embeddingActivationDType'), 'bfloat16', 'Tiny12 native dtype differs')
    for index, receipt in enumerate(report['stageLoads']):
        stage = reference['stages'][index]
        for key in ('constructionConfigurationSHA256', 'stagePlanSHA256', 'activeTensors', 'inertModules',
                    'activeMappingSHA256', 'activeParameterLayoutSHA256', 'parameterLayoutSHA256',
                    'loadedTensorBytes', 'largestHostTensorBytes', 'inertTensorBytes'):
            equal(receipt.get(key), stage[key], 'Source-derived tiny12 stage metadata differs: ' + key)
    result = check_recorded_pair(checkpoint, report)
    result.update(kind='tiny12_unequal_recording_audit', selectedCut=4, layerCounts=[4, 8],
        activeTensorCounts=[118, 234], sourceF16LayerMetadataTensors=186,
        sourceDerivedModelMetadataSHA256=sha(canonical(reference)),
        sourcePayloadIdentityPrecomputed=False, pairedRawStateBytesAvailable=False)
    return result


def validate_records(rows):
    require(type(rows) is list and len(rows) == 13, 'Exactly thirteen native records required')
    prefix = check_legacy_prefix(rows[:11])
    suffix = validate_suffix(rows[11], rows[12])
    old_id = rows[9]['baseline']['request']['request']['requestID'].lower()
    new_id = rows[11]['baseline']['request']['request']['requestID'].lower()
    require(old_id != new_id, 'Tiny8 and tiny12 recording requests reused one UUID')
    return dict(kind='qwen_layer_stage_legacy_and_unequal_cpu_audit', passed=True,
        nativeRecordCount=13, unchangedLegacyRecordCount=11, legacy=prefix, unequal=suffix,
        numericalOnly=True, launcherResourceAndCleanupAuditSeparate=True,
        statePayloadsOpaque=True, nativeOwnershipFlagsSourceBound=True,
        performanceQualified=False, physicalTwoMachineExecution=False)


def validate_file(path):
    with Path(path).open('rb') as handle:
        raw = handle.read(MAXIMUM_BYTES + 1)
    require(0 < len(raw) <= MAXIMUM_BYTES, 'Native stdout exceeds the bounded output size')
    lines = raw.decode('utf-8').splitlines()
    require(len(lines) == 13 and all(line.strip() for line in lines), 'Unexpected stdout line/count')
    result = validate_records([parse(line) for line in lines])
    result.update(nativeStdoutSHA256=sha(raw), nativeStdoutBytes=len(raw))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stdout', type=Path)
    args = parser.parse_args()
    print(json.dumps(validate_file(args.stdout), sort_keys=True, allow_nan=False))


if __name__ == '__main__':
    main()
