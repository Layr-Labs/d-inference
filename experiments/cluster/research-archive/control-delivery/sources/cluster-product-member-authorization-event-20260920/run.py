"""Root schedules each bounded same-cache phase; no retries or old result reuse."""
import argparse
import fcntl
import os
import resource
import sys
from common import BASE, RUN, clean_environment, helper, inputs, read, require, save, sha
from inventory import inventory
from completions import completion
from check_process import run_owned

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('phase', choices=['prepare','tests','build']);phase=p.parse_args().phase
    clean_environment();c,w,before,after=inputs()
    # Join the same scratch-workspace lock as the preserved parent controller.
    lock=(Path(c['base'])/'qualification-1/phase.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    RUN.mkdir(mode=0o700,exist_ok=True);out=RUN/phase;out.mkdir(mode=0o700,exist_ok=False)
    receipt=dict(passed=False,phase=phase,manifestSHA256=sha(BASE/'manifest.json'),candidateSHA256=c['candidateSHA256'],helperRebuilt=False,compilerExecuted=phase!='prepare',hardwareOrRemoteExecuted=False)
    limits=resource.getrlimit(resource.RLIMIT_FSIZE);resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024*1024,limits[1]))
    try:
        fixture=helper(c)
        if phase=='prepare':
            receipt['execution']=run_owned([sys.executable,'-B',str(BASE/'prepare.py'),str(out)],out,'execution',120)
        else:
            prior=read(RUN/'prepare/receipt.json');ready=read(RUN/'prepare/prepared.json')
            require(prior['passed'] and ready['passed'] and ready['manifestSHA256']==receipt['manifestSHA256'] and ready['candidateSHA256']==c['candidateSHA256'],'Matching preparation required')
            require(inventory(w)==after,'Full source/dependency inventory changed')
            if phase=='build':
                t=read(RUN/'tests/receipt.json')
                require(t['passed'] and t['candidateSHA256']==c['candidateSHA256'] and t['manifestSHA256']==receipt['manifestSHA256'] and t['executionSHA256']==sha(RUN/'tests/execution.json'),'Matching actual tests required')
                require(t['details']==completion((RUN/'tests/execution.stdout').read_text()+'\n'+(RUN/'tests/execution.stderr').read_text()),'Exact193 actual completions changed')
            os.chdir(w/'provider-swift')
            argv=['swift','test' if phase=='tests' else 'build','-j','2','--disable-automatic-resolution','--disable-build-manifest-caching']
            if phase=='tests':
                evidence=out/'owned-native-evidence';evidence.mkdir(mode=0o700)
                os.environ['DARKBLOOM_NATIVE_MEMBER_FIXTURE']=str(fixture/'native-member-fixture');os.environ['DARKBLOOM_NATIVE_MEMBER_EVIDENCE']=str(evidence)
                argv+=['--filter',read(BASE/'test-coverage.json')['swiftFilter']]
            else:argv+=['--product','darkbloom']
            receipt['execution']=run_owned(argv,out,'execution',900)
            if phase=='tests':receipt['details']=completion((out/'execution.stdout').read_text()+'\n'+(out/'execution.stderr').read_text())
            else:
                binary=w/'provider-swift/.build/debug/darkbloom';receipt['details']=dict(binarySHA256=sha(binary),bytes=binary.stat().st_size,binaryExecuted=False)
        inputs();require(inventory(w)==after,'Corrected source/dependency context changed');receipt['passed']=True
    except BaseException as error:
        receipt['failure']=type(error).__name__+': '+str(error);raise
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE,limits)
        if (out/'execution.json').exists():receipt['executionSHA256']=sha(out/'execution.json')
        try:
            actual=inventory(w);save(out/'inventory-terminal.json',actual);receipt['terminalInventoryMatchesCandidate']=actual==after
            if phase!='prepare':require(actual==after,'Terminal source context changed')
        except BaseException as error:
            receipt['passed']=False;receipt['terminalRecheckFailure']=str(error);raise
        finally:save(out/'receipt.json',receipt);lock.close()

from pathlib import Path
if __name__=='__main__':os.umask(0o077);main()
