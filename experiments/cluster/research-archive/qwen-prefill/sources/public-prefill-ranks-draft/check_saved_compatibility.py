"""CPU-only schema replay of explicitly pinned historical output, not execution."""
import argparse
import hashlib
import importlib
from pathlib import Path
import sys
import types
from unittest.mock import patch


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cluster',type=Path,required=True)
    parser.add_argument('--baseline',type=Path,required=True)
    parser.add_argument('--baseline-sha256',required=True)
    parser.add_argument('--run',nargs=3,action='append',required=True,metavar=('DIRECTORY','RECEIPT_SHA','PROVENANCE_SHA'))
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();draft=Path(__file__).resolve().parent
    if args.output.exists():raise ValueError('Replay output must be new')
    package=types.ModuleType('_prefill_replay');package.__path__=[str(draft/'runtime/stage_checks'),str(args.cluster/'runtime/stage_checks')]
    sys.modules[package.__name__]=package
    modules={name:importlib.import_module(package.__name__+'.'+name) for name in ('common','prefill','prefill_baseline','request')}
    common=modules['common'];require=common.require
    files=[]
    def read(path,pin=None,maximum=64*1024**2):
        with path.open('rb') as stream:raw=stream.read(maximum+1)
        require(0<len(raw)<=maximum,'Saved metadata/output exceeds byte bound')
        actual=common.digest(raw)
        if pin is not None:require(actual==common.sha(pin),'Saved evidence pin differs')
        files.append(dict(path=str(path),sha256=actual,size_bytes=len(raw)))
        return raw
    results=[]
    with patch('subprocess.Popen',side_effect=AssertionError('No process creation')), \
         patch('subprocess.run',side_effect=AssertionError('No system/native call')), \
         patch('socket.socket',side_effect=AssertionError('No socket creation')):
        baseline_raw=read(args.baseline,args.baseline_sha256)
        baseline_rows=[common.parse(line) for line in baseline_raw.splitlines() if line.strip()]
        baselines=[row['baseline'] for row in baseline_rows if row.get('kind')=='qwen_layer_stage_baseline_checkpoint']
        require(len(baselines)==1,'One independently pinned baseline required')
        baseline_pin=baselines[0]['fingerprint']
        for directory,receipt_pin,provenance_pin in args.run:
            run=Path(directory);receipt=common.parse(read(run/'receipt.json',receipt_pin))
            provenance=common.parse(read(run/'independent-provenance-audit.json',provenance_pin))
            require(provenance['status']=='passed' and provenance['launcherReceiptSHA256']==receipt_pin,
                    'Historical completed provenance receipt differs')
            require(receipt['passed'] is True,'Historical launcher did not complete')
            config=common.parse(read(run/'remote-metadata/before-config.json',receipt['configuration_sha256'],1024**2))
            prompt_item=next(item for item in receipt['inputs']['files'] if item['path']=='inputs/prompt.json')
            prompt=common.parse(read(run/'inputs/prompt.json',prompt_item['sha256'],65536))
            common.exact(prompt,receipt['inputs']['prompt'],'Saved prompt and retained receipt differ')
            require(len(prompt)==65 and receipt['inputs']['teacher']==[],'Wrong historical fixed workload')
            text=config.get('text_config',config);epoch=receipt['epoch']
            recorded,fingerprint=modules['request'].make_request(epoch,prompt,[],32,text['vocab_size'])
            context=dict(mode='prefill-ranks',artifact=receipt['artifact_aggregate_sha256'],configuration=config,text=text,
                configuration_sha256=receipt['configuration_sha256'],vocabulary=text['vocab_size'],request=recorded,
                request_fingerprint=fingerprint,baseline_sha256=args.baseline_sha256,
                stage_prefill_policy=receipt['stage_prefill_policy'],stage_logits_dtype=receipt['stage_logits_dtype'])
            context['baseline_admission']=modules['prefill_baseline'].admit(baseline_raw,context,baseline_pin,context['stage_logits_dtype'])
            readers=[];finals=[]
            for rank in (0,1):
                item=next(item for item in receipt['rank_files'] if item['path']==f'rank-{rank}/stdout.jsonl')
                rows=[common.parse(line) for line in read(run/item['path'],item['sha256']).splitlines()]
                require(len(rows)==2,'Historical rank must have ready and terminal')
                require([r['kind'] for r in rows]==[modules['prefill'].READY,modules['prefill'].TERMINAL],'Wrong ready/final order')
                for row in rows:modules['prefill'].validate(row,rank,epoch,context)
                modules['prefill'].transition(*rows,context);readers.append(types.SimpleNamespace(rows=rows));finals.append(rows[1])
            modules['prefill'].progress(readers,context)
            result=modules['prefill'].pair(finals,context)
            results.append(dict(run=str(run),epoch=epoch,policy=context['stage_prefill_policy'],rank_records=4,
                baseline_admission=context['baseline_admission'],validation=result))
    sources=sorted({Path(module.__file__) for name,module in sys.modules.items() if name.startswith(package.__name__+'.')})
    result=dict(kind='public_prefill_ranks_saved_schema_compatibility',schema_version=1,passed=True,cpu_only=True,
        historical_records_replayed=True,new_native_executions=0,model_payload_bytes_read=0,independent_numerical_audit_performed=False,
        prospective_native_qualification=False,baseline_evidence_sha256=baseline_pin,runs=results,evidence_files=files,
        validator_sources=[dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in sources],
        script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    args.output.write_bytes(common.canonical(result)+b'\n')
    print(common.canonical(dict(passed=True,runs=len(results),rank_records=sum(x['rank_records'] for x in results),
          output=str(args.output),sha256=common.digest(args.output.read_bytes()))).decode())


if __name__=='__main__':main()
