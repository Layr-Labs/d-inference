"""Root-granted same-cache source overlay, with one owned bounded preparation child."""
import json, os, sys
from build_inputs import BASE, sha
from owned_process import invoke_controller

def main():
    out=BASE/'prepare-1';out.mkdir(mode=0o700)
    result=dict(steps=[],passed=False,compilerOrModelOrRemoteExecuted=False)
    try:
        step=dict(name='guarded-source-overlay',argv=[sys.executable,'-B',str(BASE/'prepare_sources.py')])
        result['steps'].append(step)
        with (out/'stdout').open('xb') as stdout,(out/'stderr').open('xb') as stderr:
            invoke_controller(step['argv'],stdout,stderr,step,timeout=120)
        if step.get('exitCode')!=0 or not step.get('reaped') or not step.get('groupAbsent'):
            raise RuntimeError('Preparation failed or owned group remains')
        result.update(passed=True,preparationSHA256=sha(BASE/'preparation.json'))
    finally:(out/'receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
if __name__=='__main__':os.umask(0o077);main()
