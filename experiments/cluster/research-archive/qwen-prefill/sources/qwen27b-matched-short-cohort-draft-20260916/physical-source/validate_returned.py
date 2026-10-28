"""Validate retained progressive evidence before admitting this one measured sample."""
import hashlib
import json
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parent
sys.path.insert(0,str(BASE.parent/'run-source-1'))
from binding_common import parse, require, same
from solo_inputs import validate_job, Pins
from solo_contract import expected_identity, admitted, report
from solo_progress import loaded, retired, reconcile
from reference_resources import sample_local, validate_local


def main():
    directory=BASE/'run-1/returned'
    pins=Pins()
    def raw(name, cap=16*1024*1024, empty=False):
        return pins.read(directory/name,cap,empty=empty)['raw']
    job_raw=raw('job.json');job=validate_job(parse(job_raw))
    same(job_raw,(BASE.parent/'run-source-1/job.json').read_bytes(),'Exact prospective job')
    prompt_raw=raw('prompt.json');expected_raw=raw('expected.json')
    same(hashlib.sha256(prompt_raw).hexdigest(),job['prompt_sha256'],'Raw prompt')
    same(hashlib.sha256(expected_raw).hexdigest(),job['expected_sha256'],'Expected output file')
    identity=expected_identity(job,parse(prompt_raw),parse(expected_raw))
    terminal=parse(raw('terminal.json'));owner=parse(raw('owner.json'))
    stream=raw('native/worker-0.stdout');rows=stream.splitlines()
    require(stream.endswith(b'\n') and len(rows)==5,'Exact1+1 progressive five-record stream')
    first=admitted(rows[0],identity);model=loaded(rows[1],identity,first)
    progress=[];previous=model['publishedNanoseconds']
    for index,line in enumerate(rows[2:4]):
        item=retired(line,identity,first,index,previous)
        previous=item['publishedNanoseconds'];progress.append(item)
    final=report(rows[4],identity,first,owner['nativePID'],Path(job['deployment']))
    reconcile(final,model,progress)
    same(raw('native/worker-0.stderr',empty=True),b'','Native stderr')
    for key,value in dict(schema='private_resident_solo_generation_terminal_v2',status='completed',
            recordsAccepted=5,completedRequestRecords=2,cohortTimingEligible=True,
            nativeExitCodes=[0],nativeLeaderReaped=True,ownedGroupFenceComplete=True,
            outputComplete=True,sourceInputsUnchanged=True,cleanupErrors=[],postflightErrors=[],
            primaryFailure=None).items():
        same(terminal[key],value,'Successful terminal '+key)
    fresh=parse((BASE/'run-1/root-review.json').read_bytes())
    same(fresh['active'],[],'Fresh process absence');same(fresh['journalBytes'],0,'Fresh empty journal')
    samples=[parse(line) for line in raw('resources.jsonl').splitlines()]
    require(1<=len(samples)<=1500,'Bounded complete resource evidence')
    for sample in samples:
        validate_local(sample)
        values=iter([sample['rawMemory'],sample['rawVMStat'],sample['rawPower']])
        replay=sample_local(read=lambda _:next(values))
        for key in ('actualFreeBytes','pressureLevel','reportedSwapBytes','acPower'):
            same(replay[key],sample[key],'Raw resource '+key)
    measurement=final['requests'][1]['execution']
    pins.recheck()
    result=dict(schema='short_solo_complete_cohort_sample_v1',completeCohortValidated=True,
        warmupExcluded=True,measuredCount=1,requestID=measurement['requestID'],
        selectedTokenIDsSHA256=measurement['selectedTokenIDsSHA256'],timing=measurement['timing'],
        nativeSHA256=job['native_sha256'],jobSHA256=hashlib.sha256(job_raw).hexdigest(),
        terminalSHA256=hashlib.sha256((directory/'terminal.json').read_bytes()).hexdigest(),
        resourceSampleCount=len(samples),minimumActualFreeBytes=min(x['actualFreeBytes'] for x in samples),
        independentFullRowStateComparisonPerformed=False,externalTTFTMeasured=False,
        allThreeMatchedCohortsCompleted=False,performanceQualificationEstablished=False)
    with (BASE/'run-1/validated-sample.json').open('x') as stream:
        json.dump(result,stream,sort_keys=True,indent=2);stream.write('\n')
    print(json.dumps(result))


if __name__=='__main__':main()
