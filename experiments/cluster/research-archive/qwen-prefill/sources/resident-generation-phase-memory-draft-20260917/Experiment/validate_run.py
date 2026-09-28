"""Accept only a fully retired actual pair; preserve same-process phase intervals."""
from pathlib import Path
import argparse,json
from physical_evidence import terminal,read,parse,require,digest,pin
from validate_phase_memory import validate
BASE=Path(__file__).resolve().parent

def join_reports(reports,expected,external):
    local=[validate(report,wanted) for report,wanted in zip(reports,expected)]
    require(len(local)==2 and [x['rank'] for x in local]==[0,1],'Two exact ranks required')
    require(reports[0]['execution']['tokenChainSHA256']==reports[1]['execution']['tokenChainSHA256'],'Token chains disagree')
    cap=external['capacities'];actual=external['controller']['phaseReservationObservation']
    for rank,report in enumerate(reports):
        budget=dict(cap['hostBudget'],totalReservedBytes=cap['ranks'][rank]['requestReservationBytes'])
        require(report['budget']==budget,'Native named phase budget differs from prospective host allocation')
        require(all(x['pageSizeBytes']==cap['pageSize'] for x in report['memory']['samples']),'Sample/allocator page geometry differs')
        require(cap['ranks'][rank]['readyCapacityBytes']==actual['rankReadinessCapacityBytes'][rank],'Maximum-profile Ready differs from its separate prospective ceiling')
        ev=report['events'];first=next(e for e in ev if e['phase']=='firstTokenAgreed')
        local[rank].update(requestToFirstTokenAgreementNanoseconds=first['localUptimeNanoseconds']-ev[0]['localUptimeNanoseconds'],
            requestThroughRetirementNanoseconds=ev[-1]['localUptimeNanoseconds']-ev[0]['localUptimeNanoseconds'])
    require(sum(r['budget']['totalReservedBytes'] for r in reports)==actual['admittedReservedBytes'],'Sidecar sum differs from actual admitted ACK sum')
    return local

def main():
    ap=argparse.ArgumentParser(allow_abbrev=False);ap.add_argument('--case',choices=['serial','lookahead'],required=True);a=ap.parse_args();case=BASE/a.case
    external=terminal(case);out=case/'collection-1';receipt=parse(read(out/'collection.json'))
    require(receipt['schema']=='resident_phase_collection_v1' and receipt['status']=='collected' and receipt['case']==a.case,'Collection incomplete')
    require(receipt['physicalExecution']==external['physicalExecution'] and receipt['controllerResult']==external['controllerResult'],'Collection parent changed')
    require(len(receipt['ranks'])==2 and receipt['readerSHA256']==digest(read(case/'read_sidecar_remote.py')),'Reader/rank count differs')
    reports=[];expected=[];inputs=[]
    for rank,row in enumerate(receipt['ranks']):
        require(row['rank']==rank and row['status']=='collected' and row['sshExitCode']==0,'Rank collection failed')
        p=out/f'rank{rank}.json';require(pin(p)==row['sidecar'],'Collected sidecar changed')
        require(pin(out/f'rank{rank}.transport.stdout')==row['transport'],'Raw collection transport changed')
        transport=parse(read(out/f'rank{rank}.transport.stdout',2*1024*1024));observed={k:v for k,v in transport.items() if k!='data'}
        require(observed==row['observed'] and observed['active']==[] and observed['journalBytes']==0 and observed['journalSHA256']==digest(b''),'Collection postflight differs')
        import base64
        require(base64.b64decode(transport['data'],validate=True)==read(p,1024*1024),'Collected raw bytes differ')
        before=external['preflightJournals'][rank];require(observed['journalIdentity'][:2]==[before['device'],before['inode']],'Journal inode changed')
        require(read(out/f'rank{rank}.transport.stderr')==b'','Collection stderr')
        reports.append(parse(read(p,1024*1024)));expected.append(parse(read(case/f'expected-rank{rank}.json',16384)));inputs.append(pin(p))
    local=join_reports(reports,expected,external)
    result=dict(schema='resident_phase_physical_comparison_v1',accepted=True,policy=external['binding']['policy'],
        requestID=external['binding']['requestID'],membershipEpoch=external['binding']['membershipEpoch'],ranks=local,
        resources=external['resources'],nativePIDs=external['nativePIDs'],sidecars=inputs,collection=pin(out/'collection.json'),
        physicalExecution=external['physicalExecution'],controllerResult=external['controllerResult'],
        actualExternalReservationVerified=True,ownerNativeReleaseAcknowledgmentsVerified=True,actualNativeZeroExitVerified=True,
        diagnosticEOFAndOwnerTransportExitVerified=True,sameEmptyCanonicalJournalVerified=True,aliasRestored=True,
        fullExpectedTargetSequenceVerified=True,independentFullRowStateComparisonPerformed=False,
        includesRecorderOverhead=True,crossHostClockSubtractionPerformed=False,transportWaitIsWireCost=False,
        gpuKernelDurationQualified=False,productTTFTQualified=False,encryptedTransportQualified=False)
    with (case/'phase-comparison.json').open('xb') as f:f.write((json.dumps(result,indent=2,sort_keys=True)+'\n').encode())
    print(json.dumps(dict(accepted=True,output=pin(case/'phase-comparison.json'))))
if __name__=='__main__':main()
