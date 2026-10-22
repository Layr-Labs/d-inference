"""Explicit dense-policy addends over the byte-exact qualified local validator."""
import hashlib
from binding_common import require
from local_mtp_base_contract import validate_result as validate_original

POLICY='gemma4_verification_packed_m1_dense_serial_head_v1'
OPERATIONS=('execute-local-mtp-dense','qualify-mtp-conditioning-dense')

def text_hash(parts):
    return hashlib.sha256('\n'.join(parts).encode()).hexdigest()

def validate_dense_metadata(value,config,config_sha,operation):
    require(operation in OPERATIONS,'Explicit dense operation required')
    summary=value['denseProjection']
    expected=dict(policy=POLICY,expectedDenseModules=235,expectedTiedHeads=1,
        serialHeadLogicalBytes=4194304,gatheredOverrideEnabled=False,
        singleRowOverrideEnabled=False,wholeModelNumericsQualified=False)
    require(type(summary) is dict and set(summary)==set(expected)
        and all(type(summary[k]) is type(want) and summary[k]==want for k,want in expected.items()),
        'Actual dense module/head/policy coverage differs')
    aux=value['auxiliaryResources'];rows=aux['serialTargetHeadTerms']
    require(type(rows) is list and len(rows)==4,'Four individual head allocations required')
    for i,row in enumerate(rows):
        require(type(row) is dict and set(row)=={'name','logicalBytes','allocationBound'}
            and row['name']=='serialTargetHead:row'+str(i)
            and type(row['logicalBytes']) is int and row['logicalBytes']==1048576
            and type(row['allocationBound']) is int and 1048576<=row['allocationBound']<2**63,
            'Dense head row name/shape/allocation rounding differs')
    require(type(aux['liveNativeReserveBytes']) is int
        and sum(x['allocationBound'] for x in rows)<aux['liveNativeReserveBytes']<2**63,
        'Head rows must be added to retained assistant/target reserve')
    requests=[s['generation']['requestSHA256'] for s in value['samples']]
    scope=text_hash(['gemma4-local-mtp-cohort-v1',config_sha,config['benchmarkJobSHA256'],value['ordinaryInputScopeSHA256'],
        value['assistantLoad']['artifactSHA256'],value['assistantLoad']['parameterLayoutSHA256'],
        'maximumDraftTokens='+str(config['maximumDraftTokens']),'captureEvidence='+str(config['captureEvidence']).lower(),
        'qualifyConditioning='+str(operation=='qualify-mtp-conditioning-dense').lower(),'mtp=true','remote=false']
        +requests+['targetProjection='+POLICY])
    require(value['scopeSHA256']==scope,'Dense policy not bound to actual local input scope')
    for i,sample in enumerate(value['samples']):
        require(sample['scopeSHA256']==text_hash([scope,'iteration='+str(i),requests[i]]),
            'Dense per-request policy scope differs')

def validate_result(value,job,config,config_sha,operation):
    validate_dense_metadata(value,config,config_sha,operation)
    # Original count/acceptance/resource/evidence and same-clock checks remain
    # byte-exact. Only the explicitly selected operation maps to its old name.
    return validate_original(value,job,config,config_sha,operation.removesuffix('-dense'))
