"""Two fully retired diagnostic cases; no new numerical, wire/GPU or cross-clock claim."""
from pathlib import Path
import json
from physical_evidence import terminal,read,parse,pin,require
from validate_run import join_reports
BASE=Path(__file__).resolve().parent

def case(name):
    folder=BASE/name;external=terminal(folder);result=parse(read(folder/'phase-comparison.json',4*1024**2))
    require(result['accepted'] is True and result['policy']==external['binding']['policy'],'Case comparison incomplete')
    require(result['physicalExecution']==external['physicalExecution'] and result['controllerResult']==external['controllerResult'],'Case physical evidence changed')
    raw=[];expected=[]
    for rank,row in enumerate(result['sidecars']):
        f=folder/'collection-1'/f'rank{rank}.json';require(pin(f)==row,'Compared sidecar changed')
        raw.append(parse(read(f)));expected.append(parse(read(folder/f'expected-rank{rank}.json')))
    actual=join_reports(raw,expected,external)
    require(actual==result['ranks'],'Local scalar replay differs')
    reference=external['binding']['reference']
    for key in ['review','stdout','terminal','job']:require(pin(Path(reference[key]['path']))==reference[key],'Prior C256 reference changed')
    return dict(result=result,raw=raw,external=external)

def main():
    serial,lookahead=case('serial'),case('lookahead')
    require(serial['external']['binding']['reference']==lookahead['external']['binding']['reference'],'Cases do not share the same fresh C256 reference')
    require(serial['external']['binding']['nativeBundle']==lookahead['external']['binding']['nativeBundle'],'Cases changed native build')
    require(serial['external']['binding']['membershipEpoch']!=lookahead['external']['binding']['membershipEpoch'],'Cases must use distinct fresh memberships')
    for rank in [0,1]:
        a,b=serial['raw'][rank],lookahead['raw'][rank]
        for k in ['requestID','requestFingerprint','profileFingerprint','sourceConfigurationSHA256','artifactAggregateSHA256',
            'storageCommitmentSHA256','planFingerprint','stageFingerprint','buildSHA256','numericalPolicySHA256','rank','promptCount','chunkSize','outputCount']:
            require(a['identity'][k]==b['identity'][k],'Cases changed matched identity: '+k)
        require(a['execution']['selectedTokenIDs']==b['execution']['selectedTokenIDs'],'Cases changed target sequence')
    result=dict(schema='resident_phase_memory_matched_summary_v1',accepted=True,
        reference=serial['external']['binding']['reference'],nativeBundle=serial['external']['binding']['nativeBundle'],
        cases={name:dict(comparison=pin(BASE/name/'phase-comparison.json'),ranks=value['result']['ranks'],resources=value['result']['resources'])
            for name,value in [('serial',serial),('lookahead',lookahead)]},
        diagnosticOnly=True,includesObserverOverhead=True,independentFullRowStateComparisonPerformed=False,
        crossProcessClockAlignmentAsserted=False,continuousPhysicalPeakProved=False,gpuKernelDurationQualified=False,
        transportWaitIsWireCost=False,productThroughputQualified=False,placementPermissionGranted=False)
    with (BASE/'matched-summary.json').open('xb') as f:f.write((json.dumps(result,sort_keys=True,indent=2)+'\n').encode())
    print(json.dumps(dict(accepted=True,output=pin(BASE/'matched-summary.json'))))
if __name__=='__main__':main()
