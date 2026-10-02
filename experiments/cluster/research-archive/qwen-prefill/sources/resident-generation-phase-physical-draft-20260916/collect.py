"""Root-only read-only collection after completed external ownership proof."""
from pathlib import Path
import argparse,base64,hashlib,json,os,subprocess,sys
from physical_evidence import terminal,read,parse,require,digest,pin
BASE=Path(__file__).resolve().parent

def publish(p,raw):
    with p.open('xb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
def main():
    ap=argparse.ArgumentParser(allow_abbrev=False);ap.add_argument('--case',choices=['serial','lookahead'],required=True);a=ap.parse_args()
    case=BASE/a.case;prior=terminal(case)
    sys.path.insert(0,str(case));from parent_settings import SSH
    hosts=next(x.split('=',1)[1] for x in SSH if x.startswith('UserKnownHostsFile='))
    require(digest(read(hosts))=='89a73d7ca9fe16a0c1aeb0fa6cfa640ff37a02d4a2d21114e7ad5fca089443ed','SSH trust differs')
    out=case/'collection-1';out.mkdir(mode=0o700)
    script=read(case/'read_sidecar_remote.py');rows=[]
    result=dict(schema='resident_phase_collection_v1',case=a.case,status='failed',ranks=rows,
        readerSHA256=digest(script),physicalExecution=prior['physicalExecution'],controllerResult=prior['controllerResult'])
    try:
        for rank,host in enumerate(['darkbloom-24','darkbloom-48']):
            row=dict(rank=rank,host=host,status='failed');rows.append(row)
            try:
                child=subprocess.run(SSH+[host,'/usr/bin/python3 -B -'],input=script,capture_output=True,timeout=30)
            except subprocess.TimeoutExpired as error:
                publish(out/f'rank{rank}.transport.stdout',error.stdout or b'');publish(out/f'rank{rank}.transport.stderr',error.stderr or b'');raise
            publish(out/f'rank{rank}.transport.stdout',child.stdout);publish(out/f'rank{rank}.transport.stderr',child.stderr)
            row['sshExitCode']=child.returncode
            require(child.returncode==0 and child.stderr==b'' and 0<len(child.stdout)<=512*1024,'Collection SSH failed or exceeded bound')
            packet=parse(child.stdout)
            require(set(packet)==set('schema path bytes sha256 identity data active journalBytes journalSHA256 journalIdentity'.split()),'Collection fields differ')
            require(packet['schema']=='qwen27b_sidecar_collection_v1' and packet['path']==prior['binding']['remoteRoot']+'/evidence/'+prior['binding']['requestID']+'.json','Wrong exact sidecar')
            data=base64.b64decode(packet['data'],validate=True)
            require(0<len(data)<=256*1024 and packet['bytes']==len(data) and packet['sha256']==digest(data),'Sidecar size/hash differs')
            require(packet['active']==[] and packet['journalBytes']==0 and packet['journalSHA256']==digest(b''),'Fresh process/journal refusal')
            for key in ['identity','journalIdentity']:require(type(packet[key]) is list and len(packet[key])==6 and all(type(n) is int for n in packet[key]),'Missing file identity')
            before=prior['preflightJournals'][rank]
            require(packet['journalIdentity'][:2]==[before['device'],before['inode']],'Canonical journal inode changed')
            publish(out/f'rank{rank}.json',data)
            row.update(status='collected',sidecar=pin(out/f'rank{rank}.json'),transport=pin(out/f'rank{rank}.transport.stdout'),observed={k:v for k,v in packet.items() if k!='data'})
        # Recheck pinned parent evidence after all reads; no remote mutation.
        again=terminal(case);require(again['physicalExecution']==prior['physicalExecution'] and again['controllerResult']==prior['controllerResult'],'Physical evidence changed')
        result['status']='collected'
    except BaseException as error:
        result['error']=type(error).__name__+': '+str(error);raise
    finally:publish(out/'collection.json',(json.dumps(result,indent=2,sort_keys=True)+'\n').encode())
    print(json.dumps(dict(status=result['status'],collection=pin(out/'collection.json'))))
if __name__=='__main__':os.umask(0o077);main()
