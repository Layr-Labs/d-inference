"""One coherent helper, owner-drain controls, all117 Provider tests, matching CLI."""
import argparse,json,os,resource,sys
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0, '/Users/developer/DarkbloomDev/cluster-research/cluster-native-numerical-provider-build-draft-20260917')
from context import BASE,ADAPTER,WORKSPACE,OUTPUT,SOURCE,SWIFT_FILTER,OLD_HELPER,DRAIN,isolated_environment
from guards import verify,recheck_sources,require_preserved_cli,require_helper,sha,save,require
from check_process import run_owned
from coverage import validate
from activation import require_activation

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--prepared',type=Path,required=True)
    p.add_argument('--phase',choices=['helper','tests','build'],required=True);p.add_argument('--attempt',type=int,required=True);a=p.parse_args()
    require(1<=a.attempt<=9 and a.prepared.resolve()==OUTPUT,'Exact retry output and bounded attempt required')
    _,main,_,candidate=verify();prep=json.loads((OUTPUT/'preparation.json').read_text())
    require(prep['status']=='passed' and prep['activationSHA256']==sha(BASE/'activation-1/activation.json') and prep['workspace']==str(WORKSPACE) and prep['source']==str(SOURCE) and prep['wrapperManifestSHA256']==sha(BASE/'manifest.json')
        and prep['integrationSHA256']==sha(BASE/'integration.json') and prep['candidateSHA256']==sha(OUTPUT/'candidate-before.json')
        and prep['historicalHelperSHA256']==sha(OLD_HELPER/'checks.json'),'Preparation binding differs')
    require(candidate==json.loads((OUTPUT/'candidate-before.json').read_text()) and main==json.loads((OUTPUT/'source-before.json').read_text()),'Prepared exact inventories differ')
    def recheck():verify();require_activation();recheck_sources(candidate,main);require_preserved_cli()
    recheck()
    if a.phase in ['tests','build']:require_helper(a.attempt)
    if a.phase=='build':
        tests=OUTPUT/('tests-'+str(a.attempt));x=json.loads((tests/'checks.json').read_text())
        require(x['passed'] is True and x['manifestSHA256']==sha(BASE/'manifest.json') and x['candidateSHA256']==sha(OUTPUT/'candidate-before.json')
            and x['details']['testsPassed']==117 and x['details']['suitesPassed']==19 and x['details']['invocationMethodsPassed']==29,'Matching complete117/19/29 tests required')
        require(x['executionSHA256']==sha(tests/'execution.json'),'Actual test execution changed')
        require(validate((tests/'execution.stdout').read_text()+'\n'+(tests/'execution.stderr').read_text())==x['details'],'Actual passed lines changed')
    out=OUTPUT/(a.phase+'-'+str(a.attempt));out.mkdir(mode=0o700,exist_ok=False)
    isolated_environment()
    old_limit=resource.getrlimit(resource.RLIMIT_FSIZE);resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024*1024,old_limit[1]))
    steps=[];details={};artifacts=[];evidence_pins=[];failure=None
    def execute(argv,name,bound):
        try:steps.append(run_owned(argv,out,name,bound))
        finally:recheck()
    try:
        if a.phase=='helper':
            execute([sys.executable,'-B','/Users/developer/DarkbloomDev/cluster-research/cluster-native-numerical-provider-root-review-20260917/test_coverage_method_filter.py'],'coverage-parser',30)
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
            for mode,library in [('baseline',OLD_HELPER),('candidate',out)]:
                directory=out/(mode+'-drain');directory.mkdir(mode=0o700)
                (directory/'module-cache').mkdir(mode=0o700);(directory/'cases').mkdir(mode=0o700)
                fixture_command=['xcrun','swiftc','-j','2','-swift-version','6','-warnings-as-errors',
                    '-target','arm64-apple-macos14.0','-parse-as-library','-module-cache-path',str(directory/'module-cache'),
                    '-I',str(library),'-L',str(library),'-Xlinker','-rpath','-Xlinker',str(library)]
                fixture_command+=['-l'+name for name,_ in modules]
                for kind in ['Owner','Checks']:
                    flags=['-D','OWNER_RELEASE_EOF_DRAIN'] if mode=='candidate' and kind=='Checks' else []
                    files=[DRAIN/'Tests/FixtureIdentity.swift',DRAIN/'Tests/ReleaseDrainSupport.swift',DRAIN/('Tests/ReleaseDrain'+kind+'.swift')]
                    execute(fixture_command+flags+list(map(str,files))+['-o',str(directory/('ReleaseDrain'+kind))],mode+'-compile-drain-'+kind.lower(),60)
                name=mode+'-owner-drain'
                execute([str(directory/'ReleaseDrainChecks'),str(directory/'ReleaseDrainOwner'),str(directory/'cases')],name,30)
                expected='owner-release-eof-drain: '+('baseline buffered-ACK loss reproduced' if mode=='baseline' else '4 actual-owner/child groups passed')+'\n'
                require((out/(name+'.stdout')).read_text()==expected and (out/(name+'.stderr')).stat().st_size==0,'Exact actual-owner drain completion required')
            for path in [executable]+sorted(out.glob('*.dylib')):artifacts.append(dict(path=str(path),sha256=sha(path),bytes=path.stat().st_size))
            require(len(steps)==23 and len(artifacts)==6,'Combined helper closure differs')
            details=dict(helperCompiled=True,legacySSHChecksExecuted=True,newNativeHelperExecuted=False,
                baselineBufferedACKLossReproduced=True,actualOwnerDrainGroupsPassed=4)
            for path in sorted(out.iterdir()):
                if path.is_file() and path.suffix in ['.json','.stdout','.stderr']:
                    evidence_pins.append(dict(path=str(path),bytes=path.stat().st_size,sha256=sha(path)))
            for mode in ['baseline','candidate']:
                for path in sorted((out/(mode+'-drain')).rglob('*')):
                    if path.is_file() and 'module-cache' not in path.parts:
                        evidence_pins.append(dict(path=str(path),bytes=path.stat().st_size,sha256=sha(path)))
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
        try:recheck();save(out/'source-recheck.json',dict(unchanged=True,priorFailedCandidateBinaryPreserved=True))
        except BaseException as error:
            if failure is None:failure=type(error).__name__+': '+str(error)
            raise
        finally:
            save(out/'checks.json',dict(passed=failure is None,phase=a.phase,details=details,failure=failure,steps=steps,artifacts=artifacts,evidencePins=evidence_pins,
                executionSHA256=sha(out/'execution.json') if (out/'execution.json').exists() else None,
                manifestSHA256=sha(BASE/'manifest.json'),candidateSHA256=sha(OUTPUT/'candidate-before.json'),
                historicalHelperSHA256=sha(OLD_HELPER/'checks.json'),tlsQualified=False,physicalUseAuthorized=False,helperRebuilt=a.phase=='helper',modelOrRDMAOrRemoteExecuted=False))
    print(json.dumps(dict(passed=True,phase=a.phase,details=details),sort_keys=True))
if __name__=='__main__':os.umask(0o077);main()
