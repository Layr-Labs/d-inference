"""Root-authorized copy/hash only; no owner/native launch, defaults or existing files changed."""
from pathlib import Path
import hashlib
import io
import json
import shlex
import subprocess
import tarfile
import time
import threading

BASE = Path(__file__).resolve().parent

def pin(path):
    data = path.read_bytes(); return dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())

def main():
    freeze = json.loads((BASE / 'manifest.json').read_bytes())
    for name, expected in freeze['files'].items():
        if pin(BASE / name) != expected: raise RuntimeError('Frozen source changed: ' + name)
    setup = json.loads((BASE / 'configuration/controller.json').read_bytes())
    output = BASE.parent / 'qwen27b-owner-validation-deployment-receipts-20260915'
    output.mkdir(mode=0o700)
    installer = (BASE / 'install_new_tree.py').read_text()
    for rank, peer in enumerate(setup['peers']):
        plan_raw = (BASE / f'deployment-rank{rank}.json').read_bytes()
        plan = json.loads(plan_raw)
        command = ['/usr/bin/ssh', '-T', '-p', str(peer['port']), '-i', peer['identityFile'],
            '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'UserKnownHostsFile=' + peer['knownHostsFile'], '-o', 'ConnectTimeout=5',
            peer['user'] + '@' + peer['host'], shlex.join(['/usr/bin/python3', '-B', '-c', installer])]
        archive_path = output / f'rank{rank}.tar'
        with tarfile.open(archive_path, 'w', format=tarfile.USTAR_FORMAT) as archive:
            for name, entry in plan['files'].items():
                source = BASE / entry['source']
                if pin(source) != {key:entry[key] for key in ('bytes','sha256')}: raise RuntimeError('Transfer source changed')
                info = tarfile.TarInfo(name); info.size=entry['bytes']; info.mode=entry['mode']; info.mtime=0
                with source.open('rb') as stream: archive.addfile(info, stream)
        began = time.monotonic()
        with (output / f'rank{rank}.stdout.json').open('xb') as stdout, (output / f'rank{rank}.stderr').open('xb') as stderr:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr)
            watchdog = threading.Timer(180, process.kill)
            watchdog.daemon = True; watchdog.start()
            failure = None
            try:
                process.stdin.write(plan_raw)
                with archive_path.open('rb') as stream:
                    for block in iter(lambda: stream.read(1_048_576), b''): process.stdin.write(block)
                process.stdin.close()
                code = process.wait(timeout=120)
            except BaseException as error:
                failure = type(error).__name__ + ': ' + str(error)
                process.kill(); process.wait(timeout=10); code = process.returncode
            finally:
                watchdog.cancel()
        record=dict(rank=rank, command=command, exitCode=code, elapsedSeconds=time.monotonic()-began,
            sourceManifestSHA256=hashlib.sha256((BASE/'manifest.json').read_bytes()).hexdigest(),
            deploymentManifestSHA256=hashlib.sha256(plan_raw).hexdigest(), failure=failure,
            stdout=pin(output/f'rank{rank}.stdout.json'), stderr=pin(output/f'rank{rank}.stderr'),
            modelOrOwnerLaunched=False)
        (output/f'rank{rank}.receipt.json').write_text(json.dumps(record,indent=2)+'\n')
        if failure is not None or code != 0 or (output/f'rank{rank}.stderr').stat().st_size: raise RuntimeError('Remote copy/verification failed; retain partial new trees')
        verified=json.loads((output/f'rank{rank}.stdout.json').read_bytes())
        if verified['verified'] != {name:{key:entry[key] for key in ('bytes','sha256')} for name,entry in plan['files'].items()}:
            raise RuntimeError('Remote verification differs')
        print(json.dumps(dict(rank=rank,exitCode=code,verifiedFiles=len(verified['verified']),elapsedSeconds=record['elapsedSeconds'])),flush=True)

if __name__ == '__main__': main()
