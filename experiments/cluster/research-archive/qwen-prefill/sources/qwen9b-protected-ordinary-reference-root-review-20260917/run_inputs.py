import hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'qwen9b-protected-ordinary-reference-draft-20260917'
EXPECTED='4d19e5d7a6c7c21417e4233692ec89b9126cec7ac641c440b019e22def438938'
sys.path.insert(0,str(SOURCE))
from check_process import run_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 assert sha(SOURCE/'manifest.json')==EXPECTED
 for r in json.loads((SOURCE/'manifest.json').read_bytes())['files']:
  p=SOURCE/r['path'];assert p.stat().st_size==r['bytes'] and sha(p)==r['sha256']
verify();out=ROOT/'inputs-1';out.mkdir(mode=0o700);receipt=dict(status='failed',manifestSHA256=EXPECTED,steps=[],modelExecuted=False,remoteExecuted=False)
try:
 receipt['steps'].append(run_owned(['/usr/bin/env','TMPDIR=/private/tmp/','/usr/bin/python3','-B',str(SOURCE/'test_reference_binding.py')],out,'cpu',30))
 raw=(out/'cpu.stderr').read_text();assert 'Ran 6 tests' in raw and raw.rstrip().endswith('OK');verify()
 receipt['steps'].append(run_owned(['/Users/developer/.local/share/uv/tools/vllm-mlx/bin/python','-B',str(SOURCE/'prepare_prompt.py'),'--model-directory','/Users/developer/DarkbloomDev/models/Qwen3.5-9B','--output',str(out/'prompt')],out,'tokenizer',30));verify()
 receipt['steps'].append(run_owned(['/usr/bin/python3','-B',str(SOURCE/'prepare_job.py'),'--prompt-directory',str(out/'prompt'),'--output',str(out/'bound')],out,'bind',10));verify()
 receipt.update(status='passed',bindingSHA256=sha(out/'bound/binding.json'),promptSHA256=sha(out/'prompt/prompt.ids.json'),promptReceiptSHA256=sha(out/'prompt/prompt-receipt.json'),memberRequestSHA256=sha(out/'bound/member-request.json'))
finally:
 with (out/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(receipt))
