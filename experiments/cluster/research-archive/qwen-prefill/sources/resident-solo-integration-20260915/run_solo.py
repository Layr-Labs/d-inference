#!/usr/bin/env python3
"""One fixed same-input 8K resident SOLO cohort; no distributed condition or TPS qualification."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import sys
import uuid

sys.dont_write_bytecode = True
from binding_inputs import snapshot
from stage_checks.common import canonical, digest, exact, parse, require
from stage_checks.long_profile import ARTIFACT, REQUIRED_ENVIRONMENT
from worker_adapter import ResidentWorkerCohort
from worker_contract import WorkerSpec, SUFFIXES, open_command
from worker_processes import cleanup_error_text
from solo_identity import SoloValidator
from solo_provenance import PinnedFiles, deployment, model_metadata, inherited, NATIVE_SHA, PACKAGE_SHA, BUNDLE_SHA
from solo_reference import Reference, REFERENCE_PINS
from solo_resources import ResourceGate


def write_new(path, raw):
    with Path(path).open('xb') as stream:
        os.fchmod(stream.fileno(),0o600);stream.write(raw);stream.flush();os.fsync(stream.fileno())


def write_json(path, value):
    write_new(path,(json.dumps(value,sort_keys=True,indent=2,allow_nan=False)+'\n').encode())


class RawEvents:
    def __init__(self, output):
        self.output=Path(output);self.index=0;self.records=[]
        (self.output/'events').mkdir(mode=0o700)

    def __call__(self, event):
        raw=snapshot(self.output/'pipes/worker-0.stdout',160*1024**2)['raw']
        lines=raw.splitlines(keepends=True)
        require(self.index<len(lines) and lines[self.index].endswith(b'\n'), 'Raw native event not yet retained')
        line=lines[self.index]
        exact(parse(line),event,'Parsed event differs from retained raw native line')
        name='events/%02d-%s.jsonl'%(self.index,event['type'])
        write_new(self.output/name,line)
        value=digest(line);self.records.append(dict(path=name,sha256=value,size_bytes=len(line)))
        self.index+=1
        return value


def four_requests(cohort_id):
    declared=[dict(request_id=cohort_id+suffix,epoch=uuid.uuid4().hex) for suffix in SUFFIXES]
    open_command(cohort_id, declared)
    requests=[dict(request_id=row['request_id'],phase='warmup' if i==0 else 'measured',
                   iteration=0 if i==0 else i-1) for i,row in enumerate(declared)]
    return declared,requests


def make_cohort(spec, cohort_id, declared, output, reference, resource_gate, timeout=315):
    """Actual single-cohort bridge. Tests may supply fabricated Python workers.

    The CLI alone supplies approved aa7d argv/environment after provenance checks.
    The pinned V3 adapter exposes its owned child list internally; this narrow
    coupling binds ready.processID to the actual Popen owner before run1.
    """
    capture=RawEvents(output)
    holder={}
    def pid():
        children=holder['cohort']._pipes.children
        require(len(children)==1,'Exactly one owned solo process required')
        return children[0].pid
    validator=SoloValidator(reference,Path(spec.argv[0]).parent,pid,capture)
    cohort=ResidentWorkerCohort(workers=[spec],cohort_id=cohort_id,requests=declared,
        output_directory=Path(output)/'pipes',timeout_seconds=timeout,resource_gate=resource_gate,
        identity_validator=validator.identity,numerical_validator=validator.numerical)
    holder['cohort']=cohort
    return cohort,validator,capture


def main(arguments=None):
    parser=argparse.ArgumentParser(description=__doc__,allow_abbrev=False)
    parser.add_argument('--deployment',type=Path,required=True)
    parser.add_argument('--model-dir',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--cohort-id',default='diagnostic:solo')
    args=parser.parse_args(arguments)
    declared,requests=four_requests(args.cohort_id)
    for path in (args.deployment,args.model_dir,args.output): require(path.is_absolute(),'Explicit absolute paths required')
    output=args.output
    require(output.parent.is_dir() and not os.path.lexists(output),'New output in existing directory required')
    resolved=output.resolve()
    require(all(not resolved.is_relative_to(p.resolve()) for p in (args.deployment,args.model_dir,Path(__file__).parent)),
            'Output must be outside deployment, model and launcher')
    output.mkdir(mode=0o700)
    resource_file=(output/'parent-resources.jsonl').open('xb',buffering=0);os.fchmod(resource_file.fileno(),0o600)
    def publish_resource(value):
        raw=canonical(value)+b'\n'; require(len(raw)<=65536,'Resource record exceeds bound')
        resource_file.write(raw)
    gate=ResourceGate(publish_resource)
    pins=PinnedFiles();reference=None;cohort=validator=capture=None
    receipt=dict(kind='registered9b_resident_solo_integration_v1',schemaVersion=1,status='preparing',
        startedAtUTC=datetime.now(timezone.utc).isoformat(),cohortID=args.cohort_id,
        nativeSHA256=NATIVE_SHA,packageManifestSHA256=PACKAGE_SHA,bundleManifestSHA256=BUNDLE_SHA,
        nativeExecutionAttempted=False,primaryFailure=None,postflightErrors=[],measurements=[],
        performanceQualified=False,physicalTwoMachineExecution=False,developmentWorkloadRepresentative=False,
        candidateNativeLogitBytesIndependentlyReconstructed=False,wholeProcessMemorySafetyEstablished=False,
        externalClientTTFTMeasured=False,mtpEnabled=False,
        timingScope='fresh CBv2 request-state creation through finite argmax/scalar readback; excludes load, readiness, final capture and retirement',
        resourceScope='parent polls actual free, pressure, swap and AC; native additionally checks low-power and thermal state before/after requests')
    original_cwd=Path.cwd();original_term=signal.getsignal(signal.SIGTERM)
    def interrupted(signum,frame): raise KeyboardInterrupt('Solo integration interrupted by signal '+str(signum))
    signal.signal(signal.SIGTERM,interrupted)
    primary=None
    try:
        gate('prelaunch')
        inherited(pins)
        # Retain own implementation identity before any model/native operation.
        for file in sorted(Path(__file__).parent.glob('*.py')):pins.read(file,2*1024**2,keep=False)
        bundle,package_raw=deployment(args.deployment,pins)
        config,model_manifest=model_metadata(args.model_dir,pins)
        reference=Reference();receipt['reference']=reference.summary
        write_new(output/'prompt.json',reference.prompt_raw)
        write_new(output/'config.json',config);write_new(output/'model-manifest.json',model_manifest)
        write_new(output/'deployment-manifest.json',package_raw)
        prompt=output/'prompt.json';pins.read(prompt,65536,REFERENCE_PINS['prompt.json'],keep=False)
        environment=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',LANG='C',**REQUIRED_ENVIRONMENT)
        argv=(str(bundle/'cluster-inference'),'--mode','qwen-resident-benchmark-worker','--role','solo',
              '--model-dir',str(args.model_dir),'--artifact-aggregate-sha256',ARTIFACT,
              '--tokens-file',str(prompt),'--long-prompt-sha256',REFERENCE_PINS['prompt.json'],
              '--timeout-seconds','300')
        write_json(output/'invocation.json',dict(argv=argv,environment=environment,cwd=str(bundle),
            declaredRequests=declared,requests=requests,nativeSeconds=300,parentSeconds=315,
            sourceAndInputPins=pins.records()))
        cohort,validator,capture=make_cohort(WorkerSpec(argv,environment,'solo',None),args.cohort_id,
                                            declared,output,reference,gate)
        # V3 intentionally inherits cwd; the standalone parent has no other work.
        os.chdir(bundle)
        receipt['nativeExecutionAttempted']=True
        with cohort:
            for request in requests:
                value=cohort.run(request)
                receipt['measurements'].append(dict(request=request,measurement=value))
                write_json(output/('measurement-%d.json'%(len(receipt['measurements'])-1)),receipt['measurements'][-1])
        require(validator.stopped and validator.ordinal==4,'Cohort did not complete validated shutdown')
        receipt['status']='completed'
    except BaseException as error:
        primary=error;receipt['status']='failed';receipt['primaryFailure']=cleanup_error_text(error)[0]
    finally:
        os.chdir(original_cwd);signal.signal(signal.SIGTERM,original_term)
        # These are independent postflight checks; one failure cannot skip others.
        for name,check in [('source_input_recheck',pins.recheck),('reference_recheck',reference.recheck if reference else lambda:None),
                           ('resource_postflight',lambda:gate('postflight'))]:
            try:check()
            except BaseException as error:
                receipt['postflightErrors'].append(dict(check=name,error=cleanup_error_text(error)[0]))
                if not isinstance(error,Exception) and isinstance(primary,(Exception,type(None))):primary=error
        if cohort is not None:
            try:receipt['transport']=cohort.evidence()
            except BaseException as error:receipt['postflightErrors'].append(dict(check='transport_evidence',error=cleanup_error_text(error)[0]))
        if validator is not None:
            receipt['validatedNumericalRequests']=validator.results;receipt['runtime']=validator.runtime
        if capture is not None:receipt['rawNativeEventFiles']=capture.records
        receipt['parentResourceSamples']=gate.samples
        try:
            resource_file.close()
            receipt['parentResourceLog']={k:v for k,v in snapshot(output/'parent-resources.jsonl',128*1024**2,keep=False,empty=True).items() if k in ('sha256','size_bytes')}
        except BaseException as error:
            receipt['postflightErrors'].append(dict(check='resource_log',error=cleanup_error_text(error)[0]))
            if not isinstance(error,Exception) and isinstance(primary,(Exception,type(None))):primary=error
        if receipt['postflightErrors']:receipt['status']='failed'
        receipt['completedAtUTC']=datetime.now(timezone.utc).isoformat()
        write_json(output/'receipt.json',receipt)
    print(json.dumps(dict(status=receipt['status'],receipt=str(output/'receipt.json'))))
    if primary is not None and not isinstance(primary,Exception):raise primary
    return 0 if receipt['status']=='completed' else 1


if __name__=='__main__':raise SystemExit(main())
