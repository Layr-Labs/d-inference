"""Recheck the separately reviewed ordinary C256 reference before reading candidate outputs."""
from pathlib import Path
import importlib,json,sys
from physical_evidence import read,parse,require,pin,digest
from prepare_inputs import REQUEST
ROOT=Path(__file__).resolve().parent.parent.parent

def raw(x):return (json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode()

def reference(inputs,returned,review,expected_review_sha):
    review_raw=read(review,1024**2);require(digest(review_raw)==expected_review_sha,'Root reference review changed')
    r=parse(review_raw)
    for key in ['passed','allRawPressureNormalZeroSwapAC','nativeLeaderReaped','ownedGroupFenceComplete','sourceInputsUnchanged']:
        require(r.get(key) is True,'Independent reference review is incomplete: '+key)
    require(r['nativeExitCodes']==[0] and r['activeProcessesAtCollection']==[] and r['journalBytesAtCollection']==0,
        'Reference did not retire cleanly')
    require(r['minimumActualFreeBytes']>=6*1024**3 and r['throughputMeasurementValid'] is False,'Reference resource/scope differs')
    for name,row in r['returnedFiles'].items():
        require(not Path(name).is_absolute() and '..' not in Path(name).parts,'Unsafe returned member')
        value=read(returned/name,32*1024**2)
        require(len(value)==row['bytes'] and digest(value)==row['sha256'],'Reviewed reference bytes changed')
    job=parse(read(inputs/'reference-job.json'));prompt=read(inputs/'prompt.ids.json',65536)
    require((job['request_id'],job['registered_model'],job['stage_cut'],job['prompt_count'],job['chunk_size'],job['output_count'],job['stop_token_ids'],job['native_seconds'],job['parent_seconds'])==(REQUEST,'registered_qwen38_27b',16,8192,256,128,[],300,315),'Exact C256 reference job required')
    require(set(r['returnedFiles'])=={'job.json','native/worker-0.stderr','native/worker-0.stdin','native/worker-0.stdout','owner.json','prompt.json','resources.jsonl','terminal.json'},'Exact full-reference collected closure required')
    require(read(returned/'job.json')==raw(job) and read(returned/'prompt.json',65536)==prompt,'Wrong C256 reference input')
    value=read(returned/'native/worker-0.stdout',32*1024**2)
    require(digest(value)==r['referenceSHA256'] and value.endswith(b'\n') and len(value.splitlines())==2,'Reference two-record output changed')
    require(read(returned/'native/worker-0.stderr')==b'','Reference stderr is not empty')
    sys.path.insert(0,str(ROOT/'qwen27b-8k-full-reference-20260915/package'))
    contract=importlib.import_module('reference_contract')
    expected=contract.expected_identity(job,parse(prompt));a,b=value.splitlines()
    admitted=contract.admitted(a,expected)
    accepted=contract.report(b,expected,admitted,r['nativePID'],Path(job['deployment']))
    sys.path.pop(0)
    require(admitted['planSHA256']=='8e1408f4f044b0fa6f97ae9b997d575797fe1d22036ddb68409e2aeb349949ed','Reference Plan differs')
    execution=accepted['execution']
    require(execution['completedFrames']==159 and execution['committedTokens']==8319 and execution['finishReason']=='length'
        and len(execution['selectedTokenIDs'])==128,'C256 reference not complete')
    return execution['selectedTokenIDs'],dict(review=pin(review),stdout=pin(returned/'native/worker-0.stdout'),
        terminal=pin(returned/'terminal.json'),job=pin(returned/'job.json'),externalPhysicalReviewRequired=True)

