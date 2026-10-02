"""Validate only the ordinary capability target rows; admission remains native."""

def validate_description_targets(value, job):
    assert type(value) is dict and value['schema']=='gemma4_resident_benchmark_capability_v1'
    assert value['job']==job and value['metadataOnly'] is True and value['runtimeExecutionAuthorized'] is False
    output=job['outputCount'];assert type(output) is int and output in (16,128)
    if output==128:assert job['mode']=='full'
    wanted=['full','stage0','stage1'] if output==16 else ['full']
    rows=value['targets'];assert type(rows) is list and len(rows)==len(wanted)
    fields={'target','selectedTensorCount','selectedBytes','namedNativeLogicalBytes','hostEvidenceBytes',
        'extraPrefillNativeBytes','extraPrefillHostBytes','stateLogicalBytes','minimumFreeBeforeLoadLogicalLowerBound'}
    for row,name in zip(rows,wanted):
        assert type(row) is dict and set(row)==fields and row['target']==name
        for key in fields-{'target'}:assert type(row[key]) is int and 0<=row[key]<2**64
        assert row['selectedTensorCount']>0 and row['selectedBytes']>0 and row['namedNativeLogicalBytes']>0
    return wanted
