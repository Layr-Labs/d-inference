"""Bounded local SSH/copy command; never kill a group after its leader is reaped."""
import hashlib
import os
import signal
import subprocess
import time
from reference_inputs import write_json
from binding_common import require


def execute(argv,directory,name,seconds,stdin=None,cap=4*1024**2):
    start=time.monotonic();child=None;failure=None
    outpath=directory/(name+'.stdout');errpath=directory/(name+'.stderr')
    with outpath.open('xb') as out,errpath.open('xb') as err:
        try:
            child=subprocess.Popen(argv,stdin=stdin if stdin is not None else subprocess.DEVNULL,
                stdout=out,stderr=err,start_new_session=True)
            write_json(directory/(name+'.launched.json'),dict(pid=child.pid,argv=argv,timeoutSeconds=seconds))
            while child.poll() is None:
                require(time.monotonic()-start<seconds,'Owned command deadline')
                require(outpath.stat().st_size+errpath.stat().st_size<=cap,'Owned output bound')
                time.sleep(.05)
            require(outpath.stat().st_size+errpath.stat().st_size<=cap,'Final output bound')
        except BaseException as error:
            failure=type(error).__name__+': '+str(error)[:2048]
            if child is not None and child.returncode is None:
                try:os.killpg(child.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                child.wait(timeout=5)
            raise
        finally:
            absent=False
            if child is not None and child.returncode is not None:
                try:os.killpg(child.pid,0)
                except ProcessLookupError:absent=True
            def digest(path):
                h=hashlib.sha256()
                with path.open('rb') as f:
                    for block in iter(lambda:f.read(65536),b''):h.update(block)
                return h.hexdigest()
            write_json(directory/(name+'.execution.json'),dict(exitCode=child.returncode if child else None,
                reaped=child is not None and child.returncode is not None,groupAbsent=absent,
                elapsedSeconds=time.monotonic()-start,failure=failure,stdoutSHA256=digest(outpath),stderrSHA256=digest(errpath)))
    require(absent,'Owned group remains after leader exit')
    return child.returncode
