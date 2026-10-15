"""One owned group containing a real loopback TLS server and Swift verifier."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

def main():
    server_binary,client_binary,root=Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3])
    # The outer reviewed helper owns this still-live leader and its full group.
    # Children deliberately inherit this group, rather than detach from it.
    with (root/'server.stdout').open('xb') as out,(root/'server.stderr').open('xb') as err:
        server=subprocess.Popen([str(server_binary),str(root)],stdin=subprocess.PIPE,stdout=out,stderr=err)
        try:
            deadline=time.monotonic()+5
            while not (root/'ready.json').exists():
                if server.poll() is not None:raise RuntimeError('TLS fixture server ended before ready')
                if time.monotonic()>=deadline:raise TimeoutError('TLS fixture server readiness')
                time.sleep(.01)
            with (root/'client.stdout').open('xb') as cout,(root/'client.stderr').open('xb') as cerr:
                client=subprocess.Popen([str(client_binary),str(root)],stdin=subprocess.DEVNULL,stdout=cout,stderr=cerr)
                try:code=client.wait(timeout=38)
                except BaseException:
                    if client.returncode is None:client.kill()
                    client.wait(timeout=5)
                    raise
            if code!=0:raise RuntimeError('actual TLS client fixture failed')
        finally:
            server.stdin.close()
            try:server_code=server.wait(timeout=7)
            except BaseException:
                if server.returncode is None:server.kill()
                server.wait(timeout=5)
                raise
    if server_code!=0:raise RuntimeError('TLS fixture server failed')
    result=json.loads((root/'client-result.json').read_bytes())
    if result['cases']!={'valid':'ready','untrusted':'tls-refused','wrong-anchor':'tls-refused','wrong-host':'tls-refused','expired':'tls-refused','wrong-url':'refused-before-connect'}:raise ValueError('six exact actual TLS cases')
    counts=json.loads((root/'server-result.json').read_bytes())
    if counts!={'valid':1,'wrong-host':0,'expired':0}:raise ValueError('unexpected actual upgraded connections')
    print(json.dumps({'cases':result['cases'],'actualServerUpgrades':counts,'bothChildrenReaped':True},sort_keys=True),flush=True)

if __name__=='__main__':main()
