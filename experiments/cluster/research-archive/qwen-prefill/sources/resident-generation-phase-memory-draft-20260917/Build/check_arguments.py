"""Root-only pure argument controls; no model, bootstrap socket, or GPU connection."""
from pathlib import Path
import hashlib,json,os,sys
BASE=Path(__file__).resolve().parent

from owned_process import invoke_controller

def run(attempt):
    assert attempt.isdecimal() and 1<=int(attempt)<=99
    bundle=BASE/('runtime-bundle-'+attempt)
    packaged=json.loads((bundle/'bundle.json').read_bytes())
    built=json.loads((BASE/('native-'+attempt)/'receipt.json').read_bytes())
    assert built['passed'] is True and packaged['buildReceiptSHA256']==hashlib.sha256((BASE/('native-'+attempt)/'receipt.json').read_bytes()).hexdigest()
    NATIVE=bundle/'darkbloom-cluster-worker'
    SHA=next(x['sha256'] for x in packaged['files'] if x['path']=='darkbloom-cluster-worker')
    assert SHA==built['binarySHA256']
    assert hashlib.sha256(NATIVE.read_bytes()).hexdigest()==SHA
    out=BASE/('arguments-'+attempt);out.mkdir(mode=0o700);steps=[]
    def invoke(name,argv,want):
        step=dict(name=name,argv=argv);steps.append(step)
        with (out/(name+'.stdout')).open('xb') as stdout,(out/(name+'.stderr')).open('xb') as stderr:invoke_controller(argv,stdout,stderr,step,timeout=15)
        assert step['exitCode']==want and step['reaped'] and step['groupAbsent'] and not step['killedOwnedGroup']
    receipt=dict(passed=False,steps=steps,nativeModelOrGPUOrRemoteExecuted=False,nativeArgumentsOnly=True,nativeSHA256=SHA)
    try:
        invoke('clock',[str(NATIVE),'clock'],0);now=int((out/'clock.stdout').read_bytes());deadline=str(now+60_000_000_000)
        common=['--model-dir','/does-not-exist','--rank','0','--membership-epoch','11111111-1111-4111-8111-111111111111',
            '--model-id','registered_qwen38_27b','--artifact-sha256','bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463',
            '--configuration-sha256','4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff',
            '--peer0-id','darkbloom-24','--peer0-build-sha256',SHA,'--peer1-id','darkbloom-48','--peer1-build-sha256',SHA,
            '--deadline-uptime-nanoseconds',deadline,'--bootstrap-socket-path','/does-not-exist.sock','--bootstrap-owner-pid',str(os.getpid()),'--bootstrap-deadline-uptime-nanoseconds',deadline]
        for cut,status in [(16,0),(32,1)]:
            name='cut'+str(cut);invoke(name,[str(NATIVE),'check-arguments','--stage-cut',str(cut)]+common,status)
            assert (out/(name+'.stdout')).stat().st_size==0
            err=(out/(name+'.stderr')).read_bytes()
            if cut==16:assert err==b''
            else:assert b'Phase validation worker requires authenticated owner bootstrap and cut16/48' in err and len(err)<=4096
        assert hashlib.sha256(NATIVE.read_bytes()).hexdigest()==SHA;receipt['passed']=True
    finally:(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt
if __name__=='__main__':
    attempt,=sys.argv[1:];print(json.dumps(run(attempt)))
