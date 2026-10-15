"""Run the hash-bound, read-only Foundation/IOKit probe on both lab Macs."""
from pathlib import Path
import hashlib
import json
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'power-probe-actual'
sys.path.insert(0, str(ROOT.parent / 'gemma4-decode-optimization-20260920/harness-v2'))
from parent_settings import SSH

BODY = r'''
import hashlib,json,os,pathlib,signal,subprocess,sys
signal.signal(signal.SIGALRM,lambda *_:os._exit(124));signal.alarm(20)
root=pathlib.Path('/Users/developer/DarkbloomDev/gemma4-power-probe-20260920-v1')
assert not root.exists() and root.parent.resolve()==root.parent
data=sys.stdin.buffer.read(1000001)
assert 0<len(data)<=1000000 and hashlib.sha256(data).hexdigest()==sys.argv[1]
os.umask(0o077);root.mkdir(mode=0o700)
binary=root/'ResourceGuardProbe'
binary.write_bytes(data);binary.chmod(0o700)
result=subprocess.run([str(binary),'--iterations','256'],stdin=subprocess.DEVNULL,capture_output=True,timeout=15)
(root/'stdout.json').write_bytes(result.stdout);(root/'stderr').write_bytes(result.stderr)
print(json.dumps(dict(exitCode=result.returncode,binarySHA256=sys.argv[1],stdout=result.stdout.decode(),stderr=result.stderr.decode())))
'''


def main():
    build = json.loads((OUT / 'compile.json').read_bytes())
    binary = (OUT / 'ResourceGuardProbe').read_bytes()
    assert build['exitCode'] == 0 and hashlib.sha256(binary).hexdigest() == build['binarySHA256']
    for host in ['darkbloom-24', 'darkbloom-48']:
        result = subprocess.run(SSH + [host, shlex.join(['/usr/bin/python3', '-B', '-c', BODY,
                                                         build['binarySHA256']])],
                                input=binary, capture_output=True, timeout=25)
        with (OUT / (host + '.json')).open('x') as stream:
            json.dump(dict(sshExitCode=result.returncode, stdout=result.stdout.decode(),
                           stderr=result.stderr.decode()), stream, indent=2)
        assert result.returncode == 0 and not result.stderr
        response = json.loads(result.stdout)
        assert response['exitCode'] == 0 and not response['stderr']
        report = json.loads(response['stdout'])
        assert report['iterations'] == 256 and report['stableMismatches'] == 0 and report['unavailable'] == 0
        print(json.dumps(dict(host=host, stableMismatches=report['stableMismatches'], transitions=report['transitions'],
                              timings={row['name']: row['median'] for row in report['timings']})), flush=True)


if __name__ == '__main__':
    main()
