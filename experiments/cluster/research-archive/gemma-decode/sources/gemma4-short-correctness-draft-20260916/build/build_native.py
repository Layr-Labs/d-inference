"""Granted local compiler + value/filesystem checks only; never --execute."""
import json,os,re,sys
from build_inputs import BASE,WORKSPACE,SCRATCH,sha
from verify_build_inputs import verify
from check_process import run_owned

def main():
    if len(sys.argv)!=2 or not re.fullmatch(r'[A-Za-z0-9_-]+',sys.argv[1]):raise ValueError('One fresh relative attempt required')
    out=BASE/sys.argv[1];out.mkdir(mode=0o700)
    receipt=dict(sourceSnapshotSHA256=sha(BASE/'source-snapshot-1.json'),dependencySnapshotSHA256=sha(BASE/'dependency-snapshot-1.json'),
        steps=[],nativeModelExecuted=False,remoteExecuted=False,status='started')
    print('Gemma short native build runner PID '+str(os.getpid()),flush=True)
    try:
        receipt['before']=verify()
        command=['swift','build','--package-path',str(WORKSPACE/'libs/darkbloom-cluster-worker'),'--scratch-path',str(SCRATCH),
            '-c','release','--jobs','2','--disable-automatic-resolution','--skip-update','--disable-build-manifest-caching',
            '--triple','arm64-apple-macosx26.2','-Xcc','-target','-Xcc','arm64-apple-macosx26.2',
            '--product','GemmaShortCorrectnessCheck']
        receipt['steps'].append(run_owned(command,out,'build',900));verify()
        binary=SCRATCH/'arm64-apple-macosx/release/GemmaShortCorrectnessCheck'
        receipt['steps'].append(run_owned(['xcrun','vtool','-show-build',str(binary)],out,'version',10))
        version=(out/'version.stdout').read_text()
        if version.count('LC_BUILD_VERSION')!=1 or 'platform MACOS' not in version or not any(line.split()==['minos','26.2'] for line in version.splitlines()):raise ValueError('Wrong native target')
        receipt['steps'].append(run_owned([str(binary),'--check-local-fixtures',str(out/'local-fixtures')],out,'local',10))
        local=json.loads((out/'local.stdout').read_bytes())
        if local!={'accepted':7,'refused':15,'nativeExecuted':False,'modelConstructed':False,'payloadRead':False}:raise ValueError('Local fixture coverage/result differs')
        receipt['steps'].append(run_owned([str(binary),'--check-arguments',str(BASE/'arguments-job.json')],out,'arguments',10))
        value=json.loads((out/'arguments.stdout').read_bytes())
        if not value['metadataOnly'] or value['actualPayloadLoaded'] or value['runtimeExecutionAuthorized'] or value['cut']!=10 or value['promptCount']!=32 or value['outputCount']!=2:raise ValueError('Argument mode claim differs')
        if any((out/(name+'.stderr')).stat().st_size for name in ['local','arguments']):raise ValueError('Pure checks emitted stderr')
        receipt['binary']=dict(path=str(binary),sha256=sha(binary),bytes=binary.stat().st_size)
        receipt['resources']=[]
        for resource in json.loads((BASE/'resource-controls.json').read_bytes())['files']:
            path=binary.parent/resource['path']
            if path.is_symlink() or not path.is_file() or path.stat().st_size!=resource['bytes']:
                raise ValueError('Native resource differs from the qualified ancestor: '+str(path))
            actual=sha(path)
            if actual!=resource['sha256']:raise ValueError('Native resource hash differs: '+str(path))
            receipt['resources'].append(dict(path=str(path),bytes=path.stat().st_size,sha256=actual))
        receipt['status']='passed'
    except BaseException as error:
        receipt['status']='failed';receipt['failure']=type(error).__name__+': '+str(error);raise
    finally:
        try:receipt['after']=verify()
        except BaseException as error:receipt['status']='failed';receipt['sourceRecheckFailure']=str(error)
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    if receipt['status']!='passed':raise ValueError('Post-build source check failed')
    print('Gemma native build and local checks PASS; no model execution',flush=True)
if __name__=='__main__':main()
