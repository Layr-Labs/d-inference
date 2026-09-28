"""Retain exact small inputs; delegate registered payload verification to runtime."""
import os
from pathlib import Path
import stat
from .common import digest,integer,parse,require,sha
from .request import make_request
from . import stage_ranges


def retain(path,destination,maximum,expected=None):
    with Path(path).open('rb') as stream:
        before=os.fstat(stream.fileno());require(stat.S_ISREG(before.st_mode),'Input must be a regular file')
        data=stream.read(maximum+1);after=os.fstat(stream.fileno())
    require(0<len(data)<=maximum,'Input is empty or exceeds its bound')
    require((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==
            (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns),'Input changed while retained')
    if expected is not None:require(digest(data)==sha(expected),'Input hash differs from explicit pin')
    destination.write_bytes(data);destination.chmod(0o400)
    return data


def prepare(args,output,epoch,artifacts):
    cut=stage_ranges.option(args.command,getattr(args,'stage_cut',None))
    if args.command=='p2p':return dict(mode='p2p')
    model=args.model_dir.expanduser().resolve(strict=True);sha(args.artifact_aggregate_sha256)
    folder=output/'inputs';folder.mkdir(mode=0o700)
    raw_config=retain(model/'config.json',folder/'config.json',1024**2)
    raw_manifest=retain(model/'manifest.json',folder/'manifest.json',4*1024**2)
    manifest=parse(raw_manifest);configuration=parse(raw_config)
    require(manifest['aggregate_sha256']==args.artifact_aggregate_sha256,'Manifest artifact pin differs')
    integer(manifest['total_size_bytes'],1,8*1024**3)
    configuration_hash=digest(raw_config)
    entries=[entry for entry in manifest['files'] if entry.get('path')=='config.json']
    require(len(entries)==1 and entries[0]['sha256']==configuration_hash,'Retained configuration is not pinned by manifest')
    artifacts.verify_model(model,args.artifact_aggregate_sha256)
    require(digest((model/'manifest.json').read_bytes())==digest(raw_manifest),'Manifest changed during verification')
    text=configuration.get('text_config',configuration)
    require(configuration.get('model_type')in('qwen3_5','qwen3_5_text'),'Only the native dense Qwen constructor is supported')
    for key in ('num_experts','num_experts_per_tok','moe_intermediate_size','shared_expert_intermediate_size'):
        require(key not in text or type(text[key])is int and text[key]==0,'MoE metadata is unsupported')
    bounds={'num_hidden_layers':128,'full_attention_interval':128,'hidden_size':8192,'vocab_size':262144,
            'num_key_value_heads':128,'head_dim':512,'linear_num_key_heads':128,'linear_num_value_heads':128,
            'linear_key_head_dim':512,'linear_value_head_dim':512,'linear_conv_kernel_dim':16,
            'max_position_embeddings':1048576}
    for key,bound in bounds.items():integer(text[key],1,bound)
    stage_ranges.ranges(text,cut)
    # Native preflight remains authority on all quantization/topology/shape keys.
    prompt=parse(retain(args.tokens_file,folder/'tokens.json',65536,args.tokens_sha256))
    require(isinstance(prompt,list),'Tokens must be an integer JSON array')
    teacher=[]
    if args.teacher_tokens_file is not None:
        teacher=parse(retain(args.teacher_tokens_file,folder/'teacher.json',65536,args.teacher_tokens_sha256))
        require(isinstance(teacher,list) and 1<=len(teacher)<=3,'A teacher file must contain1–3 IDs; omit it for one output')
    else:require(args.teacher_tokens_sha256 is None,'Teacher hash requires its file')
    request,fingerprint=make_request(epoch,prompt,teacher,args.chunk_size,text['vocab_size'])
    require(len(prompt)+len(teacher)+1<=min(text['max_position_embeddings'],32768),'Request exceeds native context admission')
    context=dict(mode=args.command,model=str(model),artifact=args.artifact_aggregate_sha256,
        configuration=configuration,text=text,configuration_sha256=configuration_hash,
        manifest_sha256=digest(raw_manifest),vocabulary=text['vocab_size'],request=request,
        request_fingerprint=fingerprint)
    if cut is not None:context['stage_cut']=cut
    if args.baseline_jsonl is not None:
        require(args.baseline_sha256 is not None,'Baseline comparison requires an explicit SHA256 pin')
        retain(args.baseline_jsonl,folder/'baseline.jsonl',64*1024**2,args.baseline_sha256)
        context['baseline_sha256']=args.baseline_sha256
    else:require(args.baseline_sha256 is None,'Baseline pin requires its file')
    if args.command=='prefill-ranks':
        from . import prefill,prefill_baseline
        prefill.validate_options(args.stage_prefill_policy,args.stage_logits_dtype)
        require(len(prompt)==65 and args.chunk_size==32 and not teacher,'Prefill launcher requires65/32/1 and no teacher')
        require('baseline_sha256' in context,'Prefill requires a pinned baseline file')
        context.update(stage_prefill_policy=args.stage_prefill_policy,stage_logits_dtype=args.stage_logits_dtype)
        context['baseline_admission']=prefill_baseline.admit((folder/'baseline.jsonl').read_bytes(),context,
            args.baseline_evidence_sha256,args.stage_logits_dtype)
    return context


def verify(context,output,artifacts):
    if context['mode']=='p2p':return
    model=Path(context['model'])
    artifacts.verify_model(model,context['artifact'])
    require(digest((model/'config.json').read_bytes())==context['configuration_sha256'],'Model configuration changed')
    require(digest((model/'manifest.json').read_bytes())==context['manifest_sha256'],'Model manifest changed')
