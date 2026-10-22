"""Concurrent bounded SSH handles; the remote supervisor owns each native group."""
import argparse
import os
from pathlib import Path
import shlex
import sys
BASE=Path(__file__).resolve().parent;sys.path.insert(0,str(BASE/'package'))
from binding_common import canonical, parse, require, same
from gemma_inputs import REMOTE, write_json
from parent_settings import SSH
from ssh_processes import PipeWorkers, cleanup_error_text
from worker_contract import WorkerSpec


def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--mode',choices=['full','stages'],required=True)
    p.add_argument('--package-sha256',required=True);p.add_argument('--attempt',type=int,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    require(1<=a.attempt<=9,'Attempt bound');a.output.mkdir(mode=0o700)
    selected=[('full','darkbloom-48')] if a.mode=='full' else [('stage0','darkbloom-24'),('stage1','darkbloom-48')]
    specs=[]
    for mode,host in selected:
        command=shlex.join(['/usr/bin/python3','-B',str(REMOTE/'run_gemma.py'),'--mode',mode,'--attempt',str(a.attempt),'--package-sha256',a.package_sha256])
        specs.append(WorkerSpec(tuple(SSH+[host,command]),dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',HOME=str(Path.home()),LANG='C'),'solo',None))
    pipes=PipeWorkers(specs,a.output/'ssh',350,lambda _:None);record=dict(status='starting',results=[],primaryFailure=None)
    try:
        pipes.start()
        def validate(index,raw):
            value=parse(raw);same(value['mode'],selected[index][0],'Remote mode');same(value['status'],'completed','Remote completion');return value
        record['results']=pipes.collect('remote-native',validate);pipes.finish();record['status']='completed'
    except BaseException as error:record['status']='failed';record['primaryFailure']=cleanup_error_text(error)[0]
    finally:
        try:pipes.close(kill=record['status']!='completed')
        except BaseException as error:record['cleanupFailure']=cleanup_error_text(error)[0];record['status']='failed'
        record.update(exitCodes=[p.returncode for p in pipes.children],reaped=bool(pipes.children) and all(p.returncode is not None for p in pipes.children),
            cleanupErrors=pipes.cleanup_errors,outputComplete=pipes.complete_output,watchdogExpired=pipes.expired.is_set())
        if record['cleanupErrors'] or not record['reaped'] or not record['outputComplete']:record['status']='failed'
        write_json(a.output/'terminal.json',record)
    print(canonical(record).decode(),flush=True);return 0 if record['status']=='completed' else 1
if __name__=='__main__':raise SystemExit(main())
