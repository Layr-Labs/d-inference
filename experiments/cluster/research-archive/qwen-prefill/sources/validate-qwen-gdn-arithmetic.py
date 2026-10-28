#!/usr/bin/env python3
"""Root-run four-call GDN arithmetic diagnostic. Agent preparation never launches native."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import signal
import sys
sys.dont_write_bytecode=True
import qwen9_local_tp_support as supervision
from qwen9_local_tp_support import previous,preflight as original_preflight,bounded_launch,process_table
from qwen_gdn_input_audit import projection_oracle,verify_real_weight_bytes,capture,metrics,verify_native_differences
from qwen_gdn_arithmetic_audit import arithmetic_oracle,verify_real_arithmetic_weight_bytes

require,sha,read,write,now=previous.require,previous.sha,previous.read_json,previous.write_json,previous.now
REPO=previous.REPO;CLUSTER=previous.CLUSTER;RELEASE=previous.RELEASE;MODEL=previous.MODEL
HERE=Path(__file__).resolve().parent
AGGREGATE=previous.AGGREGATE
CONFIG='c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
PRIOR=HERE/'runs/qwen9-output-boundaries-20260913'
PRIOR_RECEIPT='0afffd9b1863f785f4f3880f71c21305177f36cb825e29e506983ff0f745cfc1'
INPUT_SHA='4c1f00887775d26c29e398bc54e2b37501614599455df2f3b83c5544608b3612'
PRIOR_GDN=HERE/'runs/qwen-gdn-input-20260913'
PRIOR_GDN_AUDIT_SHA='7e5e736f060b49d71d65cbabcf4ab32415a1fa0750e5dc43634a949fa4abee1a'
HELPERS={'qwen9_local_tp_support.py':'39889fec35b3f95da5a9e4d38e24cc3503e18fe876231ea8446a831474798ecb','validate-qwen9-output-boundaries.py':'80bba4f397a236e347c68c250d7a2625955189dedd259f21a926a0656a0b5f0a'}



# Explicit reserve above the old measured-solo reference and its existing 1GiB
# safety margin. The same stricter estimate is used by monitored samples.
DIAGNOSTIC_RESERVE=1024*1024**2
DIAGNOSTIC_FUSED_BYTES=12352*(4096//8*4+2*(4096//64)*2)
DIAGNOSTIC_CAPTURE_F32_BYTES=(32*4096+248320+2*32*12352)*4
DIAGNOSTIC_KNOWN_EXTRA=12*DIAGNOSTIC_FUSED_BYTES+12*DIAGNOSTIC_CAPTURE_F32_BYTES+4*64*1024**2
require(DIAGNOSTIC_KNOWN_EXTRA<=DIAGNOSTIC_RESERVE,'Explicit diagnostic reserve is insufficient')


def preflight(partition,output):
    result=original_preflight(partition,output)
    result['prior_driver_required_headroom_bytes']=result['required_headroom_bytes']
    result['diagnostic_extra_reserve_bytes']=DIAGNOSTIC_RESERVE
    result['diagnostic_known_extra_accounting_bytes']=DIAGNOSTIC_KNOWN_EXTRA
    result['diagnostic_extra_formula']='12 full fused quantized triplets +12 copies of captured Float32 values +4*64MiB JSON buffers; rounded up to1GiB; sequential arithmetic variants, model/cache overhead still estimated'
    result['required_headroom_bytes']+=DIAGNOSTIC_RESERVE
    result['headroom_policy']+=' +1GiB explicit arithmetic projection/capture/JSON reserve'
    result['memory_passed']=result['estimated_reclaimable_bytes']>=result['required_headroom_bytes']
    result['passed']=result['memory_passed'] and result['descriptors_passed'] and result['disk_passed'] and not result['severe_pressure']
    return result


supervision.preflight=preflight

def synthetic_text(dtype):
    # Exact tiny fixture configuration from archived SyntheticConfiguration.swift.
    return dict(model_type='qwen3_5_text',hidden_size=128,num_hidden_layers=4,intermediate_size=256,
        num_attention_heads=4,num_key_value_heads=2,head_dim=64,linear_num_key_heads=2,linear_num_value_heads=2,
        linear_key_head_dim=128,linear_value_head_dim=128,linear_conv_kernel_dim=4,full_attention_interval=2,
        vocab_size=512,tie_word_embeddings=False,max_position_embeddings=8192,mtp_num_hidden_layers=0,
        quantization=dict(bits=4,group_size=64,mode='affine'),cluster_fixture_dtype=dtype)


def one_row(values,vocab):
    require(isinstance(values,list) and len(values)==1 and len(values[0])==vocab,'Missing one full logit row')
    metrics(values[0],values[0]);return values[0]



def read_diagnostic(path):
    maximum=128*1024*1024
    with path.open('rb') as stream:data=stream.read(maximum+1)
    require(len(data)<=maximum,'Native diagnostic output exceeds128MiB')
    def closed(pairs):
        result={}
        for key,value in pairs:
            require(key not in result,'Duplicate native diagnostic field');result[key]=value
        return result
    records=[]
    for line in data.decode('utf-8').splitlines():
        if line.lstrip().startswith(('{','[')):
            records.append(json.loads(line,object_pairs_hook=closed,parse_int=lambda x:-0.0 if x=='-0' else int(x),parse_constant=lambda x:require(False,'Nonfinite diagnostic JSON')))
    require(len(records)==1 and isinstance(records[0],dict),'Expected one native diagnostic record')
    return records[0]

def diagnostic_identity(result,synthetic,dtype,prompt,config_sha):
    for key,value in dict(schemaVersion=1,kind='qwen_gdn_arithmetic_check',
        executionPath='cbv2-contiguous',promptTokenIDs=prompt,chunkSize=32,correctnessOnly=True,
        throughputMeasurementValid=False,modelFamily='qwen35',syntheticProfile='tiny' if synthetic else 'none',
        seed=7,captureCalls=1,captureAfterNormalStateCommit=True,fusionEligibilityValidatedBeforeAndAfter=True,
        syntheticWeights=synthetic,mtpEnabled=False,bf16ConversionEnabled=not synthetic).items():
        require(type(result.get(key)) is type(value) and result[key]==value,'Diagnostic identity differs: '+key)
    require(result['promptSHA256']==hashlib.sha256(previous.canonical(prompt)).hexdigest(),'Prompt identity differs')
    require(result['normalizedInput']['dtype']==dtype,'Normalized input dtype differs')
    if synthetic:
        config_sha=hashlib.sha256(json.dumps(synthetic_text(dtype),sort_keys=True,separators=(',',':')).encode()).hexdigest()
        require(result.get('verifiedDiagnosticLoad') is None,'Synthetic diagnostic must not claim verified artifact loading')
    require(result['configurationSHA256']==config_sha,'Diagnostic config differs')
    require(result['inputNormPath']==('' if synthetic else 'language_model.')+'model.layers.0.input_layernorm','Unexpected normalized input source')
    require(type(result['inputNormEpsilon']) in (int,float) and 0<result['inputNormEpsilon']<.01,'Invalid input norm epsilon')


def native_matches_prior(result,name):
    require(sha(PRIOR_GDN/'independent-cpu-audit.json')==PRIOR_GDN_AUDIT_SHA,'Previous input audit differs')
    old=read_diagnostic(PRIOR_GDN/(name+'-launcher')/'stdout.txt')
    # Ignore timestamps and new variant fields; require all actual inputs and
    # untouched full/rank native outputs to reproduce archived original bytes.
    for field in ('normalizedInput','firstLogits','sourceProjections','full','ranks'):
        require(result[field]==old[field],'Original native reference changed: '+field)
    return dict(all_native_inputs_outputs_exact=True,prior_raw_sha256=sha(PRIOR_GDN/(name+'-launcher')/'stdout.txt'),prior_audit_sha256=PRIOR_GDN_AUDIT_SHA)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    parser.add_argument('--expected-native-sha256',required=True)
    parser.add_argument('--prepare-only',action='store_true')
    args=parser.parse_args();out=args.output.resolve()
    require(not out.exists() and not out.is_relative_to(REPO) and not out.is_relative_to(MODEL),'Output must be new/outside repo/model')
    require(len(args.expected_native_sha256)==64 and all(c in '0123456789abcdef' for c in args.expected_native_sha256),'Expected binary SHA required')
    require(sha(RELEASE/'cluster-inference')==args.expected_native_sha256,'Build differs from root pin')
    require(sha(PRIOR/'receipt.json')==PRIOR_RECEIPT,'Frozen input origin differs')
    prompt96=read(PRIOR/'prompt-96.json')
    require(len(prompt96)==96 and hashlib.sha256(previous.canonical(prompt96)).hexdigest()==INPUT_SHA,'Frozen input differs')
    prompt=prompt96[:32];synthetic_prompt=list(range(3,35))
    require(sha(MODEL/'config.json')==CONFIG,'Registered config differs')
    probes=[p for p in process_table().values() if '/cluster-inference ' in p['command'] or '/rank_worker.py ' in p['command']]
    require(not probes,'Existing native/supervisor probe: refuse concurrent GPU work')
    out.mkdir(mode=0o700,parents=True)
    receipt=dict(schema_version=1,status='preparing',started_at=now(),native_calls=[],planned_native_calls=4,
        expected_native_sha256=args.expected_native_sha256,expected_aggregate_sha256=AGGREGATE,
        correctness_capture_only=True,throughput_qualification=False,numerical_qualification=False,
        model_quality_qualification=False,physical_two_machine_execution=False,
        input_origin_receipt_sha256=PRIOR_RECEIPT,frozen_96_prompt_sha256=INPUT_SHA,
        limitations=['One unsharded unchanged model forward captures first-layer input; native/FP32/padded QMM probes follow in that same process.',
            'Arithmetic variants are diagnostic; partition agreement alone is not equivalence to native or a whole-model fix.',
            'CPU audit verifies raw component/weight selections, not an emulation of Metal matmul rounding.',
            'Single fixed 32-token prose prefix, one output, zero warmups; no throughput qualification.',
            'Pressure/headroom estimates and RSS samples are not hard whole-process memory caps.'])
    save=lambda:write(out/'receipt.json',receipt);save()
    try:
        files=['validate-qwen-gdn-arithmetic.py','qwen_gdn_arithmetic_audit.py','test_qwen_gdn_arithmetic_audit.py','qwen_gdn_input_audit.py','test_qwen_gdn_input_audit.py','qwen9_local_tp_support.py','validate-qwen9-output-boundaries.py']
        receipt['driver_files_sha256']={}
        for name in files:
            if HELPERS.get(name):require(sha(HERE/name)==HELPERS[name],'Shared helper differs')
            shutil.copy2(HERE/name,out/name);receipt['driver_files_sha256'][name]=sha(out/name)
        sources,deps=previous.snapshot_sources(out);previous.verify_sources(out,sources)
        receipt.update(source_manifest_sha256=sha(out/'source-manifest.json'),dependencies=deps)
        sys.path.insert(0,str(out/'source/experiments/cluster'))
        from runtime.artifacts import verify_model,verify_files
        from runtime.bundle import snapshot
        from runtime.configuration import validate
        from runtime.reports import read_report,reports
        receipt['bundle_manifest_sha256']=snapshot(RELEASE,out/'bundle')
        bundle=read(out/'bundle/bundle.json')['files'];receipt['bundle_files']=verify_files(out/'bundle',bundle)
        require(receipt['bundle_files']['cluster-inference']==args.expected_native_sha256,'Archived build differs')
        receipt['model_before_aggregate_sha256']=verify_model(MODEL,AGGREGATE)
        shutil.copy2(MODEL/'manifest.json',out/'model-manifest.json');receipt['model_manifest_sha256']=sha(out/'model-manifest.json')
        for name,values in [('prompt-32.json',prompt),('synthetic-prompt-32.json',synthetic_prompt)]:write(out/name,values)
        shutil.copy2(PRIOR/'prompt-96.json',out/'prompt-96.json')
        shutil.copy2(PRIOR/'source-text.txt',out/'source-text.txt')
        receipt['input_files_sha256']={name:sha(out/name) for name in ['prompt-32.json','synthetic-prompt-32.json','prompt-96.json','source-text.txt']}
        text=read(MODEL/'config.json')['text_config'];env=previous.environment()
        work=dict(synthetic=False,prompt_ids=prompt,prompt_tokens=32,chunk_size=32,decode_tokens=1,
            repeats=1,warmups=0,seed=7,execution_path='cbv2-contiguous',attention_output_precision='native',
            ffn_output_precision='native',ffn_branch_precision='native')
        baseline_spec=validate(dict(schema_version=1,backend='solo',partition='ffn',
            ranks=[dict(location='local',model_directory=str(MODEL))],artifact_aggregate_sha256=AGGREGATE,
            timeout_seconds=170,capture_logits=True,workload=work))
        write(out/'real9b-solo.spec.json',baseline_spec)
        common=['--prompt-tokens','32','--chunk-size','32','--decode-tokens','1','--repeats','1','--warmups','0',
            '--seed','7','--timeout-seconds','170','--execution-path','cbv2-contiguous',
            '--attention-output-precision','native','--ffn-output-precision','native','--ffn-branch-precision','native']
        calls=[]
        for dtype in ('float32','bfloat16'):
            name='tiny-'+dtype
            command=[str(out/'bundle/cluster-inference'),'--mode','qwen-gdn-arithmetic-check','--synthetic',
                '--synthetic-profile','tiny','--synthetic-dtype',dtype,'--tokens-file',str(out/'synthetic-prompt-32.json'),*common]
            calls.append((name,command,True,dtype))
        calls.append(('real9b-solo',[sys.executable,str(out/'source/experiments/cluster/run_inference.py'),
            '--spec',str(out/'real9b-solo.spec.json'),'--bundle',str(out/'bundle'),'--output',str(out/'real9b-solo')],False,'bfloat16'))
        calls.append(('real9b-gdn',[str(out/'bundle/cluster-inference'),'--mode','qwen-gdn-arithmetic-check',
            '--model-dir',str(MODEL),'--artifact-aggregate-sha256',AGGREGATE,'--tokens-file',str(out/'prompt-32.json'),*common],False,'bfloat16'))
        receipt['planned_commands']=[dict(name=n,command=c) for n,c,_,_ in calls]
        receipt['preparation_preflight']=preflight('solo',out);require(receipt['preparation_preflight']['passed'],'Preparation memory/resource gate refused')
        receipt['status']='prepared_not_executed' if args.prepare_only else 'running';save()
        if args.prepare_only:
            print(json.dumps(dict(status=receipt['status'],output=str(out),native_calls=0)));return 0
        baseline=None;baseline_report=None
        for name,command,synthetic,dtype in calls:
            previous.verify_sources(out,sources)
            require(verify_files(out/'bundle',bundle)==receipt['bundle_files'],'Bundle changed')
            require(verify_model(MODEL,AGGREGATE)==AGGREGATE and sha(MODEL/'config.json')==CONFIG,'Artifact changed')
            entry=dict(name=name,status='preflight',preflight=preflight('solo',out),model_before_aggregate_sha256=AGGREGATE)
            receipt['native_calls'].append(entry);save();require(entry['preflight']['passed'],'Call resource admission refused')
            directory=out/name
            if name!='real9b-solo':directory.mkdir(mode=0o700)
            bounded_launch(command,directory,out/(name+'-launcher'),env,entry,save,'solo')
            entry['postflight']=preflight('solo',out)
            require(not entry['postflight']['severe_pressure'] and entry['postflight']['swap_used_bytes']-entry['preflight']['swap_used_bytes']<=1024**3,'Postflight pressure/swap gate failed')
            if name=='real9b-solo':
                run=read(directory/'run.json');require(run['spec']==baseline_spec and run['exit_codes']==[0]
                    and run['verified_execution'] is True and run['hardware_throughput_candidate'] is False,'Baseline execution differs')
                actual=reports(run['ranks'],baseline_spec);require(actual==run['reports'] and len(actual)==1,'Baseline raw report differs')
                baseline_report=actual[0];baseline=one_row(read(directory/'rank-0/logits.json'),text['vocab_size'])
                require(baseline_report['configurationSHA256']==CONFIG and baseline_report['runs'][0]['generatedTokens']==[baseline.index(max(baseline))],'Baseline identity/logits differ')
                entry.update(result=baseline_report,logits_sha256=sha(directory/'rank-0/logits.json'),run_sha256=sha(directory/'run.json'))
            else:
                result=read_diagnostic(out/(name+'-launcher')/'stdout.txt')
                diagnostic_identity(result,synthetic,dtype,synthetic_prompt if synthetic else prompt,None if synthetic else CONFIG)
                base_result=dict(result,kind='qwen_gdn_input_projection_check')
                entry['cpu_projection_oracle']=projection_oracle(base_result,synthetic_text(dtype) if synthetic else text)
                entry['cpu_arithmetic_oracle']=arithmetic_oracle(result,synthetic_text(dtype) if synthetic else text)
                entry['native_matches_prior']=native_matches_prior(result,name)
                verify_native_differences(result['componentDifferences'],entry['cpu_projection_oracle'])
                entry['result_sha256']=sha(out/(name+'-launcher')/'stdout.txt')
                if not synthetic:
                    load=result['verifiedDiagnosticLoad']
                    require(load==dict(schemaVersion=1,verifiedAggregateSHA256=AGGREGATE,configurationSHA256=CONFIG,
                        sourceModelTensorBytes=5038041600,loadedTensorBytes=5038041600,largestHostTensorBytes=508559360,
                        tensorCount=927,sourceTensorCount=927,parameterLayoutSHA256=result['parameterLayoutSHA256'],
                        bf16ConversionEnabled=True),'Verified diagnostic loading receipt differs')
                    entry['independent_source_byte_checks']=verify_real_weight_bytes(base_result,MODEL,text)
                    entry['independent_arithmetic_source_byte_checks']=verify_real_arithmetic_weight_bytes(result,MODEL,text)
                    require(result['parameterLayoutSHA256']==baseline_report['parameterLayoutSHA256'],'Diagnostic parameter layout differs')
                    row=capture(result['firstLogits']);comparison=metrics(baseline,row)
                    require(comparison['exact'],'Capture changed matched32 baseline first logits')
                    receipt['capture_versus_matching_solo']=dict(**comparison,prior96_not_used_as_control=True)
                entry['diagnostic_summary']={k:v for k,v in result.items() if k not in ('normalizedInput','firstLogits','full','ranks','arithmeticVariants')}
            previous.verify_sources(out,sources)
            entry.update(status='validated',model_after_aggregate_sha256=verify_model(MODEL,AGGREGATE))
            entry['evidence_sha256']={str(p.relative_to(out)):sha(p) for root in (directory,out/(name+'-launcher')) for p in sorted(root.rglob('*')) if p.is_file()}
            save();print(name,'execution and CPU evidence checks passed',flush=True)
        require(len(receipt['native_calls'])==4,'Wrong call budget')
        receipt.update(status='completed',finished_at=now(),model_final_aggregate_sha256=verify_model(MODEL,AGGREGATE),
            all_execution_and_identity_checks_passed=True,bundle_final_files=verify_files(out/'bundle',bundle))
        save();print(json.dumps(dict(status='completed',native_calls=4,output=str(out),throughput_qualification=False)));return 0
    except BaseException as error:
        receipt.update(status='failed',finished_at=now(),error=f'{type(error).__name__}: {error}');save();raise


def interrupted(signum,frame):raise KeyboardInterrupt('Diagnostic interrupted by signal '+str(signum))


if __name__=='__main__':
    for signum in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT):signal.signal(signum,interrupted)
    sys.exit(main())
