"""Strict per-rank report and actual two-rank ciphertext/timing join."""
import hashlib
import statistics
from binding_common import require
from gemma_inputs import MODES,scope,validate_job,validate_native

def integer(x):return type(x) is int and 0<=x<115_000_000_000
def digest(x):return type(x) is str and len(x)==64 and all(c in '0123456789abcdef' for c in x)

def validate_result(v,job):
    validate_job(job);n=job['nativeJob'];size=n['payloadBytes']
    expected={'schema','job','scopeSHA256','codec','copies','transfers','sealedRecords','openedRecords','sealedBytes','openedBytes',
        'baselineNativeBytes','finalNativeBytes','maximumObservedNativeBytes','baselinePhysical','finalPhysical',
        'minimumObservedFreeBytes','resourceObservations','collectiveReleased','nativeCacheBytesAfterRelease','labOnly',
        'productMembershipEstablished','productRuntimeApproved','modelExecuted','externalHTTPTTFTMeasured',
        'processOrLeaseRetirementEstablished','keyMaterialExported','recordCodecChanged','nativeCopyCodeChanged',
        'operationTimingsIncludeExistingChecks','rank0RoundtripIsSameClock','rank1ReceiveIncludesPeerWait'}
    require(type(v) is dict and set(v)==expected and v['schema']=='lab_authenticated_rdma_report_v1' and v['job']==n and v['scopeSHA256']==scope(n),'Lab report scope')
    validate_native(v['job'])
    for key in ['collectiveReleased','labOnly','operationTimingsIncludeExistingChecks','rank0RoundtripIsSameClock','rank1ReceiveIncludesPeerWait']:require(v[key] is True,'Lab positive scope flag')
    for key in ['productMembershipEstablished','productRuntimeApproved','modelExecuted','externalHTTPTTFTMeasured','processOrLeaseRetirementEstablished','keyMaterialExported','recordCodecChanged','nativeCopyCodeChanged']:require(v[key] is False,'Lab cannot claim product authority')
    counts=['sealedRecords','openedRecords','sealedBytes','openedBytes','baselineNativeBytes','finalNativeBytes',
            'maximumObservedNativeBytes','minimumObservedFreeBytes','resourceObservations','nativeCacheBytesAfterRelease']
    require(all(integer(v[k]) for k in counts),'Lab integer accounting fields')
    require(v['sealedRecords']==v['openedRecords']==47 and v['sealedBytes']==v['openedBytes']==46*size+32,'Lab exact encrypted counters')
    require(v['nativeCacheBytesAfterRelease']==0 and v['baselineNativeBytes']==v['finalNativeBytes'] and
        v['maximumObservedNativeBytes']<=v['baselineNativeBytes']+256*1024**2 and
        v['minimumObservedFreeBytes']>=6*1024**3+512*1024**2 and v['resourceObservations']>0,'Lab actual resource/retirement fields')
    for key in ['baselinePhysical','finalPhysical']:
        p=v[key];require(type(p) is dict and set(p)=={'currentBytes','lifetimeMaximumBytes'} and
            all(integer(p[k]) for k in p) and 0<p['currentBytes']<=p['lifetimeMaximumBytes'],'Lab physical metrics')
    require(v['finalPhysical']['lifetimeMaximumBytes']<=v['baselinePhysical']['currentBytes']+512*1024**2,'Lab footprint peak ceiling')
    for name,times,extra in [('codec',('sealNanoseconds','openNanoseconds'),{'plaintextBytes':size,'recordBytes':size+40}),
                             ('copies',('exportNanoseconds','importNanoseconds'),{'bytes':size})]:
        rows=v[name];require(type(rows) is list and len(rows)==23,'Lab component sample coverage')
        for i,row in enumerate(rows):
            require(type(row) is dict and set(row)=={'ordinal','warmup','verified',*times,*extra} and type(row['ordinal']) is int and row['ordinal']==i and row['warmup'] is (i<3) and row['verified'] is True,'Lab component sample')
            require(all(integer(row[k]) for k in times) and all(type(row[k]) is int and row[k]==x for k,x in extra.items()),'Lab component values')
    require(type(v['transfers']) is list and len(v['transfers'])==92,'Lab transfer sample coverage')
    for index,row in enumerate(v['transfers']):
        mode=MODES[index//23];i=index%23
        require(type(row) is dict and set(row)=={'mode','ordinal','warmup','firstOperationNanoseconds','secondOperationNanoseconds','roundtripNanoseconds','sent','received','plaintextSHA256','verified'} and row['mode']==mode and type(row['ordinal']) is int and row['ordinal']==i and row['warmup'] is (i<3) and row['verified'] is True,'Lab transfer identity')
        require(all(integer(row[k]) for k in ('firstOperationNanoseconds','secondOperationNanoseconds','roundtripNanoseconds')) and
            row['roundtripNanoseconds']==row['firstOperationNanoseconds']+row['secondOperationNanoseconds'],'Lab exact timer arithmetic')
        frame=size if mode=='raw_payload' else size+40
        plain=b'Y'*size+(b'7'*40 if mode=='raw_record_size' else b'')
        require(row['plaintextSHA256']==hashlib.sha256(plain).hexdigest(),'Lab exact fixture bytes')
        for key in ('sent','received'):
            f=row[key];require(type(f) is dict and set(f)=={'bytes','sha256','nanoseconds'} and type(f['bytes']) is int and f['bytes']==frame and digest(f['sha256']) and integer(f['nanoseconds']),'Lab frame observation')
        require(row['sent']['nanoseconds']+row['received']['nanoseconds']<=row['roundtripNanoseconds'],'Lab byte IO within measured operations')

def join_results(reports,jobs):
    require(len(reports)==len(jobs)==2,'Lab rank pair')
    for v,j in zip(reports,jobs):validate_result(v,j)
    a,b=[dict(j['nativeJob']) for j in jobs];require(a.pop('rank')==0 and b.pop('rank')==1 and a==b,'Lab ranks share exact public transcript')
    for left,right in zip(reports[0]['transfers'],reports[1]['transfers']):
        require(left['mode']==right['mode'] and left['ordinal']==right['ordinal'] and
                left['sent']['sha256']==right['received']['sha256'] and left['received']['sha256']==right['sent']['sha256'],'Lab exact cross-rank ciphertext/raw-frame join')
    result={'schema':'lab_authenticated_rdma_comparison_v1','labOnly':True,'productMembershipEstablished':False,
            'scopeSHA256':reports[0]['scopeSHA256'],'rank0RoundtripMedianNanoseconds':{},'components':[]}
    for mode in MODES:
        values=[r['roundtripNanoseconds'] for r in reports[0]['transfers'] if r['mode']==mode and not r['warmup']]
        require(len(values)==20,'Lab measured sample count');result['rank0RoundtripMedianNanoseconds'][mode]=statistics.median(values)
    for rank,v in enumerate(reports):
        row={'rank':rank}
        for group,keys in [('codec',('sealNanoseconds','openNanoseconds')),('copies',('exportNanoseconds','importNanoseconds'))]:
            for key in keys:row[key]=statistics.median([x[key] for x in v[group] if not x['warmup']])
        result['components'].append(row)
    result['componentSumsAreNotEndToEndLatency']=True
    return result
