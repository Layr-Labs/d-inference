"""One explicitly scheduled root action; exact sources and original owned bounds."""
import argparse,json,time
from pathlib import Path
from activation import bind,recheck,sha
from owned_process import invoke_controller
ROOT=Path(__file__).resolve().parent

def verify_source():
    manifest=ROOT/'source-inputs.json'
    for row in json.loads(manifest.read_bytes())['members']:
        p=ROOT/row['path'];assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],row['path']
    required=json.loads((ROOT/'required-native-sources.json').read_bytes())
    for name in ['metadataSources','activationPredecessor','activationManifest','argumentOrderManifest','activationComposition','argumentOrderComposition','unionManifest','unionIntegration','packedHeadManifest']:
        row=required[name];assert sha(Path(row['path']))==row['sha256']
    from registered_embedding import verify
    assert verify()=='45259723b22ef7d5c039213763eb57a0711bdc7e897ca112b58821b3d97827a4'
    return sha(manifest)

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('action',choices=['deploy-prepare','install','case-prepare','metadata','run','compare'])
    p.add_argument('--host',choices=['darkbloom-24','darkbloom-48']);p.add_argument('--case')
    p.add_argument('--refill-policy',choices=['paired','single'],default='paired')
    p.add_argument('--depth',type=int,choices=[1,2],default=2)
    p.add_argument('--output-count',type=int,choices=[16,128],default=16)
    p.add_argument('--prompt',type=int,choices=[128,4096],default=128);p.add_argument('--capture',action='store_true');p.add_argument('--embedding-sha256')
    for name in ['binary','build-receipt','sources','tiny-qualification']:p.add_argument('--'+name,type=Path)
    a=p.parse_args();assert a.case is None or (a.case and all(c.isalnum() or c in '-_' for c in a.case))
    assert (a.case is None)==(a.action in ('deploy-prepare','install')) and (a.host is not None)==(a.action=='install')
    source=verify_source();name=a.action+'-'+(a.case or a.host or '1');out=ROOT/'root-actions'/name;out.mkdir(mode=0o700,parents=True)
    record=dict(schema='gemma4_remote_mtp_root_action_v1',action=a.action,sourceManifestSHA256=source);started=time.monotonic()
    try:
        if a.action=='deploy-prepare':
            assert a.binary and a.build_receipt and a.sources and a.tiny_qualification;activation=bind(a.binary,a.build_receipt,a.sources,a.tiny_qualification)
            command=['deploy.py','prepare','--binary',str(a.binary)];timeout=150
        else:
            assert not a.binary and not a.build_receipt and not a.sources and not a.tiny_qualification;activation=recheck()
            if a.action=='install':command=['deploy.py','install','--host',a.host];timeout=150
            elif a.action=='case-prepare':
                assert a.embedding_sha256
                command=['prepare_case.py','--case',a.case,'--prompt',str(a.prompt),'--output-count',str(a.output_count),'--depth',str(a.depth),'--refill-policy',a.refill_policy,'--embedding-sha256',a.embedding_sha256]
                if a.capture:command.append('--capture')
                timeout=30
            elif a.action=='metadata':command=['remote_metadata.py','--case',a.case];timeout=110
            elif a.action=='run':
                from evidence import Inputs,action
                action(Inputs(),'metadata-'+a.case,'metadata',source,sha(ROOT/'activation.json'))
                command=['run_case.py','--case',a.case];timeout=1020
            else:command=['compare.py','--case',a.case,'--output',str(ROOT/'cases'/a.case/'physical-result.json')];timeout=240
        record['activationSHA256']=sha(ROOT/'activation.json')
        argv=['/usr/bin/python3','-B',str(ROOT/command[0]),*command[1:]];record['argv']=argv
        with (out/'stdout').open('xb') as stdout,(out/'stderr').open('xb') as stderr:invoke_controller(argv,stdout,stderr,record,timeout=timeout)
        assert record['exitCode']==0 and record['reaped'] is True and record['groupAbsent'] is True
        assert verify_source()==source and recheck()==activation;record['status']='passed'
    except BaseException as e:record.update(status='failed',error=type(e).__name__+': '+str(e));raise
    finally:
        record['elapsedSeconds']=time.monotonic()-started
        for name in ['stdout','stderr']:
            f=out/name
            if f.exists():record[name+'SHA256']=sha(f);record[name+'Bytes']=f.stat().st_size
        with (out/'receipt.json').open('x') as f:json.dump(record,f,indent=2);f.write('\n')
        print(json.dumps(record),flush=True)
if __name__=='__main__':main()
