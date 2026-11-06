"""One root-owned incremental build with an absolute bound; never runs a GPU."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import subprocess
import time
from composition import WORK,DECODE,pin,read_pinned,sha

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--sources',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();assert a.sources.is_absolute() and a.output.is_absolute() and a.output.parent.resolve()==a.output.parent
    source=json.loads(a.sources.read_bytes());assert source['schema']=='gemma4_remote_mtp_composition_v1' and source['workspaceMutated'] is True
    def check():
        for row in source['files']:read_pinned(dict(row,path=str(WORK/row['path'])))
        assert pin(a.sources)==identity
    identity=pin(a.sources);check()
    a.output.mkdir(mode=0o700)
    binary=WORK/'libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release/GemmaResidentBenchmark'
    if binary.exists():
        subprocess.run(['/bin/cp','-c',str(binary),str(a.output/'prior-GemmaResidentBenchmark')],check=True,timeout=30)
    base=DECODE.parent/'gemma4-decode-optimization-20260920/build/timestamp-build.json'
    assert pin(base)['sha256']==json.loads((Path(__file__).resolve().parent/'build-command-input.json').read_bytes())['sha256']
    command=json.loads(base.read_bytes())['argv']+['-Xswiftc','-DCBV2_WINDOW_STATE_FIXTURE']
    assert command[command.index('--jobs')+1]=='2' and '--disable-automatic-resolution' in command and 'arm64-apple-macosx26.2' in command
    started=time.monotonic();child=None;record=dict(schema='gemma4_remote_mtp_native_build_v1',argv=command,sourcesSHA256=identity['sha256'],gpuExecuted=False)
    try:
        with (a.output/'stdout').open('xb') as out,(a.output/'stderr').open('xb') as err:
            child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=out,stderr=err,start_new_session=True)
            try:code=child.wait(timeout=900)
            except BaseException:
                os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=10);raise
        record.update(exitCode=code,compilerReaped=True,compilerPID=child.pid)
        try:os.killpg(child.pid,0);absent=False
        except ProcessLookupError:absent=True
        record['groupAbsent']=absent;check()
        assert code==0 and absent
        native=pin(binary);record.update(nativeSHA256=native['sha256'],nativeBytes=native['bytes'])
        record['resources']=[pin(binary.parent/name) for name in ['mlx.metallib','mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal']]
        record['status']='passed'
    except BaseException as error:
        record.update(status='failed',error=type(error).__name__+': '+str(error));raise
    finally:
        record['elapsedSeconds']=time.monotonic()-started
        for name in ['stdout','stderr']:
            f=a.output/name
            if f.exists():record[name]=pin(f)
        with (a.output/'receipt.json').open('x') as f:json.dump(record,f,indent=2);f.write('\n')
        print(json.dumps(record),flush=True)
if __name__=='__main__':main()
