#!/usr/bin/env python3
"""Apply the prospectively frozen CPU oracle to an explicitly completed saved run."""
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import time
import traceback

ROOT=Path('/Users/developer/DarkbloomDev/cluster-research')
PINS={
    'qwen_layer_stage_prefill_rank_audit.py':'c3a0fcda8f4adddbe9dba7aa8e8ebd5b98de2d99f2f207e38551eccb636a5cb7',
    'test_qwen_layer_stage_prefill_rank_audit.py':'e62199f55dadcebf38ce71015ee2378903ee527d4f79d88c8d933935e1d10191',
    'qwen-layer-stage-prefill-rank-cpu-validator-tests-20260914.json':'3ba6586b4c2c06088e81a3d08910dbe3796629d27efa7a2ccbc006dbb4eb7972',
    'qwen_layer_stage_prefill_audit.py':'4bc20dfff992f6c7c8085a8f60bb565b34d883e6a9578e79db8c8ef963bc494c',
    'qwen_layer_stage_recorded_audit.py':'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4',
    'qwen-layer-stage-real9b-expected-20260913.json':'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99',
    'runs/qwen-layer-stage-prefill-peer24-20260914/native/stdout.jsonl':'10971a2556dbbfecf6557ba67375646a035483b4c3cbe937a67b7f22adfb8597',
    'qwen-layer-stage-prefill-peer24-independent-cpu-comparison-20260914.json':'a85b412eb9065276ba55f42d8e0f61678fb2f5efde45dc4753326e2f62d5ac73',
}


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert len(sys.argv)==3,'Arguments: completed-run-directory expected-launcher-receipt-SHA256'
    run=Path(sys.argv[1]); expected_receipt_sha=sys.argv[2]
    assert run.parent==ROOT/'runs' and re.fullmatch(r'qwen-layer-stage-prefill-ranks-(serial|lookahead)-peer24-20260914',run.name)
    assert re.fullmatch('[0-9a-f]{64}',expected_receipt_sha)
    name=run.name.removesuffix('-20260914')+'-independent-cpu-comparison-20260914'
    output=ROOT/(name+'.json');log=ROOT/(name+'.log')
    assert not output.exists() and not log.exists(),'Preserve all completed audit evidence'
    pins={ROOT/name:value for name,value in PINS.items()};pins[run/'receipt.json']=expected_receipt_sha
    for path,value in pins.items():assert digest(path)==value,'Pinned evidence changed: '+str(path)
    launch=json.loads((run/'receipt.json').read_text())
    assert launch['passed'] is True and launch['cohort']['passed'] is True
    assert launch['cohort']['exit_codes']==[0,0] and launch['cohort']['validation']['records_per_rank']==[2,2]
    assert launch['cohort']['error'] is None and launch['cohort']['cancellation_reason'] is None
    assert launch['stage_prefill_policy']==('serial_v1' if '-serial-' in run.name else 'prompt_lookahead_one_v1')
    stdout=[]
    for rank in range(2):
        relative=f'rank-{rank}/stdout.jsonl';entry=next(x for x in launch['rank_files'] if x['path']==relative)
        path=run/relative
        assert path.stat().st_size==entry['size_bytes'] and path.stat().st_size<=4*1024**2
        assert digest(path)==entry['sha256']
        pins[path]=entry['sha256'];stdout.append(path)
    helper=ROOT/'qwen_layer_stage_prefill_rank_audit.py'
    spec=importlib.util.spec_from_file_location('frozen_actual_prefill_rank_oracle',helper)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    started=datetime.datetime.now(datetime.timezone.utc).isoformat();tick=time.monotonic()
    result,error,code=None,None,0
    try:
        result=module.validate(stdout,ROOT/'runs/qwen-layer-stage-prefill-peer24-20260914/native/stdout.jsonl',
            ROOT/'qwen-layer-stage-real9b-expected-20260913.json',launch['epoch'],launch['stage_prefill_policy'])
    except Exception:error,code=traceback.format_exc(),1
    elapsed=time.monotonic()-tick
    for path,value in pins.items():assert digest(path)==value,'Evidence changed during audit: '+str(path)
    with log.open('x') as stream:
        stream.write('Frozen prospective CPU oracle on completed '+run.name+'.\n')
        stream.write('Current-rank final logit evidence is digest agreement only; no raw candidate values/native private-byte comparison.\n')
        stream.write(error if error else json.dumps(result,indent=2,sort_keys=True,allow_nan=False));stream.write('\n')
    receipt=dict(schemaVersion=1,status='passed' if code==0 else 'failed',cpuOnly=True,exitCode=code,
        startedAtUTC=started,wallSeconds=elapsed,auditScriptSHA256=digest(Path(__file__)),helperSHA256=PINS[helper.name],
        policy=launch['stage_prefill_policy'],epoch=launch['epoch'],launcherReportedExitCodes=launch['cohort']['exit_codes'],
        launcherReceiptSHA256=expected_receipt_sha,pinnedInputs=[dict(path=str(path),sha256=value,byteCount=path.stat().st_size) for path,value in pins.items()],
        logPath=str(log),logSHA256=digest(log),comparison=result,error=error,actualRankModeNativeEvidenceChecked=True,
        helperFrozenBeforeCandidateOutputRead=True,newNativeExecutions=0,newSSHCalls=0,newBuilds=0,newProcessInventoryCalls=0,
        newModelPayloadReads=0,rewrittenPriorArtifacts=0,
        provenanceScope='Exact saved stdout and completed launcher receipt plus frozen helpers/reference metadata; root separately owns binary/source/model/resource/remote-process provenance.')
    with output.open('x') as stream:json.dump(receipt,stream,indent=2,sort_keys=True,allow_nan=False);stream.write('\n')
    print(json.dumps(dict(status=receipt['status'],exitCode=code,policy=launch['stage_prefill_policy'],receiptPath=str(output),
        receiptSHA256=digest(output),logSHA256=digest(log),auditScriptSHA256=digest(Path(__file__)),
        actionCounts=result['actionCounts'] if result else None,
        diagnosticTiming=result['timing'] if result else None),sort_keys=True))
    if error:print(error)
    return code


if __name__=='__main__':raise SystemExit(main())
