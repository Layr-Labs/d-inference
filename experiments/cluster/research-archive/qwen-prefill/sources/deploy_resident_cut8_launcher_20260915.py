from pathlib import Path
import hashlib
import json
import shlex
import shutil
import subprocess
import time

root = Path(__file__).resolve().parent
source = root / 'resident-physical-cut8-draft'
destination = root / 'resident-physical-cut8-20260915'
pin = 'ef8dbd342776c0f3975ff5e037a5e2262f9ff02aeb367a268a477bf69d8ec5e0'
assert hashlib.sha256((source / 'manifest.json').read_bytes()).hexdigest() == pin
manifest = json.loads((source / 'manifest.json').read_bytes())
assert len(manifest['files']) == 87
assert not destination.exists()
destination.mkdir()
for row in manifest['files']:
    relative = Path(row['path'])
    assert not relative.is_absolute() and '..' not in relative.parts
    src = source / relative
    assert src.is_file() and not src.is_symlink()
    raw = src.read_bytes()
    assert len(raw) == row['size_bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256']
    dst = destination / relative
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
shutil.copy2(source / 'manifest.json', destination / 'manifest.json')
verify = '''from pathlib import Path
import hashlib,json,sys
p=Path(sys.argv[1]);pin=sys.argv[2]
assert hashlib.sha256((p/'manifest.json').read_bytes()).hexdigest()==pin
m=json.loads((p/'manifest.json').read_bytes())
assert len(m['files'])==87
for row in m['files']:
 f=p/row['path'];assert f.is_file() and not f.is_symlink()
 raw=f.read_bytes();assert len(raw)==row['size_bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
print(json.dumps({'verifiedMembers':len(m['files']),'manifestSHA256':pin,'destination':str(p)}))
'''
results = []
for host in ('darkbloom-24', 'darkbloom-48'):
    start = time.monotonic()
    check = ['/usr/bin/python3', '-c', 'import os,sys;assert not os.path.lexists(sys.argv[1])', str(destination)]
    subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, shlex.join(check)], check=True, timeout=15)
    subprocess.run(['scp', '-q', '-r', str(destination), host + ':' + str(destination)], check=True, timeout=45)
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', host, shlex.join(['/usr/bin/python3', '-', str(destination), pin])],
                            input=verify, capture_output=True, text=True, check=True, timeout=30)
    assert not result.stderr
    item = json.loads(result.stdout)
    item.update(host=host, copyAndVerifySeconds=time.monotonic()-start)
    results.append(item)
    (root/'resident-cut8-launcher-remote-verification-20260915.json').write_text(json.dumps(results, indent=2)+'\n')
    print(json.dumps(item), flush=True)
