#!/bin/bash
# Root orchestrator only. Stages and performs CPU checks; does not run inference.
set -euo pipefail
ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 darkbloom-24 /usr/bin/python3 - <<'PY'
from pathlib import Path
stage=Path('/Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-stage-20260913')
assert not any((p/'.git').exists() for p in (stage,*stage.parents))
stage.mkdir(mode=0o700,parents=True,exist_ok=False)
PY
scp -q -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 /Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-package-20260913.tar darkbloom-24:/Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-stage-20260913/package.tar
ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 darkbloom-24 /Users/developer/.darkbloom/python/bin/python3 - <<'PY'
import hashlib,json,tarfile
from pathlib import Path,PurePosixPath
stage=Path('/Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-stage-20260913')
archive=stage/'package.tar'
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as stream:
  for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
expected='86c548ffd242d22ad4630d7d4ee985607a5d73104eaf03d0f9d01fd6fe86ffd6'
assert sha(archive)==expected,'Transfer SHA256 mismatch'
archive.chmod(0o400)
payload=stage/'payload';payload.mkdir(mode=0o700,exist_ok=False)
with tarfile.open(archive,'r:') as stream:
 members=stream.getmembers();assert len(members)==165
 for item in members:
  path=PurePosixPath(item.name)
  assert item.isfile() and not path.is_absolute() and '..' not in path.parts and '\\' not in item.name
 stream.extractall(payload,filter='data')
manifest='49190b33015157950a1ac4b1af2c13b49fe1e4512c807268c171d845b8086a76'
assert sha(payload/'package-manifest.json')==manifest
receipt=dict(status='staged_not_executed',tar_sha256=expected,package_manifest_sha256=manifest,payload=str(payload),native_runs=0)
(stage/'staging-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
PY
ssh -T -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 darkbloom-24 /Users/developer/.darkbloom/python/bin/python3 /Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-stage-20260913/payload/drivers/run-qwen9-staged-local-tp.py --package /Users/developer/DarkbloomDev/cluster-research/qwen9-peer24-stage-20260913/payload --manifest-sha256 49190b33015157950a1ac4b1af2c13b49fe1e4512c807268c171d845b8086a76 --model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B --check-only
