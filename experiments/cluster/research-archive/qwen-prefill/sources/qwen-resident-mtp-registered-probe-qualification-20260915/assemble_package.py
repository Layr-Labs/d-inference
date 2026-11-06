"""Local-only assembly of exact existing binaries/resources and narrow path changes."""
from pathlib import Path
import ast
import hashlib
import json
import shutil
import subprocess

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
records = []

def pin(path):
    raw = path.read_bytes()
    return dict(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())

def copy(source, relative):
    target = BASE / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if pin(target) != pin(source): raise RuntimeError('Refuse changed destination: ' + relative)
    else:
        shutil.copy2(source, target)
    records.append(dict(source=str(source), destination=relative, **pin(source)))

for name in ('monitor.py', 'reference_resources.py', 'stage_checks/common.py', 'stage_checks/__init__.py', 'lease_source.py'):
    copy(ROOT / 'owner-timing-serial-wakeup-20260915' / name, name)
for name in ('owner-controller', 'libDarkbloomClusterProtocol.dylib', 'libDarkbloomClusterProcess.dylib',
             'libDarkbloomClusterBootstrap.dylib', 'libDarkbloomClusterRemote.dylib'):
    copy(ROOT / 'owner-ssh-qualification-20260915/build-v3' / name, 'controller/' + name)
owner_bundle = ROOT / 'owner-wakeup-qualification-bundle-20260915'
for entry in json.loads((owner_bundle / 'bundle.json').read_bytes())['files']:
    source = owner_bundle / entry['path']
    assert pin(source) == {key: entry[key] for key in ('bytes', 'sha256')}
    copy(source, 'owner/' + entry['path'])
copy(owner_bundle / 'bundle.json', 'owner/bundle.json')
native_bundle = ROOT / 'qwen-resident-mtp-registered-probe-native-build-20260915/runtime-bundle'
for entry in json.loads((native_bundle / 'bundle.json').read_bytes())['entries']:
    source = native_bundle / entry['path']
    assert pin(source) == {key: entry[key] for key in ('bytes', 'sha256')}
    copy(source, 'runtime/' + entry['path'])
copy(native_bundle / 'bundle.json', 'runtime/bundle.json')
upstream = ROOT / 'resident-owner-timing-wakeup-bundle-20260915'
for name in ('upstream/DarkbloomClusterRemote/ClusterDeviceLease.swift', 'upstream/DarkbloomClusterRemote/ClusterWorkerOwnerService.swift',
             'manifest.json', 'main-input-pins.json', 'module-delta.json', 'current-artifacts.json'):
    copy(upstream / name, 'lineage/wakeup/' + name)
for name in ('Controller.swift', 'QualificationInput.swift'):
    copy(ROOT / 'owner-ssh-qualification-20260915/Sources' / name, 'lineage/controller/' + name)
copy(ROOT.parent / 'd-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterProcess/ClusterDeviceExclusion.swift', 'lineage/current/ClusterDeviceExclusion.swift')
copy(ROOT.parent / 'd-inference/provider-swift/Sources/ProviderCore/Config/ClusterConfigurationPaths.swift', 'lineage/current/ClusterConfigurationPaths.swift')
copy(ROOT / 'qwen-resident-mtp-registered-probe-native-build-20260915/build-handoff/HANDOFF.md', 'lineage/native-build-HANDOFF.md')
copy(ROOT / 'qwen-resident-mtp-registered-probe-native-build-20260915/build-handoff/manifest.json', 'lineage/native-build-manifest.json')
# Retain the exact whole upstream wrapper plus prove all function/class ASTs unchanged.
source = ROOT / 'owner-native-generation128-20260915/run_physical.py'
copy(source, 'lineage/run_physical.original.py')
text = source.read_text().replace("REMOTE = '/Users/developer/DarkbloomDev/owner-native-generation128-20260915'",
    "REMOTE = '/Users/developer/DarkbloomDev/owner-native-mtp-probe-20260915'")
text = text.replace("CONTROLLER = ROOT / 'owner-ssh-qualification-20260915/build-v3/owner-controller'", "CONTROLLER = BASE / 'controller/owner-controller'")
text = text.replace("SSH = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5']",
    "SSH = ['/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=/Users/developer/DarkbloomDev/cluster-research/owner-ssh-preflight-20260915/known_hosts', '-i', '/Users/developer/.ssh/id_ed25519_darkbloom_dev']")
(BASE / 'run_physical.py').write_text(text)
def bodies(text):
    return [ast.dump(node, include_attributes=False) for node in ast.parse(text).body if isinstance(node, (ast.FunctionDef, ast.ClassDef))]
assert bodies(text) == bodies(source.read_text())
records.append(dict(source=str(source), destination='run_physical.py', original=pin(source), final=pin(BASE/'run_physical.py'),
    allFunctionAndClassASTsUnchanged=True, changes=['private remote directory', 'local exact controller closure', 'explicit key and pinned known-host SSH flags']))
(BASE/'assembly-lineage.json').write_text(json.dumps(dict(schema='mtp_probe_package_assembly_v1', files=records),indent=2)+'\n')
print(json.dumps(dict(copied=len(records), wrapperBodiesPreserved=True)))
