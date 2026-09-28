"""Single-process outer record admission; nested numerical comparison is audited separately."""
import json
import math
from pathlib import Path
import re
import uuid
from prefill_compute_inputs import ARTIFACT,CONFIGURATION,VOCABULARY,expected_frames,recorded_fingerprint

FIRST='qwen_layer_stage_baseline_checkpoint'
FINAL='qwen_layer_stage_prefill_report'
MAX_STDOUT=64*1024**2
MAX_LINE=60*1024**2


def require(value,message):
    if not value:raise ValueError(message)


def timeout(value):require(type(value)is int and 1<=value<=180,'Timeout must be integer1–180seconds')


def configuration(bundle,bundle_hash,model,prompt,seconds):
    timeout(seconds)
    require(len(prompt)==65 and all(type(x)is int and 0<=x<VOCABULARY for x in prompt),'Wrong fixed prompt')
    return dict(bundle=str(bundle),bundle_sha256=bundle_hash,rank=0,persistent=False,
        model_directory=str(model),artifact_aggregate_sha256=ARTIFACT,timeout_seconds=seconds,
        environment={'DARKBLOOM_BF16_WEIGHTS':'1'},environment_files={},input_files={'prompt.json':prompt},
        arguments=['--mode','qwen-layer-stage-prefill-check','--model-dir','@model',
            '--artifact-aggregate-sha256',ARTIFACT,'--execution-path','cbv2-contiguous',
            '--tokens-file','@rank/prompt.json','--prompt-tokens','65','--chunk-size','32',
            '--decode-tokens','1','--repeats','1','--warmups','0','--timeout-seconds',str(seconds)])


def parse(data):
    def pairs(values):
        result={}
        for key,value in values:require(key not in result,'Duplicate JSON key');result[key]=value
        return result
    def number(value):
        result=float(value);require(math.isfinite(result),'Nonfinite JSON number');return result
    def invalid(value):raise ValueError('Nonfinite JSON constant')
    return json.loads(data,object_pairs_hook=pairs,parse_float=number,parse_constant=invalid,
        parse_int=lambda value:-0.0 if value=='-0' else int(value))


def flags(record,**expected):
    for key,value in expected.items():require(type(record.get(key))is bool and record[key]is value,'Wrong flag: '+key)


def validate_request(value,prompt):
    require(isinstance(value,dict),'Missing recorded baseline request')
    request=value.get('request',{});identifier=request.get('requestID')
    require(type(identifier)is str and re.fullmatch('[0-9a-fA-F-]{36}',identifier)is not None,'Wrong request UUID')
    require(str(uuid.UUID(identifier))==identifier.lower(),'Noncanonical request UUID')
    for key,expected in [('promptCount',65),('chunkSize',32),('outputCount',1)]:
        require(type(request.get(key))is int and request[key]==expected,'Wrong request bound: '+key)
    require(type(value.get('vocabularySize'))is int and value['vocabularySize']==VOCABULARY,'Wrong vocabulary')
    require(value.get('promptTokenIDs')==prompt and all(type(x)is int for x in value['promptTokenIDs']) and value.get('teacherTokenIDs')==[],'Wrong prompt/teacher input')
    require(value.get('fingerprint')==recorded_fingerprint(identifier,prompt),'Wrong recorded request fingerprint')
    steps=[dict(frame=f,tokenIDs=prompt[f['tokenOffset']:f['tokenOffset']+f['tokenCount']])for f in expected_frames()]
    require(json.dumps(value.get('steps'),sort_keys=True)==json.dumps(steps,sort_keys=True),'Wrong recorded prefill-only schedule')


def validate_first(record,prompt):
    require(record.get('kind')==FIRST,'Expected existing baseline checkpoint first')
    flags(record,baselineModelReleasedBeforeStageLoading=True)
    baseline=record.get('baseline');require(isinstance(baseline,dict)and baseline.get('kind')=='qwen_layer_stage_recorded_baseline','Wrong baseline namespace')
    flags(baseline,correctnessOnly=True,throughputMeasurementValid=False,allRequestStateRetired=True)
    source=baseline.get('source',{})
    require(source.get('artifactAggregateSHA256')==ARTIFACT and source.get('sourceConfigurationSHA256')==CONFIGURATION,'Wrong baseline source pin/configuration')
    validate_request(baseline.get('request'),prompt)


def validate_final(record,first):
    require(record.get('kind')==FINAL and type(record.get('schemaVersion'))is int and record['schemaVersion']==1,'Wrong final namespace/schema')
    flags(record,correctnessOnly=True,throughputMeasurementValid=False,
          baselineModelReleasedBeforeStageLoading=True,stageModelsReleasedAfterComparison=True)
    require(isinstance(record.get('comparison'),dict) and record['comparison'],'Missing nested native comparison')
    if 'request'in record:
        require(json.dumps(record['request'],sort_keys=True)==json.dumps(first['baseline']['request'],sort_keys=True),'Final request differs from baseline')
    # The new comparison belongs to its native owner and independent auditor.
    # Do not guess its inner schema or convert declarations into numerical proof.


class Records:
    def __init__(self,directory,prompt):
        self.directory=Path(directory);self.prompt=prompt;self.offset=0;self.pending=b'';self.rows=[]
    def poll(self,final=False):
        err=self.directory/'stderr.log'
        require(not err.exists() or err.stat().st_size<=4*1024**2,'stderr exceeds4MiB')
        path=self.directory/'stdout.jsonl';size=path.stat().st_size if path.exists()else 0
        require(self.offset<=size<=MAX_STDOUT,'stdout shrank/exceeded64MiB')
        if size>self.offset:
            with path.open('rb')as stream:stream.seek(self.offset);chunk=stream.read(MAX_STDOUT-self.offset+1)
            self.offset+=len(chunk);self.pending+=chunk;require(self.offset<=MAX_STDOUT,'stdout grew beyond bound')
        while b'\n'in self.pending:
            raw,self.pending=self.pending.split(b'\n',1)
            require(raw and len(raw)<=MAX_LINE and len(self.rows)<2,'Invalid record size/count')
            value=parse(raw);require(isinstance(value,dict),'Record must be an object')
            if not self.rows:validate_first(value,self.prompt)
            else:validate_final(value,self.rows[0])
            self.rows.append(value)
        require(len(self.pending)<=MAX_LINE,'Partial record exceeds line bound')
        if final:require(not self.pending and len(self.rows)==2,'EOF without both complete records')
