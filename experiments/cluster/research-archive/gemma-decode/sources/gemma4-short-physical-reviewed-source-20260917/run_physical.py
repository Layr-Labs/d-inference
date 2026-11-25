"""Root-only separate copy, full, pair, collection and comparison actions."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
BASE=Path(__file__).resolve().parent;sys.dont_write_bytecode=True
sys.path[:0]=[str(BASE/'package'),str(BASE/'comparison')]
from binding_common import canonical, parse, require, same, sha
from binding_inputs import snapshot
from gemma_inputs import REMOTE, write_json
from local_process import execute
from parent_settings import SSH
from parent_cleanup import observe_retirement
from alias import Alias
from receive_collection import receive
from validate_collected import validate
from terminal_binding import describe_launch, recheck_launch, require_terminal


def verify_source():
    manifest=parse((BASE/'manifest.json').read_bytes())
    for row in manifest['files']:
        item=snapshot(BASE/row['path'],max(row['bytes'],1),keep=False,empty=True)
        same(item['sha256'],row['sha256'],'Frozen source');same(item['size_bytes'],row['bytes'],'Frozen size')
    trust=parse((BASE/'trust.json').read_bytes());same(snapshot(Path(trust['path']),65536)['sha256'],trust['sha256'],'Pinned SSH trust')


def read_bound(directory,wanted):
    item=snapshot(directory/'binding-receipt.json',65536);same(item['sha256'],wanted,'Binding receipt')
    value=parse(item['raw']);require(value['readyForRootCopyReview'] is True,'Unprepared binding')
    same(parse((directory/'binding.json').read_bytes()),value['binding'],'Binding input changed')
    same(snapshot(directory/'deployment.json',1048576)['sha256'],value['deploymentSHA256'],'Deployment changed')
    same(snapshot(directory/'package.json',1048576)['sha256'],value['packageSHA256'],'Package changed')
    return value


def remote_code(action,mode=None,attempt=1):
    argv=['/usr/bin/python3','-B','-c',(BASE/'remote_evidence.py').read_text(),action]
    if mode:argv+=['--mode',mode,'--attempt',str(attempt)]
    return shlex.join(argv)


def postflight(rank,timeout):
    host=('darkbloom-24','darkbloom-48')[rank]
    value=subprocess.run(SSH+[host,remote_code('observe')],capture_output=True,timeout=timeout)
    require(value.returncode==0 and not value.stderr and len(value.stdout)<=2*1024**2,'Bounded read-only postflight failed')
    return parse(value.stdout)


def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('action',choices=['copy','run','collect','compare'])
    p.add_argument('--bound',required=True,type=Path);p.add_argument('--binding-sha256',required=True)
    p.add_argument('--output',required=True,type=Path);p.add_argument('--mode',choices=['full','stage0','stage1','stages'])
    p.add_argument('--attempt',type=int,default=1);p.add_argument('--copy-proof',type=Path);p.add_argument('--copy-proof-sha256')
    p.add_argument('--full-dir',type=Path);p.add_argument('--stage0-dir',type=Path);p.add_argument('--stage1-dir',type=Path)
    p.add_argument('--full-run-receipt',type=Path);p.add_argument('--full-run-sha256')
    p.add_argument('--stages-run-receipt',type=Path);p.add_argument('--stages-run-sha256');a=p.parse_args()
    require(1<=a.attempt<=9 and a.output.is_absolute() and a.output.parent.resolve()==a.output.parent,'Fresh action/attempt path')
    verify_source();bound=read_bound(a.bound,a.binding_sha256);a.output.mkdir(mode=0o700);os.umask(0o077)
    record=dict(schema='gemma_short_root_action_v1',action=a.action,mode=a.mode,attempt=a.attempt,status='failed',bindingReceiptSHA256=a.binding_sha256,
        packageSHA256=bound['packageSHA256'],numericalQualification=False,throughputMeasurementValid=False,encryptedRDMAEstablished=False)
    try:
        def completed_run(path,wanted,mode):
            require(path is not None and wanted is not None,'Pinned root run receipt required')
            item=snapshot(path,4*1024**2);same(item['sha256'],wanted,'Root run receipt pin');value=parse(item['raw'])
            same(value['status'],'passed','Root run success');same(value['action'],'run','Root run action');same(value['mode'],mode,'Root run mode')
            same(value['bindingReceiptSHA256'],a.binding_sha256,'Root run binding')
            require(value['launchExitCode']==0 and value['retirement']['nativeProcessesAbsent']
                    and value['retirement']['journalsEmpty'],'Root retirement proof')
            if mode=='stages':require(value['aliasRelease']['restored'] is True,'Alias restoration proof')
            recheck_launch(value['launchReceipt'],mode)
            return dict(path=str(path),sha256=wanted,attempt=value['attempt'],launchReceipt=value['launchReceipt'])
        if a.action=='copy':
            require(a.mode is None,'Copy includes both hosts and has no mode')
            code=execute(['/usr/bin/python3','-B',str(BASE/'prepare_copy.py'),'--bound',str(a.bound),
                '--deployment-sha256',bound['deploymentSHA256']],a.output,'stream',180,cap=400_000_000)
            require(code==0,'Copy stream failed');record['hosts']={}
            for host in ('darkbloom-24','darkbloom-48'):
                command=shlex.join(['/usr/bin/python3','-B','-c',(BASE/'install_new_tree.py').read_text()])
                with (a.output/'stream.stdout').open('rb') as stream:code=execute(SSH+[host,command],a.output,host,300,stdin=stream)
                require(code==0,'Copy failed on '+host);value=parse((a.output/(host+'.stdout')).read_bytes())
                same(value['manifestSHA256'],bound['deploymentSHA256'],'Installed manifest');same(value['modelOrOwnerLaunched'],False,'Copy-only')
                record['hosts'][host]=value
        elif a.action=='run':
            require(a.mode in ('full','stages'),'Run mode must be full or stages')
            require(a.copy_proof is not None and a.copy_proof_sha256 is not None,'Both-host native deployment proof required')
            copied=snapshot(a.copy_proof,1048576);same(copied['sha256'],a.copy_proof_sha256,'Copy receipt pin')
            proof=parse(copied['raw']);same(proof['status'],'passed','Actual copy proof');same(proof['action'],'copy','Copy proof action')
            same(proof['bindingReceiptSHA256'],a.binding_sha256,'Copy/binding join');same(set(proof['hosts']),{'darkbloom-24','darkbloom-48'},'Both hosts copied')
            if a.mode=='stages':
                require(a.full_dir is not None,'A separately completed full reference is mandatory')
                record['fullRootRun']=completed_run(a.full_run_receipt,a.full_run_sha256,'full')
                record['fullReferencePrerequisite']=validate(a.bound,a.full_dir,'full')
                same(record['fullRootRun']['attempt'],record['fullReferencePrerequisite']['attempt'],'Full run/collection attempt')
                require_terminal(record['fullRootRun']['launchReceipt'],'full',record['fullReferencePrerequisite']['terminalSHA256'])
            selected=[('full','darkbloom-48')] if a.mode=='full' else [('stage0','darkbloom-24'),('stage1','darkbloom-48')]
            for mode,host in selected:
                command=shlex.join(['/usr/bin/python3','-B',str(REMOTE/'run_gemma.py'),'--package-sha256',bound['packageSHA256'],
                    '--mode',mode,'--attempt',str(a.attempt),'--observe-only'])
                require(execute(SSH+[host,command],a.output,'preflight-'+mode,20)==0,'Actual preflight refused')
            alias=Alias(a.output) if a.mode=='stages' else None;origin=time.monotonic();observations=[]
            try:
                if alias:record['aliasReady']=alias.start()
                record['launchExitCode']=execute(['/usr/bin/python3','-B',str(BASE/'launch_remote.py'),'--mode',a.mode,
                    '--package-sha256',bound['packageSHA256'],'--attempt',str(a.attempt),'--output',str(a.output/'launch')],a.output,'launch',360)
                if record['launchExitCode']==0:
                    record['launchReceipt']=describe_launch(a.output/'launch/terminal.json',a.mode)
            finally:
                try:record['retirement']=observe_retirement(origin+420,postflight,observations.append)
                finally:
                    # Preserve the alias until the existing bounded retirement
                    # observation completes, even after an interrupted SSH.
                    try:
                        if alias:record['aliasRelease']=alias.release()
                    finally:write_json(a.output/'postflight-observations.json',observations)
            require(record.get('launchExitCode')==0,'Native run failed')
            require(record['retirement']['nativeProcessesAbsent'] and record['retirement']['journalsEmpty'],'Remote retirement not established')
            require(not record['retirement'].get('interrupted'),'Retirement was interrupted')
            if alias:require(record['aliasRelease']['restored'],'Temporary alias not restored')
        elif a.action=='collect':
            require(a.mode in ('full','stage0','stage1'),'Collect exactly one native role')
            host='darkbloom-24' if a.mode=='stage0' else 'darkbloom-48'
            require(execute(SSH+[host,remote_code('collect',a.mode,a.attempt)],a.output,'archive',60,cap=65*1024**2)==0,'Read-only collection failed')
            header=receive(a.output/'archive.stdout',a.output/'returned');same(header['mode'],a.mode,'Returned role');same(header['attempt'],a.attempt,'Returned attempt')
            # Failure collections remain useful and are retained. This action
            # does not relabel a failed terminal as successful native execution.
            record['collection']=dict(files=len(header['files']),remoteRoot=header['remoteRoot'],nativeSuccessClaimed=False)
        else:
            require(all((a.full_dir,a.stage0_dir,a.stage1_dir)),'Three collected roles required')
            record['rootRuns']=[completed_run(a.full_run_receipt,a.full_run_sha256,'full'),
                                completed_run(a.stages_run_receipt,a.stages_run_sha256,'stages')]
            checked={mode:validate(a.bound,directory,mode) for mode,directory in [('full',a.full_dir),('stage0',a.stage0_dir),('stage1',a.stage1_dir)]}
            same(checked['full']['attempt'],record['rootRuns'][0]['attempt'],'Full attempt')
            require_terminal(record['rootRuns'][0]['launchReceipt'],'full',checked['full']['terminalSHA256'])
            for mode in ('stage0','stage1'):
                same(checked[mode]['attempt'],record['rootRuns'][1]['attempt'],'Stage attempt')
                require_terminal(record['rootRuns'][1]['launchReceipt'],mode,checked[mode]['terminalSHA256'])
            sources=parse((a.bound/'sources.json').read_bytes())
            packet=dict(schema='gemma4_short_comparison_packet_v1',expected=dict(path=sources['expected.json']['path'],sha256=bound['binding']['expectedSHA256']),
                prompt=dict(path=sources['prompt.ids.json']['path'],sha256=bound['binding']['promptSHA256']),
                results={k:{name:v[name] for name in ('report','sidecarsDirectory')} for k,v in checked.items()})
            write_json(a.output/'comparison-packet.json',packet)
            require(execute(['/usr/bin/python3','-B',str(BASE/'comparison/compare.py'),'--packet',str(a.output/'comparison-packet.json'),
                '--packet-sha256',sha(canonical(packet)+b'\n'),'--output',str(a.output/'numerical.json')],a.output,'compare',120)==0,'Exact numerical comparison failed')
            record['physicalChecks']=checked;record['numericalQualification']=True
        verify_source();read_bound(a.bound,a.binding_sha256);record['status']='passed'
    except BaseException as error:
        record['failure']=type(error).__name__+': '+str(error)[:2048];raise
    finally:write_json(a.output/'receipt.json',record)
    print(canonical(dict(status=record['status'],receipt=str(a.output/'receipt.json'))).decode())


if __name__=='__main__':main()
