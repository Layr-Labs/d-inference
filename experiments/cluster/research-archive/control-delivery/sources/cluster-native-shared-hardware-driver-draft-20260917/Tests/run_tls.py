"""Future granted CPU-only compile and actual loopback TLS qualification."""
import hashlib
import json
import os
from pathlib import Path
import sys
import time
from owned_process import invoke_controller

ROOT=Path(__file__).resolve().parents[1]
def main():
    if len(sys.argv)!=2 or not sys.argv[1].isdigit():raise ValueError('positive attempt required')
    number=int(sys.argv[1])
    if number<1:raise ValueError('positive attempt required')
    output=ROOT/('tls-check-'+str(number));output.mkdir(mode=0o700)
    pins=json.loads((ROOT/'source-inputs.json').read_bytes())
    def check():
        for row in pins:
            raw=Path(row['path']).read_bytes()
            if len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:raise ValueError('source pin differs: '+row['path'])
    check()
    os.environ['GOMAXPROCS']='2'
    os.environ['GO111MODULE']='off'
    source=ROOT/'proposed/provider-swift/Sources/ProviderCore/Coordinator/PrivateClusterTLSAnchor.swift'
    server=output/'tls-server';client=output/'tls-client'
    steps=[('compile-server',['/Users/developer/.local/share/mise/installs/go/1.25.0/bin/go','build','-p','2','-o',str(server),str(ROOT/'Tests/tls_server.go')],90),
           ('compile-client',['xcrun','swiftc','-j','2','-swift-version','6','-warnings-as-errors','-target','arm64-apple-macos14.0','-parse-as-library','-D','NATIVE_PAIR_HARDWARE_EXPERIMENT','-module-cache-path',str(output/'module-cache'),str(source),str(ROOT/'Tests/PrivateClusterTLSCheck.swift'),'-o',str(client)],90),
           ('actual-tls',[sys.executable,'-B',str(ROOT/'Tests/tls_group.py'),str(server),str(client),str(output)],60)]
    receipt={'scope':'actual loopback TLS/URL; no model, remote host, system trust mutation or physical pair qualification','steps':[],'passed':False}
    try:
        for name,command,timeout in steps:
            check();row={'name':name,'argv':command};receipt['steps'].append(row);started=time.monotonic()
            with (output/(name+'.stdout')).open('xb') as out,(output/(name+'.stderr')).open('xb') as err:
                invoke_controller(command,out,err,row,timeout=timeout)
            row['elapsedSeconds']=time.monotonic()-started
            if row['exitCode']!=0 or not row['reaped'] or not row.get('groupAbsent') or row.get('killedOwnedGroup'):raise ValueError('step did not naturally retire: '+name)
            check()
        receipt['passed']=True
    finally:
        with (output/'receipt.json').open('x') as f:json.dump(receipt,f,indent=2,sort_keys=True);f.write('\n')
    print(json.dumps({'passed':True,'output':str(output),'steps':len(steps)},sort_keys=True),flush=True)

if __name__=='__main__':main()
