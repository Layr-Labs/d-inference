"""Explicit local full verification, then APFS-only private clone staging."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import platform
import signal
import time
from artifact import BASE,SOURCE,manifest,hash_file,inspect,recheck,verify_tree,stamp,write,record,disk,digest
from binding_common import require,same
from source_guard import check_sources

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    require(platform.system()=='Darwin','APFS staging requires macOS')
    source_pins=check_sources()
    require(a.output.is_absolute() and a.output.parent.resolve()==a.output.parent,'Canonical fresh output')
    a.output.mkdir(mode=0o700);os.umask(0o077);start=time.monotonic();deadline=start+900
    previous=signal.getsignal(signal.SIGALRM)
    def expired(*_):raise TimeoutError('Local verification/staging900s deadline')
    signal.signal(signal.SIGALRM,expired);signal.alarm(900)
    result=dict(status='started',sourceDirectory=str(SOURCE),sourceCacheModified=False,modelExecuted=False,sourcePinsSHA256=source_pins)
    try:
        raw,rows=manifest();inventory=json.loads((BASE/'local-cache-inventory.json').read_bytes())['files']
        same([(x['path'],x['size_bytes'],x['sha256'],x['source']) for x in inventory],
             [(x['path'],x['size_bytes'],x['sha256'],str(SOURCE/x['path'])) for x in rows],'Exact retained cache inventory')
        # No model staging exists until every source file has passed full hashing.
        result['sourceFiles']=[]
        for r in rows:result['sourceFiles'].append(hash_file(SOURCE/r['path'],r['size_bytes'],r['sha256'],deadline))
        record(a.output/'source-verification.json',dict(wholePayloadVerified=True,files=result['sourceFiles']))
        result['disk']=disk(a.output.parent);stage=a.output/'model';stage.mkdir(mode=0o700)
        libc=ctypes.CDLL(None,use_errno=True);clone=libc.clonefile
        clone.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int];clone.restype=ctypes.c_int
        for row in result['sourceFiles']:
            source=SOURCE/row['path'];target=stage/row['path'];same(inspect(source),row['identity'],'Source before clone')
            require(time.monotonic()<deadline,'Clone deadline')
            if clone(os.fsencode(source),os.fsencode(target),0)!=0:raise OSError(ctypes.get_errno(),'APFS clonefile failed; no copy fallback')
            target.chmod(0o600);same(inspect(source),row['identity'],'Source after clone')
        write(stage/'manifest.json',raw)
        result['staging']=verify_tree(stage,deadline)
        for row in result['sourceFiles']:same(inspect(SOURCE/row['path']),row['identity'],'Original source postflight')
        result['stageDirectory']=str(stage);result['status']='passed'
        write(a.output/'files.txt',('\n'.join([r['path'] for r in rows]+['manifest.json'])+'\n').encode())
        same(check_sources(),source_pins,'Source postflight')
    except BaseException as error:result['status']='failed';result['failure']=type(error).__name__+': '+str(error)[:2048];raise
    finally:
        signal.alarm(0);signal.signal(signal.SIGALRM,previous);result['elapsedSeconds']=time.monotonic()-start
        record(a.output/'receipt.json',result)
    print(json.dumps(dict(status=result['status'],receipt=str(a.output/'receipt.json'),sha256=digest((a.output/'receipt.json').read_bytes()))))
if __name__=='__main__':main()
