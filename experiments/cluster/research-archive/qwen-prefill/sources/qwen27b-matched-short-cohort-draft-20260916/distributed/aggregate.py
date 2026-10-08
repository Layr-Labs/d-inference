"""Three complete fresh1+1 cohorts; failure in any cohort produces no aggregate."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import sys
from timing_results import require, validate_cohort
from run import BASE, OLD, verify


def summarize(cohorts):
    require(type(cohorts) is list and len(cohorts)==3,'Exactly three complete cohorts required')
    results=[];epochs=set();identifiers=set();reference=None
    for config, pin, lines, execution in cohorts:
        result=validate_cohort(config,pin,lines,execution)
        keys=('policyLabel','promptTokenIDs','expectedTokenIDs','chunkSize','outputCount','stopTokenIDs')
        bound={k:config[k] for k in keys}
        if reference is None: reference=bound
        require(bound==reference,'Cohorts have different policy or matched inputs')
        require(config['membershipEpoch'] not in epochs,'Cohort epoch reused')
        epochs.add(config['membershipEpoch'])
        ids={r['requestID'] for r in result['requests']}
        require(not identifiers.intersection(ids),'Request history reused across cohorts')
        identifiers.update(ids);results.append(result)
    return dict(schema='three_complete_short_distributed_cohorts_v1',policy=reference['policyLabel'],
        completeCohortCount=3,excludedWarmupCount=3,measuredCount=3,failedCohortsExcludedByRefusal=True,
        cohorts=results,medianInternalFirstTokenSeconds=statistics.median(r['medianInternalFirstTokenSeconds'] for r in results),
        medianPrefillTokensPerSecond=statistics.median(r['medianPrefillTokensPerSecond'] for r in results),
        medianContinuationTokensPerSecond=statistics.median(r['medianContinuationTokensPerSecond'] for r in results),
        prefillNumerator=8192,continuationNumerator=127,externalTTFTMeasured=False,
        wholeControllerElapsedUsedAsThroughput=False,independentFullRowStateComparisonPerformed=False,
        diagnosticEOFCompletenessProven=False,encryptedRDMAQualified=False,providerCapacityUpdated=False)


def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--policy',required=True,choices=('serial','lookahead'))
    args=parser.parse_args();verify()
    sys.path.insert(0,str(OLD/'helpers'/args.policy));sys.path.insert(0,str(OLD/args.policy))
    import audit_common as common
    from snapshot import snapshot
    from reference_resources import sample_local,validate_local
    saved=[]
    def raw(path):
        item=snapshot(path,16*1024**2);saved.append((path,{k:v for k,v in item.items() if k!='raw'}));return item['raw']
    def read(path):return common.parse(raw(path))
    declarations=read(BASE/'configurations.json')['configurations']
    cohorts=[];resource_rows=[]
    for index in (1,2,3):
        case=BASE/(args.policy+'-'+str(index))
        declaration,=[x for x in declarations if x['case']==case.name]
        config_raw=raw(case/'configuration/controller.json')
        common.exact(hashlib.sha256(config_raw).hexdigest(),declaration['sha256'],'Frozen config')
        config=common.parse(config_raw)
        lines=[common.parse(x) for x in raw(case/'physical-1/controller.stdout.jsonl').splitlines() if x]
        execution=read(case/'physical-1/execution.json')
        cohorts.append((config,declaration['sha256'],lines,execution))
        for rank in (0,1):
            samples=[common.parse(x) for x in raw(case/('physical-1/resources-'+str(rank)+'.jsonl')).splitlines() if x]
            common.exact([x['ordinal'] for x in samples],list(range(len(samples))),'Resource ordinals')
            common.integer(len(samples),1,1400)
            for sample in samples:
                common.exact(sample['admissible'],True,'Resource monitor acceptance');validate_local(sample)
                values=iter([sample['rawMemory'],sample['rawVMStat'],sample['rawPower']])
                replay=sample_local(read=lambda _:next(values))
                for key in ('actualFreeBytes','pressureLevel','reportedSwapBytes','acPower'):
                    common.exact(replay[key],sample[key],'Raw resource '+key)
            resource_rows.append(dict(cohort=index,rank=rank,sampleCount=len(samples),
                minimumActualFreeBytes=min(x['actualFreeBytes'] for x in samples)))
    result=summarize(cohorts);result['resources']=resource_rows
    result['inputs']=[dict(path=str(path),**item) for path,item in saved]
    for path,item in saved:
        common.exact({k:v for k,v in snapshot(path,16*1024**2,keep=False).items() if k!='raw'},item,'Input recheck')
    with (BASE/(args.policy+'-three-cohorts.json')).open('x') as output:
        json.dump(result,output,sort_keys=True,indent=2);output.write('\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('cohorts','inputs','resources')}))


if __name__=='__main__':main()
