"""Granted same-cache Provider tests then CLI build; actual Foundation helper is reused."""
import argparse,json,os,re,resource
from pathlib import Path
from context import BASE,OUTPUT,HELPER,WORKSPACE,SOURCE,SWIFT_FILTER,INVOCATION_METHODS,isolated_environment
from guards import verify,recheck_sources,require_helper,require_preserved_cli,sha,save,require
from check_process import run_owned
from coverage import validate as validate_swift_results

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--prepared',type=Path,required=True)
    p.add_argument('--phase',choices=['tests','build'],required=True);p.add_argument('--attempt',type=int,required=True);a=p.parse_args()
    require(1<=a.attempt<=9 and a.prepared.resolve()==OUTPUT,'Exact fresh retry output/attempt required')
    _,main,_,candidate=verify();prep=json.loads((OUTPUT/'preparation.json').read_text())
    require(prep['workspace']==str(WORKSPACE) and prep['source']==str(SOURCE) and prep['wrapperManifestSHA256']==sha(BASE/'manifest.json')
        and prep['integrationSHA256']==sha(BASE/'integration.json') and prep['candidateSHA256']==sha(OUTPUT/'candidate-before.json')
        and prep['reusedHelperSHA256']==sha(HELPER/'checks.json'),'Preparation binding differs')
    require(candidate==json.loads((OUTPUT/'candidate-before.json').read_text()) and main==json.loads((OUTPUT/'source-before.json').read_text()),'Prepared exact inventories differ')
    def recheck():verify();recheck_sources(candidate,main);require_helper();require_preserved_cli()
    recheck()
    if a.phase=='build':
        tests=OUTPUT/('tests-'+str(a.attempt));x=json.loads((tests/'checks.json').read_text())
        require(x['passed'] is True and x['manifestSHA256']==sha(BASE/'manifest.json') and x['candidateSHA256']==sha(OUTPUT/'candidate-before.json')
            and x['details']['testsPassed']==107 and x['details']['invocationMethodsPassed']==29,'Matching complete107/29 tests required')
        require(x['executionSHA256']==sha(tests/'execution.json'),'Actual tests execution changed')
        detail=validate_swift_results((tests/'execution.stdout').read_text()+'\n'+(tests/'execution.stderr').read_text())
        require(detail['testsPassed']==107 and detail['invocationMethodsPassed']==29,'Actual passed lines changed')
    out=OUTPUT/(a.phase+'-'+str(a.attempt));out.mkdir(mode=0o700,exist_ok=False)
    isolated_environment();os.chdir(WORKSPACE/'provider-swift')
    old_limit=resource.getrlimit(resource.RLIMIT_FSIZE);resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024*1024,old_limit[1]))
    details={};step=None;failure=None
    try:
        command=['swift','build' if a.phase=='build' else 'test','-j','2','--disable-automatic-resolution','--disable-build-manifest-caching']
        if a.phase=='tests':
            evidence=out/'owned-native-evidence';evidence.mkdir(mode=0o700)
            os.environ['DARKBLOOM_NATIVE_MEMBER_FIXTURE']=str(HELPER/'native-member-fixture')
            os.environ['DARKBLOOM_NATIVE_MEMBER_EVIDENCE']=str(evidence);command+=['--filter',SWIFT_FILTER]
        else:command+=['--product','darkbloom']
        step=run_owned(command,out,'execution',900)
        recheck()
        if a.phase=='tests':
            text=(out/'execution.stdout').read_text()+'\n'+(out/'execution.stderr').read_text();details=validate_swift_results(text)
            for name in INVOCATION_METHODS:
                require(len(re.findall(r'(?m)^✔ Test '+re.escape(name)+r'\(\) passed after [^\n]+$',text))==1,'Required test absent/repeated: '+name)
            require(details['testsPassed']==107 and details['invocationMethodsPassed']==29,'Exact107 tests/29 required methods must pass')
        else:
            binary=WORKSPACE/'provider-swift/.build/debug/darkbloom';details=dict(binarySHA256=sha(binary),binaryBytes=binary.stat().st_size,binaryExecuted=False)
    except BaseException as error:
        failure=type(error).__name__+': '+str(error);raise
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE,old_limit)
        recheck();save(out/'source-recheck.json',dict(unchanged=True,priorQualifiedCLIPreserved=True,reusedHelperUnchanged=True))
        save(out/'checks.json',dict(passed=failure is None,phase=a.phase,details=details,failure=failure,step=step,
            executionSHA256=sha(out/'execution.json') if (out/'execution.json').exists() else None,
            manifestSHA256=sha(BASE/'manifest.json'),candidateSHA256=sha(OUTPUT/'candidate-before.json'),
            reusedHelperSHA256=sha(HELPER/'checks.json'),helperRebuilt=False,modelOrRDMAOrRemoteExecuted=False))
    print(json.dumps(dict(passed=True,phase=a.phase,details=details),sort_keys=True))
if __name__=='__main__':os.umask(0o077);main()
