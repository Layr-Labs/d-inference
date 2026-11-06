from pathlib import Path
import hashlib,json,os,stat
root=Path('/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/native-diagnostics')
raw=(root/'bundle.json').read_bytes();assert hashlib.sha256(raw).hexdigest()=='31edaba87f91f72ab22a1ff1c1ad94842d2c3cc3129a1b4a0ea91382b6f1bdec'
b=json.loads(raw);seen=set()
for row in b['files']:
 p=root/row['path'];st=p.lstat();assert stat.S_ISREG(st.st_mode) and st.st_uid==os.geteuid() and not(st.st_mode&0o022)
 assert st.st_size==row['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256'];seen.add(row['path'])
actual=set()
for p in root.rglob('*'):
 assert not p.is_symlink()
 if p.is_file():actual.add(str(p.relative_to(root)))
assert actual==seen|{'bundle.json'} and (root/'cluster-inference').stat().st_mode&stat.S_IXUSR
print(json.dumps(dict(verified=True,files=b['files'],bundleSHA256=hashlib.sha256(raw).hexdigest(),modelExecuted=False)))
