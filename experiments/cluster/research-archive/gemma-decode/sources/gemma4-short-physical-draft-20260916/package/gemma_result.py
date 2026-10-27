"""Native completion shape only; numerical and physical checks are separate."""
from binding_common import parse, require, same


def result(raw, mode, expected):
    # PipeWorkers retains the LF on disk and delivers the decoded line without it.
    require(0 < len(raw) <= 1_048_576 and b'\n' not in raw,'Native report line bound')
    value=parse(raw);same(value['schema'],'gemma4_short_result_v1','native schema')
    same(value['mode'],mode,'native role');same(value['expected'],expected,'prospective expected identity')
    for name in ('modelReleased','nativeExecuted'):same(value[name],True,name)
    for name in ('physicalProcessOrLeaseRetirementEstablished','runtimeServingEnabled','numericalComparisonPerformed',
                 'throughputMeasurementValid','encryptedRDMAEstablished'):same(value[name],False,name)
    for name in ('collectiveCreated','collectiveReleased'):same(value[name],mode!='full',name)
    same(value['nativeCacheBytesAfterRelease'],0,'native cache retirement')
    ex=value['execution'];same(ex['committedTokens'],33,'input frontier');same(ex['finishReason'],'length','finish reason')
    same(ex['requestStateRetired'],True,'state retirement')
    require(type(ex['selectedTokenIDs']) is list and len(ex['selectedTokenIDs'])==2,'Two selected IDs')
    # The unchanged companion comparator later checks all rows/bytes/identities.
    return dict(scopeSHA256=expected['scopeSHA256'],selectedTokenIDs=ex['selectedTokenIDs'],
                modelReleased=True,requestStateRetired=True,numericalComparisonPerformed=False)
