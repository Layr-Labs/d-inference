"""Granted corrected helper/legacy checks, complete 112 Provider tests, then CLI build."""
import argparse,json,os,resource,sys
from pathlib import Path
sys.dont_write_bytecode=True
from context import BASE,ADAPTER,WORKSPACE,OUTPUT,SOURCE,SWIFT_FILTER,OLD_HELPER,isolated_environment
from guards import verify,recheck_sources,require_preserved_cli,require_helper,sha,save,require
from check_process import run_owned
from coverage import validate

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--prepared',type=Path,required=True)
    p.add_argument('--phase',choices=['helper','tests','build'],required=True);p.add_argument('--attempt',type=int,required=True);a=p.parse_args()
    require(1<=a.attempt<=9 and a.prepared.resolve()==OUTPUT,'Exact retry output and bounded attempt required')
    _,main,_,candidate=verify();prep=json.loads((OUTPUT/'preparation.json').read_text())
    require(prep['workspace']==str(WORKSPACE) and prep['source']==str(SOURCE) and prep['wrapperManifestSHA256']==sha(BASE/'manifest.json')
        and prep['integrationSHA256']==sha(BASE/'integration.json') and prep['candidateSHA256']==sha(OUTPUT/'candidate-before.json')
        and prep['historicalHelperSHA256']==sha(OLD_HELPER/'checks.json'),'Preparation binding differs')
    require(candidate==json.loads((OUTPUT/'candidate-before.json').read_text()) and main==json.loads((OUTPUT/'source-before.json').read_text()),'Prepared exact inventories differ')
    def recheck():verify();recheck_sources(candidate,main);require_preserved_cli()
    recheck()
    if a.phase in ['tests','build']:require_helper(a.attempt)
    if a.phase=='build':
        tests=OUTPUT/('tests-'+str(a.attempt));x=json.loads((tests/'checks.json').read_text())
        require(x['passed'] is True and x['manifestSHA256']==sha(BASE/'manifest.json') and x['candidateSHA256']==sha(OUTPUT/'candidate-before.json')
            and x['details']['testsPassed']==112 and x['details']['suitesPassed']==18 and x['details']['invocationMethodsPassed']==29,'Matching complete 112/18/29 tests required')
        require(x['executionSHA256']==sha(tests/'execution.json'),'Actual test execution changed')
        require(validate((tests/'execution.stdout').read_text()+'\n'+(tests/'execution.stderr').read_text())==x['details'],'Actual passed lines changed')
    out=OUTPUT/(a.phase+'-'+str(a.attempt));out.mkdir(mode=0o700,exist_ok=False)
    isolated_environment()
    old_limit=resource.getrlimit(resource.RLIMIT_FSIZE);resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024*1024,old_limit[1]))
    steps=[];details={};artifacts=[];failure=None
    def execute(argv,name,bound):
        try:steps.append(run_owned(argv,out,name,bound))
        finally:recheck()
    try:
        if a.phase=='helper':
            execute([sys.executable,'-B',str(BASE/'test_coverage.py')],'coverage-parser',30)
            source=WORKSPACE/'libs/darkbloom-cluster';(out/'module-cache').mkdir(mode=0o700)
            command=['xcrun','swiftc','-j','2','-swift-version','6','-warnings-as-errors','-target','arm64-apple-macos14.0',
                '-parse-as-library','-module-cache-path',str(out/'module-cache')]
            linkage=['-I',str(out),'-L',str(out),'-Xlinker','-rpath','-Xlinker',str(out)]
            modules=[('DarkbloomClusterProtocol',[]),('DarkbloomClusterProcess',['DarkbloomClusterProtocol']),
                ('DarkbloomClusterBootstrap',[]),('DarkbloomClusterSecurity',['DarkbloomClusterBootstrap']),
                ('DarkbloomClusterRemote',['DarkbloomClusterProtocol','DarkbloomClusterProcess','DarkbloomClusterBootstrap','DarkbloomClusterSecurity'])]
            for name,dependencies in modules:
                library=out/('lib'+name+'.dylib')
                execute(command+linkage+['-l'+x for x in dependencies]+['-enable-testing','-emit-library','-emit-module','-module-name',name,
                    '-emit-module-path',str(out/(name+'.swiftmodule')),'-Xlinker','-install_name','-Xlinker','@rpath/'+library.name]
                    +list(map(str,sorted((source/'Sources'/name).glob('*.swift'))))+['-o',str(library)],name,60)
            links=linkage+['-l'+name for name,_ in modules];executable=out/'native-member-fixture'
            execute(command+links+list(map(str,sorted((ADAPTER/'Tests/OwnedChild').glob('*.swift'))))+['-o',str(executable)],'compile-helper',60)
            for name in ['FakeClusterWorker','FakeOwner','RemoteOwnerTests','RetirementShutdownTests','DiagnosticFailureWorker','LateDiagnosticOwner','OwnerDiagnosticDrainTests']:
                path=source/('Tests/ProcessChecks' if name=='FakeClusterWorker' else 'Tests/SSHChecks')/(name+'.swift')
                files=[source/'Tests/ProcessChecks/FixtureIdentity.swift',path]
                if name=='RetirementShutdownTests':files.append(source/'Tests/SSHChecks/RetirementOwnerConnection.swift')
                execute(command+links+['-D','OWNER_DIAGNOSTIC_DRAIN']+list(map(str,files))+['-o',str(out/name)],'compile-'+name,60)
            for directory in ['retirement-checks','diagnostic-checks']:(out/directory).mkdir(mode=0o700)
            execute([str(out/'RemoteOwnerTests'),str(out/'FakeOwner'),str(out/'FakeClusterWorker')],'legacy-remote',30)
            execute([str(out/'RetirementShutdownTests'),str(out/'FakeOwner'),str(out/'FakeClusterWorker'),str(out/'retirement-checks'),'corrected'],'legacy-retirement',30)
            execute([str(out/'OwnerDiagnosticDrainTests'),str(out/'LateDiagnosticOwner'),str(out/'DiagnosticFailureWorker'),str(out/'diagnostic-checks')],'legacy-diagnostics',30)
            for path in [executable]+sorted(out.glob('*.dylib')):artifacts.append(dict(path=str(path),sha256=sha(path),bytes=path.stat().st_size))
            require(len(steps)==17 and len(artifacts)==6,'Corrected helper closure differs')
            details=dict(helperCompiled=True,legacySSHChecksExecuted=True,newNativeHelperExecuted=False)
        else:
            os.chdir(WORKSPACE/'provider-swift')
            command=['swift','build' if a.phase=='build' else 'test','-j','2','--disable-automatic-resolution','--disable-build-manifest-caching']
            if a.phase=='tests':
                evidence=out/'owned-native-evidence';evidence.mkdir(mode=0o700)
                os.environ['DARKBLOOM_NATIVE_MEMBER_FIXTURE']=str(OUTPUT/('helper-'+str(a.attempt))/'native-member-fixture')
                os.environ['DARKBLOOM_NATIVE_MEMBER_EVIDENCE']=str(evidence);command+=['--filter',SWIFT_FILTER]
            else:command+=['--product','darkbloom']
            execute(command,'execution',900);require_helper(a.attempt)
            if a.phase=='tests':details=validate((out/'execution.stdout').read_text()+'\n'+(out/'execution.stderr').read_text())
            else:
                binary=WORKSPACE/'provider-swift/.build/debug/darkbloom';details=dict(binarySHA256=sha(binary),binaryBytes=binary.stat().st_size,binaryExecuted=False)
    except BaseException as error:
        failure=type(error).__name__+': '+str(error);raise
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE,old_limit)
        try:recheck();save(out/'source-recheck.json',dict(unchanged=True,priorQualifiedCLIPreserved=True))
        except BaseException as error:
            if failure is None:failure=type(error).__name__+': '+str(error)
            raise
        finally:
            save(out/'checks.json',dict(passed=failure is None,phase=a.phase,details=details,failure=failure,steps=steps,artifacts=artifacts,
                executionSHA256=sha(out/'execution.json') if (out/'execution.json').exists() else None,
                manifestSHA256=sha(BASE/'manifest.json'),candidateSHA256=sha(OUTPUT/'candidate-before.json'),
                historicalHelperSHA256=sha(OLD_HELPER/'checks.json'),helperRebuilt=a.phase=='helper',modelOrRDMAOrRemoteExecuted=False))
    print(json.dumps(dict(passed=True,phase=a.phase,details=details),sort_keys=True))
if __name__=='__main__':os.umask(0o077);main()
