"""Bounded synthetic native token selection and dtype disagreement checks."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

CLUSTER = Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster')
sys.path.insert(0, str(CLUSTER))
from runtime.configuration import loopback_addresses

binary = CLUSTER/'inference/.build/arm64-apple-macosx/release/cluster-inference'
root = Path(sys.argv[1]); root.mkdir(mode=0o700)
results = []
for label in ['token-selection', 'mixed-dtype-rejection']:
    output = root/label; output.mkdir(mode=0o700)
    hosts = output/'hosts.json'; hosts.write_text(json.dumps(loopback_addresses()))
    children, handles, codes = [], [], []
    try:
        for rank in range(2):
            env = {k:v for k,v in os.environ.items() if not k.startswith(('MLX_','JACCL_','DARKBLOOM_'))}
            env.update(MLX_RANK=str(rank), MLX_HOSTFILE=str(hosts))
            args = [str(binary),'--mode', 'token-selection-check' if label == 'token-selection' else 'ffn-tp',
                    '--synthetic','--transport','loopback-test','--timeout-seconds','20']
            if label == 'mixed-dtype-rejection':
                args += ['--synthetic-dtype','float32' if rank == 0 else 'bfloat16',
                         '--prompt-tokens','5','--decode-tokens','2','--warmups','0','--repeats','1']
            out = (output/f'rank-{rank}.stdout').open('w')
            err = (output/f'rank-{rank}.stderr').open('w'); handles.extend([out,err])
            children.append(subprocess.Popen(args,env=env,stdout=out,stderr=err,start_new_session=True))
        deadline=time.monotonic()+25
        for child in children: codes.append(child.wait(timeout=max(1,deadline-time.monotonic())))
    finally:
        for child in children:
            try: os.killpg(child.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            child.wait()
        for handle in handles: handle.close()
    if label == 'token-selection':
        reports = [json.loads((output/f'rank-{rank}.stdout').read_text()) for rank in range(2)]
        assert codes == [0,0]
        assert all(r['generatedTokens'] == [3,1,6] and r['decodeInputTokens'] == [3,1] for r in reports)
        assert reports[1]['localArgmaxTokens'] == [5,7,2] and reports[1]['localArgmaxDisagreementCount'] == 3
        results.append(dict(name=label,exit_codes=codes,reports=reports,passed=True))
    else:
        assert codes == [1,1]
        for rank in range(2):
            assert not (output/f'rank-{rank}.stdout').read_text()
            assert 'Ranks disagree' in (output/f'rank-{rank}.stderr').read_text()
        results.append(dict(name=label,exit_codes=codes,rejected_before_inference=True,passed=True))
receipt = dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),checks=results,
               real_model_tested=False,rdma_tested=False,target_m3_ultra_tested=False)
(root/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
