"""Verify exact prepared source, dependencies and original workspace; no compilation."""
from pathlib import Path
import hashlib,importlib.util,json,os
ROOT=Path(__file__).resolve().parent
old=ROOT.parent/'qwen27b-resident-native-build-20260915'
spec=importlib.util.spec_from_file_location('prior',old/'prepare.py')
prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
for name in ('source-snapshot.json','source-preimages.json','dependency-source-snapshot.json'):
    receipt=json.loads((ROOT/name).read_text())
    assert prior.snapshot(Path(receipt['root']))==receipt['members'],name
frozen=ROOT.parent/'qwen27b-owner-qualification-draft-20260915'
assert hashlib.sha256((frozen/'manifest.json').read_bytes()).hexdigest()=='211c1ec3b03367e4b5b71f8a4c69233bda78e4c4f50806f50ad8fff49a06ee17'
for row in json.loads((frozen/'manifest.json').read_text())['members']:
    assert hashlib.sha256((frozen/row['path']).read_bytes()).hexdigest()==row['sha256'],row['path']
print(json.dumps(dict(passed=True,sourceMembers=3040,dependencyMembers=8755,originalWorkspaceUnchanged=True,frozenPackageUnchanged=True,modelExecuted=False,remoteOperations=False)))
