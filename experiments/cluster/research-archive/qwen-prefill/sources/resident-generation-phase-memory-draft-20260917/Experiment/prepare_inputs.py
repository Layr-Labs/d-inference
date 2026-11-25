"""Root-owned small-file preparation only. No child, source materialization or model IO."""
from pathlib import Path
import argparse, hashlib, json, os
BASE=Path(__file__).resolve().parent
ROOT=BASE.parent.parent
OLD=ROOT/'resident-generation-phase-physical-draft-20260916'
REFERENCE=ROOT/'qwen27b-8k-full-reference-20260915/package/example-job.json'
REMOTE='/Users/developer/DarkbloomDev/qwen27b-phase-memory-c256'
REFERENCE_REMOTE='/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/supervisor-phase-memory-c256-20260917'
REFERENCE_RUN='/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/runs/phase-memory-c256-1'
REQUEST='72a2b195-bb12-4da5-ae3a-986352fc2dc4'
EPOCHS={'serial':'c1e3cbfe-ceac-4f7f-83cc-6a4a2e402dc8','lookahead':'c0c64d4a-e22e-46a8-bd67-97a2a3e5565c'}
PROMPT='ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'

def canonical(x):return (json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):
    with p.open('xb') as f:f.write(v if isinstance(v,bytes) else canonical(v))

def expected_packet():
    job=json.loads(REFERENCE.read_bytes())
    job.update(request_id=REQUEST,chunk_size=256,prompt_file=REFERENCE_REMOTE+'/prompt.ids.json',run_dir=REFERENCE_RUN)
    request=json.loads((OLD/'inputs/request.json').read_bytes());request.update(requestID=REQUEST,chunkSize=256)
    return job,request

def prepare(output):
    # Frozen authority consists only of small metadata/source/prompt, never weights.
    for row in json.loads((BASE/'input-pins.json').read_bytes()):
        p=Path(row['path'])
        if p.stat().st_size!=row['bytes'] or sha(p)!=row['sha256']:raise ValueError('Experiment source input changed')
    raw=(OLD/'inputs/prompt.ids.json').read_bytes();tokens=json.loads(raw)
    if hashlib.sha256(raw).hexdigest()!=PROMPT or len(tokens)!=8192 or any(type(x) is not int or not 0<=x<248320 for x in tokens):
        raise ValueError('Exact diagnostic 8K token packet required')
    job,request=expected_packet()
    if (job['registered_model'],job['stage_cut'],job['prompt_count'],job['output_count'],job['native_seconds'],job['parent_seconds'],job['stop_token_ids'])!=('registered_qwen38_27b',16,8192,128,300,315,[]):
        raise ValueError('Reference inherited authority changed')
    if not output.is_absolute() or output.parent.resolve()!=output.parent:raise ValueError('Canonical fresh parent required')
    output.mkdir(mode=0o700);save(output/'prompt.ids.json',raw);save(output/'reference-job.json',job);save(output/'request.json',request)
    save(output/'case-plan.json',dict(schema='qwen27b_phase_memory_c256_plan_v1',requestID=REQUEST,
        promptSHA256=PROMPT,tokenization='retained diagnostic token IDs; no new tokenizer or performance-workload claim',
        referenceJobSHA256=sha(output/'reference-job.json'),requestSHA256=sha(output/'request.json'),
        nativeSeconds=300,parentSeconds=315,requestSeconds=120,startupSeconds=90,
        ordinaryReferenceRequiredBeforeCandidates=True,expectedTokenIDs=None,newNativeBinarySHA256=None,
        cases=[dict(name=name,prefillPolicy=policy,membershipEpoch=EPOCHS[name],remoteRoot=REMOTE+'-'+name+'-20260917',
            promptCount=8192,chunkSize=256,outputCount=128,stageCut=16,mtp=False,stopTokenIDs=[])
            for name,policy in [('serial','serial'),('lookahead','oneChunkLookahead')]],
        noCompilerOrModelOrRemoteExecuted=True))
    return dict(output=str(output),referenceJobSHA256=sha(output/'reference-job.json'),promptSHA256=PROMPT)
if __name__=='__main__':
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    os.umask(0o077);print(json.dumps(prepare(a.output)))
