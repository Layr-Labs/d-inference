"""Private package assembly only; no subprocess, native, model or network execution."""
from pathlib import Path
import ast
import base64
import difflib
import hashlib
import json
import shutil
import sys
import uuid

ROOT=Path(__file__).resolve().parent
OLD=ROOT/'qwen-resident-mtp-registered-probe-qualification-20260915'
PARENT=ROOT/'qwen-resident-mtp-probe-parent-interrupt-20260915'
BUILD=ROOT/'owner-retirement-controls-build-20260915'
OUT=ROOT/'qwen-resident-mtp-probe-clean-rerun-20260915'
REMOTE='/Users/developer/DarkbloomDev/owner-native-mtp-probe-clean-20260915'
NATIVE_REMOTE='/Users/developer/DarkbloomDev/qwen-mtp-registered-probe-runtime-20260915'
NATIVE='34fcd255f3bab741586476867da26035cfd0ee0f2ba6ee708551c07d0bdbcba1'
COPIES=[]

def pin(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return dict(bytes=path.stat().st_size,sha256=h.hexdigest())
def save(path,value,compact=False):
 path.parent.mkdir(parents=True,exist_ok=True)
 path.write_text(json.dumps(value,sort_keys=True,indent=None if compact else 2,separators=(',',':') if compact else None)+'\n')
def copy(source,name):
 target=OUT/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
 COPIES.append(dict(source=str(source),destination=name,**pin(source)))
def check_manifest(directory,expected):
 assert pin(directory/'manifest.json')['sha256']==expected
 data=json.loads((directory/'manifest.json').read_bytes())['files']
 rows=[dict(path=k,**v) for k,v in data.items()] if type(data)is dict else data
 for e in rows:assert pin(directory/e['path'])=={k:e[k] for k in ('bytes','sha256')},e['path']
 return len(rows)

assert not OUT.exists()
counts=[check_manifest(OLD,'b025400b718f0c65ec35ef33c40906ca9d7fe339cc6d53bf8e068122a3f3830f'),check_manifest(PARENT,'a3d6f4f8b93dea176ff435efc5d11776883eb79b2e2339a897a0f8308d54a3bd'),check_manifest(BUILD,'5cfbce678c37fda7af42fc34500192a9765c306baf9df3951ab49c51140b03c9')]
OUT.mkdir(mode=0o700)
for n in ['parent_cleanup.py','probe_postflight.py','lease_source.py','test_parent_cleanup.py']:
 copy(PARENT/n,n)
for n in ['monitor.py','reference_resources.py','stage_checks/__init__.py','stage_checks/common.py','probe_values.py','probe_validation.py','probe_io.py','validate_probe.py','test_probe.py']:
 copy(OLD/n,n)
for n in ['configuration/known_hosts','configuration/matrix.json']:
 copy(OLD/n,n)
for n in ['run_physical.py','parent_settings.py']:
 copy(PARENT/n,'lineage/prior-parent/'+n)
for n in ['install_new_tree.py','deploy_copy_only.py']:
 copy(OLD/n,'lineage/prior-parent/'+n)
for directory,label in [(OLD,'prior-probe'),(PARENT,'prior-parent'),(BUILD,'controls-build')]:
 copy(directory/'manifest.json','lineage/'+label+'-manifest.json')
for n in ['HANDOFF.md','source-lineage.json','portable-linkage.json','build-1/execution.json','build-1/source-pins.json']:
 copy(BUILD/n,'lineage/controls-build/'+n)
for n in ['Entries/mtp/main.swift','Entries/controller/Controller.swift','Entries/controller/QualificationInput.swift','Sources/DarkbloomClusterRemote/ClusterDeviceLease.swift','Sources/DarkbloomClusterRemote/ClusterWorkerOwnerService.swift','Sources/DarkbloomClusterProcess/ClusterDeviceExclusion.swift']:
 copy(BUILD/n,'lineage/controls-build/'+n)
copy(ROOT/'cluster-owner-retirement-shutdown-review-20260915/source-review.json','lineage/owner-fix-source-review.json')
copy(ROOT/'qwen-mtp-known-journal-recovery-review-20260915/source-review.json','lineage/administrative-recovery-source-review.json')
copy(OLD/'runtime/bundle.json','native-bundle.json')
bundle=json.loads((BUILD/'bundle-mtp/bundle.json').read_bytes())
assert pin(BUILD/'bundle-mtp/bundle.json')['sha256']=='9dfda2faebdf63293ab5126d9c6ee63aecd5fe6b09cd5952a6cae538500d5bd7'
for e in bundle['files']:
 assert pin(BUILD/'bundle-mtp'/e['path'])=={k:e[k] for k in ('bytes','sha256')}
 copy(BUILD/'bundle-mtp'/e['path'],'controls/'+e['path'])
copy(BUILD/'bundle-mtp/bundle.json','controls/bundle.json')
assert pin(OLD/'runtime/darkbloom-cluster-worker')['sha256']==NATIVE
for e in json.loads((OLD/'runtime/bundle.json').read_bytes())['entries']:
 assert pin(OLD/'runtime'/e['path'])=={k:e[k] for k in ('bytes','sha256')}

request=json.loads((OLD/'request.json').read_bytes()); old_request=request['requestID'];request['requestID']=str(uuid.uuid4());epoch=str(uuid.uuid4())
save(OUT/'request.json',request)
sys.path.insert(0,str(OUT))
from probe_validation import context
from probe_values import agreement,canonical,digest
ctx=context(request)
expected=json.loads((OLD/'configuration/expected-agreement.json').read_bytes());old_epoch=expected['membershipEpoch'];expected.update(membershipEpoch=epoch,requestID=request['requestID'],requestFingerprint=ctx['fingerprint'])
assert expected['rankBuildSHA256']==[NATIVE]*2
agreement_sha=agreement(expected,ctx)
save(OUT/'configuration/expected-agreement.json',expected,True)
controller=json.loads((OLD/'configuration/controller.json').read_bytes());controller.update(membershipEpoch=epoch,requestID=request['requestID'])
for peer in controller['peers']:
 peer['installedOwner']=REMOTE+'/darkbloom-owner-qualification';peer['knownHostsFile']=str(OUT/'configuration/known_hosts')
save(OUT/'configuration/controller.json',controller,True)
for rank in (0,1):
 owner=json.loads((OLD/f'configuration/owner-rank{rank}.json').read_bytes())
 env=owner['workerEnvironment'];env['DARKBLOOM_BENCHMARK_EVIDENCE_DIR']=REMOTE+'/evidence';env['JACCL_IBV_DEVICES']=REMOTE+'/matrix.json'
 assert owner['workerExecutable']==NATIVE_REMOTE+'/darkbloom-cluster-worker'
 save(OUT/f'configuration/owner-rank{rank}.json',owner,True)
# Ready templates keep zero placeholder epoch; actual fresh epoch arrives through authenticated owner open.
for rank in (0,1):
 o=json.loads((OUT/f'configuration/owner-rank{rank}.json').read_bytes()); t=json.loads(base64.b64decode(o['readyTemplateBase64']))
 assert t['ready']['rank']==rank and t['ready']['identity']['membershipEpoch']==str(uuid.UUID(int=0))
 assert [x['buildSHA256'] for x in t['ready']['identity']['peers']]==[NATIVE]*2
 assert o['leaseDirectory']=='/Users/developer/.darkbloom/cluster-device' and o['maximumLifetimeSeconds']==300 and o['stageCut']==4
assert controller['promptTokenIDs']==request['promptTokenIDs'] and controller['expectedTokenIDs'] is None
assert (controller['lifetimeSeconds'],controller['startupSeconds'],controller['requestSeconds'])==(300,90,120)
# Only path constants change; executable parent/retirement/resource behavior stays byte-exact.
parent=(PARENT/'run_physical.py').read_text();updated=parent.replace("REMOTE = '/Users/developer/DarkbloomDev/owner-native-mtp-probe-20260915'",'REMOTE = '+repr(REMOTE)).replace("CONTROLLER = ROOT / 'qwen-resident-mtp-registered-probe-qualification-20260915/controller/owner-controller'","CONTROLLER = BASE / 'controls/owner-controller'")
assert updated!=parent
(OUT/'run_physical.py').write_text(updated)
settings=(PARENT/'parent_settings.py').read_text().replace(str(OLD/'configuration/known_hosts'),str(OUT/'configuration/known_hosts'));(OUT/'parent_settings.py').write_text(settings)
installer=(OLD/'install_new_tree.py').read_text();before_roots="ROOTS = {'owner': Path('/Users/developer/DarkbloomDev/owner-native-mtp-probe-20260915'),\n         'runtime': Path('/Users/developer/DarkbloomDev/qwen-mtp-registered-probe-runtime-20260915')}"
assert before_roots in installer;installer=installer.replace(before_roots,"ROOTS = {'owner': Path("+repr(REMOTE)+")}").replace('Creates two exact NEW private trees','Creates one exact NEW private owner tree')
(OUT/'install_new_tree.py').write_text(installer)
deployer=(OLD/'deploy_copy_only.py').read_text().replace("'qwen-resident-mtp-registered-probe-deployment-20260915'","'qwen-resident-mtp-probe-clean-rerun-deployment-20260915'");(OUT/'deploy_copy_only.py').write_text(deployer)
# Deploy only the corrected owner closure; retain and separately verify old native bundle.
owner_members={e['path']:e for e in bundle['files'] if e['path']!='owner-controller'}
save(OUT/'owner-bundle.json',dict(schema='mtp_clean_rerun_owner_bundle_v1',files=list(owner_members.values()),coherentControlsBundleSHA256=pin(OUT/'controls/bundle.json')['sha256']))
for rank in (0,1):
 files={}
 for name in owner_members:
  files['owner/'+name]=dict(source='controls/'+name,mode=0o700,**pin(OUT/'controls'/name))
 for dest,source in [('bundle.json','owner-bundle.json'),('owner.json',f'configuration/owner-rank{rank}.json'),('matrix.json','configuration/matrix.json'),('monitor.py','monitor.py'),('reference_resources.py','reference_resources.py'),('stage_checks/__init__.py','stage_checks/__init__.py'),('stage_checks/common.py','stage_checks/common.py')]:
  files['owner/'+dest]=dict(source=source,mode=0o600,**pin(OUT/source))
 save(OUT/f'deployment-rank{rank}.json',dict(schema='mtp_probe_copy_only_tree_v1',files=files),True)
policy=json.loads((OLD/'policy.json').read_bytes());policy['files']={n:pin(OUT/n)['sha256'] for n in policy['files']};save(OUT/'policy.json',policy)
# Pin only the actual local launch closure, new control artifacts and explicit metadata.
run_names=['run_physical.py','parent_settings.py','parent_cleanup.py','probe_postflight.py','lease_source.py','monitor.py','reference_resources.py','stage_checks/common.py','stage_checks/__init__.py','configuration/controller.json','configuration/owner-rank0.json','configuration/owner-rank1.json','configuration/matrix.json','configuration/known_hosts']+[str(p.relative_to(OUT)) for p in sorted((OUT/'controls').iterdir())]
save(OUT/'run-pins.json',dict(schema='mtp_clean_rerun_parent_pins_v1',files=[dict(path=str(OUT/n),**pin(OUT/n)) for n in run_names]))
native_files={n:pin(OLD/'runtime'/n) for n in ['bundle.json','darkbloom-cluster-worker','mlx.metallib','mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal']}
save(OUT/'native-runtime-reference.json',dict(localDirectory=str(OLD/'runtime'),remoteDirectory=NATIVE_REMOTE,files=native_files,existingNativeBytesUnchanged=True,deploymentPerformed=False))
save(OUT/'preflight-plan.json',dict(schema='mtp_clean_rerun_root_preflight_plan_v1',ownerDirectory=REMOTE,nativeDirectory=NATIVE_REMOTE,rankDeploymentFiles=['deployment-rank0.json','deployment-rank1.json'],nativeReference='native-runtime-reference.json',requiresEmptyEvidenceDirectory=True,canonicalLease='/Users/developer/.darkbloom/cluster-device/native-device.lease',requiresSameCanonicalEmptyJournal=True,requiresNoOwnerNativeProviderReferenceProcess=True,resources='Exact reference_resources.sample_local + validate_local on each remote host; unchanged 6GiB actual-free/AC/zero swap/pressure bounds',administrativeRecoverySeparate=True,executed=False))
patch=''
for name,before in [('run_physical.py',parent),('parent_settings.py',(PARENT/'parent_settings.py').read_text()),('install_new_tree.py',(OLD/'install_new_tree.py').read_text()),('deploy_copy_only.py',(OLD/'deploy_copy_only.py').read_text())]:
 patch+=''.join(difflib.unified_diff(before.splitlines(True),(OUT/name).read_text().splitlines(True),fromfile='before/'+name,tofile='after/'+name))
(OUT/'assembly.patch').write_text(patch)
# Every top-level executable body is identical; substitutions are module constants/docs only.
for name,base in [('run_physical.py',PARENT),('parent_settings.py',PARENT),('install_new_tree.py',OLD),('deploy_copy_only.py',OLD)]:
 def bodies(text):return [ast.dump(n,include_attributes=False) for n in ast.parse(text).body if isinstance(n,(ast.FunctionDef,ast.ClassDef))]
 current=(OUT/name).read_text()
 if name=='deploy_copy_only.py': current=current.replace("'qwen-resident-mtp-probe-clean-rerun-deployment-20260915'","'qwen-resident-mtp-registered-probe-deployment-20260915'")
 assert bodies(current)==bodies((base/name).read_text()),name
save(OUT/'assembly-lineage.json',dict(schema='mtp_clean_rerun_assembly_v1',verifiedPredecessorMemberCounts=counts,exactCopies=COPIES,freshRequestID=request['requestID'],freshMembershipEpoch=epoch,oldRequestID=old_request,oldMembershipEpoch=old_epoch,requestFingerprint=ctx['fingerprint'],agreementFingerprint=agreement_sha,nativeBinarySHA256=NATIVE,coherentControlManifest=pin(BUILD/'manifest.json'),runtimeAlgorithmChanges=False, changedBodyConstant="deploy_copy_only.main output directory only; inverse AST equality checked",controlSourceDelta='Already reviewed single Service shutdown drain correction; all four Foundation libraries freshly linked with unchanged owner/controller entry sources.',canonicalExclusion='Current ClusterDeviceLease wrapper uses ClusterDeviceExclusion; recorded bytes and path/inode checks included.',testsOrNativeOrRemoteExecuted=False))
for p in OUT.rglob('*.py'):ast.parse(p.read_text(),feature_version=(3,9))
print(json.dumps(dict(directory=str(OUT),requestID=request['requestID'],epoch=epoch,requestFingerprint=ctx['fingerprint'],agreementFingerprint=agreement_sha,controllerConfiguration=pin(OUT/'configuration/controller.json'),policy=pin(OUT/'policy.json'),frozen=False),indent=2))
