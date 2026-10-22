"""Root schedules each phase; no automatic retries, remote, native or GPU launch."""
import argparse,json,os,re,resource,sys
from pathlib import Path
from common import BASE,ROOT,inputs,require,save,sha
from source_inventory import inventory
from check_process import run_owned

def completion(text):
    contract=json.loads((BASE/'test-coverage.json').read_bytes())
    labels=re.findall(r'(?m)^✔ Test (.+?) passed after \d+(?:\.\d+)? seconds\.$',text)
    labels=[x for x in labels if not x.startswith('run with ')]
    summaries=re.findall(r'✔ Test run with (\d+) tests(?: in \d+ suites)? passed after',text)
    require(sorted(labels)==contract['completionLabels'] and summaries==[str(contract['testCount'])],'Exact 178 completions and terminal summary required')
    require('✘' not in text,'Failed test/suite observed')
    return dict(passedTests=len(labels),all178ExactCompletions=True)

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('phase',choices=['prepare','tests','build']);a=p.parse_args()
    c,w,before,after=inputs();root=BASE/'qualification-1'
    root.mkdir(mode=0o700,exist_ok=True);out=root/a.phase;out.mkdir(mode=0o700,exist_ok=False)
    keep=('PATH','HOME','USER','LOGNAME','LANG','LC_ALL','DEVELOPER_DIR','SDKROOT');env={k:os.environ[k] for k in keep if k in os.environ}
    os.environ.clear();os.environ.update(env);os.environ['TMPDIR']='/private/tmp'
    receipt=dict(passed=False,phase=a.phase,manifestSHA256=sha(ROOT/'manifest.json'),candidateSHA256=sha(BASE/'candidate-after.json'),compilerExecuted=a.phase!='prepare',modelOrRemoteExecuted=False,helperRebuilt=False)
    limits=resource.getrlimit(resource.RLIMIT_FSIZE);resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024*1024,limits[1]))
    try:
        if a.phase=='prepare':
            receipt['execution']=run_owned([sys.executable,'-B',str(BASE/'prepare.py'),str(out)],out,'execution',120)
        else:
            prepared=json.loads((root/'prepare/prepared.json').read_bytes())
            require(prepared['passed'] and prepared['manifestSHA256']==receipt['manifestSHA256'] and prepared['candidateSHA256']==receipt['candidateSHA256'],'Matching prepared composition required')
            require(sha(root/'prepare/prior-darkbloom')==c['priorCLI_SHA256'] and inventory(w)==after,'Preserved binary or complete candidate changed')
            if a.phase=='build':
                t=json.loads((root/'tests/receipt.json').read_bytes());require(t['passed'] and t['candidateSHA256']==receipt['candidateSHA256'] and t['manifestSHA256']==receipt['manifestSHA256'] and t['executionSHA256']==sha(root/'tests/execution.json'),'Matching tests required')
                require(t['details']==completion((root/'tests/execution.stdout').read_text()+'\n'+(root/'tests/execution.stderr').read_text()),'Test completion changed')
            os.chdir(w/'provider-swift')
            argv=['swift','test' if a.phase=='tests' else 'build','-j','2','--disable-automatic-resolution','--disable-build-manifest-caching']
            if a.phase=='tests':
                evidence=out/'owned-native-evidence';evidence.mkdir(mode=0o700)
                os.environ['DARKBLOOM_NATIVE_MEMBER_FIXTURE']=str(Path(c['helperDirectory'])/'native-member-fixture');os.environ['DARKBLOOM_NATIVE_MEMBER_EVIDENCE']=str(evidence)
                argv+=['--filter',json.loads((BASE/'test-coverage.json').read_bytes())['swiftFilter']]
            else:argv+=['--product','darkbloom']
            receipt['execution']=run_owned(argv,out,'execution',900)
            if a.phase=='tests':receipt['details']=completion((out/'execution.stdout').read_text()+'\n'+(out/'execution.stderr').read_text())
            else:
                binary=w/'provider-swift/.build/debug/darkbloom';receipt['details']=dict(binarySHA256=sha(binary),bytes=binary.stat().st_size,binaryExecuted=False)
        inputs();actual=inventory(w);save(out/'inventory-after.json',actual);require(actual==after,'Source/dependency closure changed')
        receipt['passed']=True
    except BaseException as error:
        receipt['failure']=type(error).__name__+': '+str(error)
        raise
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE,limits)
        if (out/'execution.json').exists():receipt['executionSHA256']=sha(out/'execution.json')
        try:
            actual=inventory(w);save(out/'inventory-terminal.json',actual)
            receipt['terminalInventoryMatchesCandidate']=actual==after
            if a.phase!='prepare':require(actual==after,'Terminal source/dependency closure changed')
        except BaseException as error:
            receipt['passed']=False;receipt['terminalRecheckFailure']=type(error).__name__+': '+str(error)
            raise
        finally:save(out/'receipt.json',receipt)
if __name__=='__main__':os.umask(0o077);main()
