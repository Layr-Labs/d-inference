"""Bounded outer identities only; exact layer/state/logit qualification belongs to the CPU audit."""

import json
import math
from pathlib import Path
import re
import uuid

from stage_rank_inputs import ARTIFACT, CONFIGURATION, VOCABULARY, expected_frames, request_fingerprint

MAX_STDOUT_BYTES = 64 * 1024**2
MAX_LINE_BYTES = 60 * 1024**2
MAX_STDERR_BYTES = 4 * 1024**2


def require_timeout(value):
    if type(value) is not int or not 1 <= value <= 180:
        raise ValueError('Stage rank timeout must be an integer1–180seconds')


def rank_configuration(bundle, bundle_hash, rank, epoch, timeout, hosts, model, prompt, teacher):
    require_timeout(timeout)
    if type(rank) is not int or rank not in (0,1) or re.fullmatch('[0-9a-f]{32}', epoch) is None:
        raise ValueError('Invalid stage rank/epoch')
    if len(hosts) != 2 or any(not isinstance(row,list) or len(row)!=1 for row in hosts):
        raise ValueError('Expected two loopback endpoints')
    ports=[]
    for row in hosts:
        match=re.fullmatch(r'127\.0\.0\.1:([0-9]{1,5})',row[0])
        if match is None or not 1<=int(match[1])<=65535: raise ValueError('Invalid loopback endpoint')
        ports.append(int(match[1]))
    if len(set(ports))!=2: raise ValueError('Duplicate loopback ports')
    if len(prompt)!=65 or len(teacher)!=3 or any(type(x)is not int or not 0<=x<VOCABULARY for x in prompt+teacher):
        raise ValueError('Invalid fixed prompt/teacher history')
    return dict(bundle=str(bundle),bundle_sha256=bundle_hash,rank=rank,persistent=False,
        model_directory=str(model),artifact_aggregate_sha256=ARTIFACT,timeout_seconds=timeout,
        arguments=['--mode','qwen-layer-stage-rank-check','--model-dir','@model',
            '--artifact-aggregate-sha256',ARTIFACT,'--transport','loopback-test','--epoch',epoch,
            '--execution-path','cbv2-contiguous','--tokens-file','@rank/prompt.json',
            '--teacher-tokens-file','@rank/teacher.json','--prompt-tokens','65','--chunk-size','32',
            '--decode-tokens','4','--repeats','1','--warmups','0','--timeout-seconds',str(timeout)],
        environment={'MLX_RANK':str(rank),'DARKBLOOM_BF16_WEIGHTS':'1'},
        environment_files={'MLX_HOSTFILE':'hosts.json'},
        input_files={'hosts.json':hosts,'prompt.json':prompt,'teacher.json':teacher})


def strict_json(data):
    def pairs(items):
        result={}
        for key,value in items:
            if key in result: raise ValueError('Duplicate JSON key')
            result[key]=value
        return result
    def number(value):
        result=float(value)
        if not math.isfinite(result): raise ValueError('Nonfinite JSON number')
        return result
    def invalid(value): raise ValueError('Nonfinite JSON constant: '+value)
    return json.loads(data, object_pairs_hook=pairs,parse_constant=invalid,parse_float=number,
                      parse_int=lambda value: -0.0 if value=='-0' else int(value))


def validate_record(record, rank, epoch, inputs):
    if not isinstance(record,dict): raise ValueError('Stage record must be an object')
    for key,value in [('schemaVersion',1),('rank',rank),('worldSize',2)]:
        if type(record.get(key)) is not int or record[key]!=value: raise ValueError('Stage integer identity mismatch: '+key)
    for key,value in [('epoch',epoch),('backend','ring'),('transport','loopback-test')]:
        if record.get(key)!=value: raise ValueError('Stage identity mismatch: '+key)
    kind=record.get('kind')
    if kind not in ('qwen_layer_stage_rank_ready','qwen_layer_stage_rank_report'):
        raise ValueError('Unexpected stage record kind')
    if kind.endswith('_ready'): return kind
    for key,value in [('completed',True),('correctnessOnly',True),('throughputMeasurementValid',False),
                      ('modelForwardCompared',False),('allRequestStateRetired',True),('modelReleased',True)]:
        if type(record.get(key))is not bool or record[key]is not value: raise ValueError('Stage terminal flag mismatch: '+key)
    def require_digest(value):
        if not isinstance(value,str) or re.fullmatch('[0-9a-f]{64}',value) is None:
            raise ValueError('Missing/malformed stage identity digest')
    source=record.get('sourceLoad')
    if not isinstance(source,dict) or type(source.get('stageIndex'))is not int or source['stageIndex']!=rank:
        raise ValueError('Wrong source stage index')
    if source.get('verifiedAggregateSHA256')!=ARTIFACT or source.get('sourceConfigurationSHA256')!=CONFIGURATION:
        raise ValueError('Source artifact/configuration differs')
    for key in ('planSHA256','storageCommitmentSHA256'):
        require_digest(source.get(key))
    request=record.get('request')
    if not isinstance(request,dict) or request.get('promptTokenIDs')!=inputs['prompt'] or request.get('teacherTokenIDs')!=inputs['teacher']:
        raise ValueError('Recorded token history differs')
    if any(type(value)is not int for value in request['promptTokenIDs']+request['teacherTokenIDs']):
        raise ValueError('Recorded token IDs must be JSON integers')
    if type(request.get('vocabularySize'))is not int or request['vocabularySize']!=VOCABULARY:
        raise ValueError('Recorded vocabulary differs')
    spec=request.get('request',{})
    if spec.get('requestID','').lower()!=str(uuid.UUID(hex=epoch)) or any(type(spec.get(k))is not int or spec[k]!=v for k,v in [('promptCount',65),('chunkSize',32),('outputCount',4)]):
        raise ValueError('Recorded request identity/schedule differs')
    frames=record.get('frames')
    if not isinstance(frames,list) or len(frames)!=6: raise ValueError('Expected exactly six stage frame completions')
    for item,expected in zip(frames,expected_frames()):
        capture=item.get('capture',{})
        if item.get('kind')!='qwen_layer_stage_rank_frame_completion' or capture.get('kind')!='qwen_layer_stage_rank_frame_capture':
            raise ValueError('Invalid frame completion/capture kind')
        actual=capture.get('frame',{})
        if set(actual)!=set(expected) or any(type(actual.get(key))is not int for key in ('sequence','tokenOffset','tokenCount')) or type(actual.get('finalPromptChunk'))is not bool:
            raise ValueError('Frame fields/types differ')
        if capture.get('frame')!=expected or type(capture.get('committedTokens'))is not int or capture['committedTokens']!=expected['tokenOffset']+expected['tokenCount']:
            raise ValueError('Incomplete or reordered frame schedule')
        identity=capture.get('identity',{})
        if type(identity.get('stageIndex'))is not int or identity['stageIndex']!=rank or identity.get('requestFingerprint')!=request_fingerprint(epoch):
            raise ValueError('Wrong captured stage/request identity')
        for key in ('artifactAggregateSHA256','storageCommitmentSHA256','sourceConfigurationSHA256','planFingerprint'):
            require_digest(identity.get(key))
        require_digest(item.get('headerSHA256'));require_digest(capture.get('boundaryPayloadSHA256'))
        if identity.get('artifactAggregateSHA256')!=ARTIFACT or identity.get('sourceConfigurationSHA256')!=CONFIGURATION or identity.get('storageCommitmentSHA256')!=source['storageCommitmentSHA256'] or identity.get('planFingerprint')!=source['planSHA256']:
            raise ValueError('Captured source identity differs from verified stage receipt')
        if identity.get('bf16ConversionEnabled')is not True or identity.get('activationDType')!='bfloat16':
            raise ValueError('Captured source dtype/conversion policy differs')
        phase='consumed_ack_received_and_validated' if rank==0 else 'consumed_ack_send_completed'
        if item.get('completedTransportPhase')!=phase: raise ValueError('Frame lacks completed consumed acknowledgement')
    return kind


class RankRecords:
    def __init__(self,directory,rank,epoch,inputs):
        self.directory,self.rank,self.epoch,self.inputs=Path(directory),rank,epoch,inputs
        self.offset,self.pending,self.records=0,b'',[]
        self.terminal=None
    def poll(self,final=False):
        stderr=self.directory/'stderr.log'
        if stderr.exists() and stderr.stat().st_size>MAX_STDERR_BYTES: raise ValueError('Stage stderr exceeds bound')
        path=self.directory/'stdout.jsonl'
        size=path.stat().st_size if path.exists() else 0
        if size<self.offset or size>MAX_STDOUT_BYTES: raise ValueError('Stage stdout changed/exceeds64MiB')
        if size>self.offset:
            with path.open('rb') as stream:
                stream.seek(self.offset); data=stream.read(MAX_STDOUT_BYTES-self.offset+1)
            self.offset+=len(data); self.pending+=data
            if self.offset>MAX_STDOUT_BYTES: raise ValueError('Stage stdout exceeds64MiB')
        while b'\n' in self.pending:
            line,self.pending=self.pending.split(b'\n',1)
            if not line or len(line)>MAX_LINE_BYTES or len(self.records)>=2 or self.terminal is not None:
                raise ValueError('Stage record count/order/size invalid')
            record=strict_json(line.decode('utf-8'))
            kind=validate_record(record,self.rank,self.epoch,self.inputs)
            expected='qwen_layer_stage_rank_ready' if not self.records else 'qwen_layer_stage_rank_report'
            if kind!=expected: raise ValueError('Stage report must follow one ready record')
            self.records.append(record)
            if kind.endswith('_report'): self.terminal=record
        if len(self.pending)>MAX_LINE_BYTES: raise ValueError('Stage JSONL partial line exceeds60MiB')
        if final and (self.pending or self.terminal is None): raise ValueError('Stage EOF lacks terminal report')


def validate_pair(readers):
    if len(readers)!=2 or any(reader.terminal is None for reader in readers): raise ValueError('Both stages must finish')
    a,b=[reader.terminal for reader in readers]
    if a['request']!=b['request']: raise ValueError('Peer request histories differ')
    for key in ('verifiedAggregateSHA256','sourceConfigurationSHA256','planSHA256','storageCommitmentSHA256'):
        if a['sourceLoad'].get(key)!=b['sourceLoad'].get(key): raise ValueError('Peer source commitment differs: '+key)
    common=('requestFingerprint','artifactAggregateSHA256','storageCommitmentSHA256','bf16ConversionEnabled',
            'sourceConfigurationSHA256','planFingerprint','activationDType')
    for left,right in zip(a['frames'],b['frames']):
        for key in common:
            if left['capture']['identity'].get(key)!=right['capture']['identity'].get(key):
                raise ValueError('Peer frame identity differs: '+key)
        if left.get('headerSHA256')!=right.get('headerSHA256') or left['capture'].get('boundaryPayloadSHA256')!=right['capture'].get('boundaryPayloadSHA256'):
            raise ValueError('Peer residual/header digest differs')
    return dict(terminal_records=2,complete_frames_per_rank=[6,6],peer_outer_identity_agreement=True,
                state_logit_source_oracle_not_run_by_launcher=True,baseline_comparison_passed=None)
