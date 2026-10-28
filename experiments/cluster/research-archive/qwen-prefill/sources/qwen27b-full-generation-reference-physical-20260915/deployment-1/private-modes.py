import os,stat
from pathlib import Path
root=Path('/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/supervisor')
assert root.resolve()==root
for d,ds,fs in os.walk(root,followlinks=False):
 for p in [Path(d)]+[Path(d)/n for n in ds+fs]:
  st=p.lstat();assert st.st_uid==os.geteuid() and not stat.S_ISLNK(st.st_mode)
  assert stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)
  p.chmod(0o700 if stat.S_ISDIR(st.st_mode) else 0o600)
print('Private launcher modes set')
