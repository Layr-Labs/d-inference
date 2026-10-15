"""Accept completed physical evidence, then compare full rows/state and timings."""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path
import statistics
from decimal import Decimal

def require(condition,message):
    if not condition:raise ValueError(message)

def read(path):return json.loads(path.read_bytes())

def validate_launch(case,kind,mode,host):
    outer=case/kind;directory=outer/mode;receipt=read(outer/'receipt.json')
    expected_modes=['full'] if kind=='solo' else ['stage0','stage1']
    require(receipt['status']=='completed' and not receipt.get('errors') and not receipt.get('error')
            and not receipt.get('cleanupErrors') and not receipt.get('collectionErrors'),
            'Outer physical launch failed')
    require(sorted(x['mode'] for x in receipt['results'])==expected_modes
            and all(x['exitCode']==0 for x in receipt['results']), 'Missing/failed SSH launches')
    require(sorted(x['host'] for x in receipt['quiescence'])==
            (['darkbloom-48'] if kind=='solo' else ['darkbloom-24','darkbloom-48']),
            'Incomplete bilateral retirement observations')
    if kind=='pair':require(receipt['aliasRelease']['restored'],'Thunderbolt alias was not restored')
    launched=next(x for x in receipt['results'] if x['mode']==mode)
    require(launched['host']==host,'Physical host role differs')
    require((outer/(mode+'.stderr')).stat().st_size==0,'Remote parent emitted stderr')
    lines=(outer/(mode+'.stdout')).read_bytes().splitlines()
    require(len(lines)==1,'Remote completion output differs')
    completion=json.loads(lines[0]);terminal_bytes=(directory/'terminal.json').read_bytes()
    require(completion['status']=='completed' and completion['mode']==mode
            and completion['run']==launched['remoteDirectory']
            and completion['terminalSHA256']==hashlib.sha256(terminal_bytes).hexdigest(),
            'Collected terminal does not match actual SSH completion')
    expected_job=(case/(mode+'.json')).read_bytes()
    require((directory/'job.json').read_bytes()==expected_job,'Collected job differs from original request')
    terminal=json.loads(terminal_bytes)
    require(terminal['jobSHA256']==hashlib.sha256(expected_job).hexdigest(),'Terminal job identity differs')

def sidecar(directory,row):
    require(Path(row['name']).name==row['name'],'Unsafe sidecar name')
    raw=(directory/'sidecars'/row['name']).read_bytes()
    require(len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],'Sidecar bytes changed')
    return raw

def load(directory,mode):
    terminal=read(directory/'terminal.json');job=read(directory/'job.json')
    require(terminal['status']=='completed' and terminal['exitCodes']==[0]
            and terminal['groupsAbsent'] and terminal['outputComplete']
            and terminal['journalEmptyAndProcessesRetired'] and not terminal['cleanupErrors'],
            'Physical owner did not retire successfully')
    value=terminal['result']
    require(value['schema']=='gemma4_resident_benchmark_result_v1' and value['job']==job
            and job['mode']==mode and value['nativeExecuted'] and value['modelReleased']
            and value['nativeCacheBytesAfterRelease']==0,'Native result identity/release')
    require(value['warmupRequests']==1 and value['measuredRequests']==3
            and len(value['samples'])==4,'Incomplete cohort')
    require(value['collectiveCreated']==(mode!='full') and value['collectiveReleased']==(mode!='full'),
            'Transport release evidence differs')
    observations=0
    for line in (directory/'resources.jsonl').read_bytes().splitlines():
        observed=json.loads(line);observations+=1
        page=re.search(r'page size of (\d+) bytes',observed['rawVMStat'])
        free=re.search(r'Pages free:\s+(\d+)\.',observed['rawVMStat'])
        swap=re.search(r'used\s*=\s*([0-9.]+)([MG])',observed['rawMemory'])
        require(page and free and swap,'Incomplete raw resource observation')
        require(observed['actualFreeBytes']==int(page[1])*int(free[1])
                and observed['pressureLevel']==int(observed['rawMemory'].splitlines()[0])
                and Decimal(observed['reportedSwapBytes'])==Decimal(swap[1])*(1024**2 if swap[2]=='M' else 1024**3)
                and observed['acPower']==("Now drawing from 'AC Power'" in observed['rawPower']),
                'Parsed resource observation does not match retained raw data')
        require(observed['actualFreeBytes']>=6*1024**3 and observed['pressureLevel']==1
                and observed['acPower'] and Decimal(observed['reportedSwapBytes'])==0,
                'A resource observation violates the retained physical gates')
    require(observations>0,'Missing physical resource observations')
    for ordinal,sample in enumerate(value['samples']):
        require(sample['ordinal']==ordinal and sample['warmup']==(ordinal==0)
                and sample['requestID']==job['requestIDs'][ordinal],'Request identity/order')
        require(len(sample['selectedTokenIDs'])==job['outputCount']
                and sample['committedTokens']==job['promptCount']+job['outputCount']-1
                and sample['requestStateRetired'],'Token/state completion')
        agreements=sample['tokenAgreementNanoseconds']
        require(len(agreements)==job['outputCount'] and all(a<b for a,b in zip(agreements,agreements[1:])),
                'Token clocks are not strictly increasing')
        prefill=agreements[0]-sample['startedNanoseconds'];decode=agreements[-1]-agreements[0]
        require(prefill==sample['prefillNanoseconds']>0 and decode==sample['decodeNanoseconds']>0,
                'Timing arithmetic differs')
        require(math.isclose(sample['prefillTokensPerSecond'],job['promptCount']*1e9/prefill,rel_tol=1e-12)
                and math.isclose(sample['decodeTokensPerSecond'],(job['outputCount']-1)*1e9/decode,rel_tol=1e-12),
                'Throughput arithmetic differs')
    require(len({tuple(x['selectedTokenIDs']) for x in value['samples']})==1,'Fresh request output differs')
    for row in value['files']:sidecar(directory,row)
    return value

def state(directory,sample):
    result={}
    value=sample['finalState']
    require(value['frontier']==sample['committedTokens'],'Snapshot frontier differs')
    for entry in value['entries']:
        key=(entry['globalLayerIndex'],entry['component'])
        require(key not in result,'Duplicate state component')
        raw=sidecar(directory,entry['file'])
        require(len(raw)==entry['byteCount'] and hashlib.sha256(raw).hexdigest()==entry['sha256'],
                'State payload differs from entry')
        result[key]=(entry['dtype'],entry['shape'],entry['logicalRange'],raw)
    return result

def state_keys(start,end):
    return {(layer,component) for layer in range(start,end)
            for component in ('kv.keys','kv.values','kv.position_offsets')}

def summarize(samples,prompt,outputs):
    measured=samples[1:]
    return dict(measurements=len(measured),
                prefillTPS=prompt*len(measured)*1e9/sum(x['prefillNanoseconds'] for x in measured),
                decodeTPS=(outputs-1)*len(measured)*1e9/sum(x['decodeNanoseconds'] for x in measured),
                medianInternalFirstTokenSeconds=statistics.median(x['prefillNanoseconds']/1e9 for x in measured),
                perRequestPrefillTPS=[x['prefillTokensPerSecond'] for x in measured])

def compare(directory):
    validate_launch(directory,'solo','full','darkbloom-48')
    validate_launch(directory,'pair','stage0','darkbloom-24')
    validate_launch(directory,'pair','stage1','darkbloom-48')
    paths=[directory/'solo/full',directory/'pair/stage0',directory/'pair/stage1']
    values=[load(path,mode) for path,mode in zip(paths,['full','stage0','stage1'])]
    solo,rank0,rank1=values;job=solo['job']
    for other in values[1:]:
        require({k:v for k,v in other['job'].items() if k not in ('mode','outputDirectory')}
                =={k:v for k,v in job.items() if k not in ('mode','outputDirectory')},'Unmatched paired jobs')
        require(other['planSHA256']==solo['planSHA256'] and other['scopeSHA256']==solo['scopeSHA256'],
                'Paired plan/cohort mismatch')
        require(other['sourceLoad']['artifactSHA256']==solo['sourceLoad']['artifactSHA256'],'Artifact differs')
    capture=job['captureEvidence'];rows=components=state_bytes=0
    for ordinal,(a,b,c) in enumerate(zip(*(v['samples'] for v in values))):
        require(a['selectedTokenIDs']==b['selectedTokenIDs']==c['selectedTokenIDs'],f'Generation differs at request {ordinal}')
        if capture:
            full=json.loads(sidecar(paths[0],a['finalRow']))
            stage=json.loads(sidecar(paths[2],c['finalRow']))
            require(full==stage and full['shape']==[1,262144] and len(full['values'])==262144,
                    f'Complete final logit row differs at request {ordinal}')
            require(all(math.isfinite(x) for x in full['values']),'Nonfinite logit')
            require(full['values'].index(max(full['values']))==a['selectedTokenIDs'][-1],'Final argmax differs')
            sa,sb,sc=[state(path,sample) for path,sample in zip(paths,[a,b,c])]
            require(set(sa)==state_keys(0,30) and set(sb)==state_keys(0,job['cut'])
                    and set(sc)==state_keys(job['cut'],30),'Native state key domain differs')
            require(len(sa)==90 and not set(sb)&set(sc) and sa=={**sb,**sc},
                    f'Final native state differs at request {ordinal}')
            rows+=1;components+=len(sa);state_bytes+=sum(len(value[3]) for value in sa.values())
    p,o=job['promptCount'],job['outputCount']
    report=dict(schema='gemma4_matched_resident_comparison_v1',status='passed',promptTokens=p,outputTokens=o,
                cut=job['cut'],mtpEnabled=False,transport='plaintext JACCL/RDMA',
                numericalEvidence='all generated IDs, complete final rows and native final state' if capture else 'generated IDs only',
                fullRowsCompared=rows,stateComponentsCompared=components,stateBytesCompared=state_bytes,
                solo=summarize(solo['samples'],p,o),rank0=summarize(rank0['samples'],p,o),rank1=summarize(rank1['samples'],p,o),
                externalTTFTMeasured=False,representativeWorkloadStudyComplete=False,
                timingIncludesResourceChecks=True,captureOutsideTimedInterval=capture,
                benchmarkNativeSHA256=job['buildIdentitySHA256'],artifactSHA256=solo['sourceLoad']['artifactSHA256'])
    report['distributedConservativePrefillTPS']=min(report['rank0']['prefillTPS'],report['rank1']['prefillTPS'])
    report['prefillSpeedup']=report['distributedConservativePrefillTPS']/report['solo']['prefillTPS']
    return report

def main():
    parser=argparse.ArgumentParser();parser.add_argument('case',type=Path);args=parser.parse_args()
    report=compare(args.case)
    with (args.case/'comparison.json').open('x') as stream:json.dump(report,stream,indent=2,allow_nan=False)
    print(json.dumps(report))

if __name__=='__main__':main()
