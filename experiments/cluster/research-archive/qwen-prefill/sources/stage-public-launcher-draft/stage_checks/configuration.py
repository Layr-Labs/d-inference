"""Exact mode-specific native argv, with no TP, persistent worker or remote path."""
import re
from .common import integer,require


def build(rank,epoch,context,bundle,bundle_hash,hosts,timeout):
    integer(rank,0,1);integer(timeout,1,60 if context['mode']=='p2p' else 180)
    require(type(epoch)is str and re.fullmatch('[0-9a-f]{32}',epoch),'Invalid fresh cohort epoch')
    require(isinstance(hosts,list) and len(hosts)==2,'Exactly two local endpoints are required')
    ports=[]
    for row in hosts:
        require(isinstance(row,list) and len(row)==1 and isinstance(row[0],str),'One endpoint per rank is required')
        match=re.fullmatch(r'127\.0\.0\.1:([0-9]{1,5})',row[0]);require(match is not None,'Only literal IPv4 loopback is supported')
        ports.append(integer(int(match[1]),1,65535))
    require(len(set(ports))==2,'Loopback ports must differ')
    environment={'MLX_RANK':str(rank)};files={'hosts.json':hosts}
    arguments=['--mode','stage-p2p-check' if context['mode']=='p2p' else 'qwen-layer-stage-rank-check']
    config=dict(rank=rank,bundle=str(bundle),bundle_sha256=bundle_hash,persistent=False,
                timeout_seconds=timeout,environment=environment,environment_files={'MLX_HOSTFILE':'hosts.json'},input_files=files)
    if context['mode']=='p2p':arguments+=['--synthetic']
    else:
        request=context['request'];spec=request['request'];environment['DARKBLOOM_BF16_WEIGHTS']='1'
        files['tokens.json']=request['promptTokenIDs']
        arguments+=['--model-dir','@model','--artifact-aggregate-sha256',context['artifact'],
                    '--execution-path','cbv2-contiguous','--tokens-file','@rank/tokens.json',
                    '--prompt-tokens',str(spec['promptCount']),'--chunk-size',str(spec['chunkSize']),
                    '--decode-tokens',str(spec['outputCount']),'--repeats','1','--warmups','0']
        if request['teacherTokenIDs']:
            files['teacher.json']=request['teacherTokenIDs'];arguments+=['--teacher-tokens-file','@rank/teacher.json']
        config.update(model_directory=context['model'],artifact_aggregate_sha256=context['artifact'])
    arguments+=['--transport','loopback-test','--epoch',epoch,'--timeout-seconds',str(timeout)]
    config['arguments']=arguments
    return config
