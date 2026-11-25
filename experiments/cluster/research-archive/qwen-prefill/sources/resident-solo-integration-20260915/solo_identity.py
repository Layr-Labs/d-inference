"""Native lifecycle/source/input checks for the one admitted solo cohort."""
import copy
import uuid
from runtime_binding import validate_runtime_pair
from stage_checks.common import exact, integer, require
from stage_checks.long_identity import request_identity
from solo_reference import fields, REFERENCE_PINS
from solo_resources import native_resources


class SoloValidator:
    def __init__(self, reference, bundle, pid, capture):
        self.reference, self.bundle, self.pid, self.capture = reference, str(bundle), pid, capture
        self.ready = self.released = self.stopped = False
        self.ordinal = 0; self.last_time = 0; self.last_close = 0
        self.pending = None; self.runtime = None; self.results = []

    def identity(self, spec, event, command):
        require(spec.role=='solo' and spec.rank is None, 'Only solo is supported')
        kind, row = event['type'], event['record']
        if kind=='ready':
            require(not self.ready and self.ordinal==0, 'Duplicate ready')
            fields(row,'execution initialResources loadedResources runtime','ready')
            evidence=self.reference.evidence
            expected=dict(kind='qwen_long_prefill_resident_solo_ready',schemaVersion=1,
                source=self.reference.execution['source'],sourceLoad=self.reference.execution['sourceLoad'],
                arithmeticEnvironment=evidence['arithmeticEnvironment'],
                arithmeticEnvironmentSHA256=evidence['arithmeticEnvironmentSHA256'],
                resourceAdmission=evidence['resourceAdmission'],requestCount=4,warmupCount=1,
                verifiedModelLoaded=True,freshRequestStateCreated=False,correctnessOnly=True,
                throughputMeasurementValid=False,physicalTransferQualified=False,independentNumericalComparisonPerformed=False)
            exact(row['execution'],expected,'Loaded-ready source/resource/arithmetic differs')
            initial=native_resources(row['initialResources'])
            self.last_time=native_resources(row['loadedResources'],after=initial)
            self.runtime=validate_runtime_pair(row['runtime'],row['runtime'],self.pid(),[self.bundle])
            require(self.runtime['executablePathReported'],'Ready must report the native executable path')
            self.ready=True
        elif kind=='result':
            require(self.ready and not self.released and self.pending is None and self.ordinal<4,'Unexpected result')
            ordinal=command['sequence']-1; require(ordinal==self.ordinal,'Result ordinal differs')
            _,_,history=request_identity(command['epoch'],self.reference.prompt)
            step=copy.deepcopy(row['step']);fields(step,'ordinal excludedWarmup requestID recordedRequestFingerprint promptFileSHA256','step')
            require(type(step['requestID']) is str and uuid.UUID(step['requestID'])==uuid.UUID(command['epoch']), 'Step UUID differs')
            step['requestID']=str(uuid.UUID(step['requestID']))
            exact(step,dict(ordinal=ordinal,excludedWarmup=ordinal==0,requestID=str(uuid.UUID(command['epoch'])),
                recordedRequestFingerprint=history,promptFileSHA256=REFERENCE_PINS['prompt.json']),'Step identity differs')
            summary=self.reference.validate(row['execution'],command['epoch'])
            before=native_resources(row['resourcesBeforeRequest'],after=self.last_time)
            require(before<=summary['start'] and summary['start']>self.last_close,'Preparation/timing order differs')
            self.last_time=native_resources(row['resourcesAfterRequest'],after=summary['closed'])
            self.last_close=summary['closed'];self.pending=(command,summary)
        elif kind=='released':
            require(self.ready and self.ordinal==4 and self.pending is None and not self.released,'Early/duplicate release')
            fields(row,'completedRequestCount memory resourcesAfterRelease modelLoadCount modelReleased allRequestStateRetired '
                   'correctnessOnly throughputMeasurementValid physicalTransferQualified independentNumericalComparisonPerformed','released')
            for key,value in dict(completedRequestCount=4,modelLoadCount=1,modelReleased=True,allRequestStateRetired=True,
                    correctnessOnly=True,throughputMeasurementValid=False,physicalTransferQualified=False,
                    independentNumericalComparisonPerformed=False).items(): exact(row[key],value,'Release '+key)
            phases=['before_resident_full_model_load','resident_full_model_loaded_no_request_state']+[
                'resident_solo_request_%d_retired_weights_resident'%i for i in range(4)]+['resident_full_model_released_cache_cleared']
            require(type(row['memory']) is list and len(row['memory'])==7,'Release memory phases differ')
            peak=0
            for item,phase in zip(row['memory'],phases):
                fields(item,'phase activeMLXBytes cachedMLXBytes peakMLXBytesSinceProcessStart','memory')
                require(item['phase']==phase,'Memory phase differs')
                active=integer(item['activeMLXBytes']);integer(item['cachedMLXBytes'])
                current=integer(item['peakMLXBytesSinceProcessStart']);require(current>=max(active,peak),'Allocator peak regressed');peak=current
            require(row['memory'][-1]['cachedMLXBytes']==0,'Final cache not cleared')
            self.last_time=native_resources(row['resourcesAfterRelease'],after=self.last_time);self.released=True
        elif kind=='stopped':
            require(self.released and not self.stopped,'Stopped without release')
            exact(row,dict(completedRequestCount=4,modelReleased=True,allRequestStateRetired=True,explicitShutdownAccepted=True,
                correctnessOnly=True,throughputMeasurementValid=False,physicalTransferQualified=False,
                independentNumericalComparisonPerformed=False),'Stopped record differs');self.stopped=True
        else: raise ValueError('Unknown event')
        source_sha=self.capture(event)
        if kind=='result':self.pending=self.pending+(source_sha,)

    def numerical(self, command, events):
        require(len(events)==1 and self.pending is not None,'Missing solo numerical result')
        original,summary,source_sha=self.pending;exact(command,original,'Numerical command differs')
        self.results.append(summary);self.pending=None;self.ordinal+=1
        return dict(elapsed_ns=summary['elapsed_ns'],prompt_tokens=8192,generated_tokens=1,source_sha256=source_sha)
