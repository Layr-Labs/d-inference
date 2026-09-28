"""Pure value/source checks for the new request; no subprocess or remote execution."""
from pathlib import Path
import ast
import base64
import copy
import hashlib
import json
import time
from probe_io import prospective
from probe_validation import compare, context
from probe_values import agreement
from test_probe import fixture

BASE=Path(__file__).resolve().parent
OLD=BASE.parent/'qwen-resident-mtp-registered-probe-qualification-20260915'
PARENT=BASE.parent/'qwen-resident-mtp-probe-parent-interrupt-20260915'
BUILD=BASE.parent/'owner-retirement-controls-build-20260915'

def pin(p):
 raw=p.read_bytes();return dict(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
def read(p):return json.loads(p.read_bytes())
def require_rejection(body):
 try:body()
 except ValueError:return
 raise AssertionError('Stale or incomplete evidence was accepted')

def main():
 started=time.monotonic();groups=[]
 request=read(BASE/'request.json'); old_request=read(OLD/'request.json')
 controller=read(BASE/'configuration/controller.json'); old_controller=read(OLD/'configuration/controller.json')
 expected=read(BASE/'configuration/expected-agreement.json');old_expected=read(OLD/'configuration/expected-agreement.json')
 assert {k for k in request if request[k]!=old_request[k]}=={'requestID'}
 assert {k for k in expected if expected[k]!=old_expected[k]}=={'membershipEpoch','requestID','requestFingerprint'}
 assert {k for k in controller if controller[k]!=old_controller[k]}=={'membershipEpoch','requestID','peers'}
 for p,o in zip(controller['peers'],old_controller['peers']):
  assert {k for k in p if p[k]!=o[k]}=={'knownHostsFile','installedOwner'}
  assert p['identityFile']==o['identityFile'] and p['host']==o['host'] and p['port']==22
 assert (BASE/'configuration/known_hosts').read_bytes()==(OLD/'configuration/known_hosts').read_bytes()
 assert expected['membershipEpoch']==controller['membershipEpoch'] and expected['requestID']==controller['requestID']==request['requestID']
 assert expected['requestFingerprint']==context(request)['fingerprint']
 groups.append('fresh UUID/epoch and exact allowed configuration deltas, unchanged SSH trust bytes')
 for rank in (0,1):
  owner=read(BASE/f'configuration/owner-rank{rank}.json');old=read(OLD/f'configuration/owner-rank{rank}.json')
  assert {k for k in owner if owner[k]!=old[k]}=={'workerEnvironment'}
  assert {k for k in owner['workerEnvironment'] if owner['workerEnvironment'][k]!=old['workerEnvironment'][k]}=={'DARKBLOOM_BENCHMARK_EVIDENCE_DIR','JACCL_IBV_DEVICES'}
  template=json.loads(base64.b64decode(owner['readyTemplateBase64']))['ready']
  assert template['rank']==rank and template['identity']['membershipEpoch']=='00000000-0000-0000-0000-000000000000'
  assert template['identity']['peers']==json.loads(base64.b64decode(controller['readyTemplateBase64']))['ready']['identity']['peers']
  assert template['identity']['peers'][rank]['buildSHA256']==expected['rankBuildSHA256'][rank]
 groups.append('rank templates and native identity stay exact; only new owner-side evidence/matrix paths')
 bundle=read(BASE/'controls/bundle.json');original=read(BUILD/'bundle-mtp/bundle.json')
 assert bundle==original and len(bundle['files'])==6
 for e in bundle['files']:assert pin(BASE/'controls'/e['path'])=={k:e[k] for k in ('bytes','sha256')}
 groups.append('six-file coherent owner/controller/Protocol/Process/Remote/Bootstrap bundle')
 for rank in (0,1):
  plan=read(BASE/f'deployment-rank{rank}.json');assert len(plan['files'])==12
  assert all(n.startswith('owner/') for n in plan['files'])
  for name,e in plan['files'].items():assert pin(BASE/e['source'])=={k:e[k] for k in ('bytes','sha256')}
  required={'owner/'+n for n in ['monitor.py','reference_resources.py','stage_checks/common.py','stage_checks/__init__.py','owner.json','matrix.json','darkbloom-owner-qualification']}
  assert required<=set(plan['files'])
 groups.append('complete 12-file per-rank new-owner deployment closure; native tree is verification-only')
 for name in ['parent_cleanup.py','probe_postflight.py','lease_source.py']:
  assert (BASE/name).read_bytes()==(PARENT/name).read_bytes()
 for name in ['monitor.py','reference_resources.py','stage_checks/common.py','stage_checks/__init__.py','probe_values.py','probe_validation.py','probe_io.py','validate_probe.py']:
  assert (BASE/name).read_bytes()==(OLD/name).read_bytes()
 for name,prior in [('run_physical.py',PARENT),('parent_settings.py',PARENT),('install_new_tree.py',OLD),('deploy_copy_only.py',OLD)]:
  text=(BASE/name).read_text()
  if name=='deploy_copy_only.py':text=text.replace("'qwen-resident-mtp-probe-clean-rerun-deployment-20260915'","'qwen-resident-mtp-registered-probe-deployment-20260915'")
  bodies=lambda x:[ast.dump(n,include_attributes=False) for n in ast.parse(x).body if isinstance(n,(ast.FunctionDef,ast.ClassDef))]
  assert bodies(text)==bodies((prior/name).read_text())
 groups.append('unchanged parent cleanup/alias/resource/validator bodies and normalized copy-output path')
 policy,policy_sha,_=prospective(BASE)
 values=fixture();result=compare(*values)
 assert result['status']=='passed' and result['requestID']==request['requestID'] and result['membershipEpoch']==expected['membershipEpoch']
 require_rejection(lambda:compare(values[0],old_expected,values[2],values[3],values[4]))
 stale=copy.deepcopy(values);stale[2][0]['execution']['membershipEpoch']=old_expected['membershipEpoch']
 require_rejection(lambda:compare(*stale))
 groups.append('fresh prospective policy accepts fabricated new evidence and rejects prior epoch/agreement')
 for key in ['nativeCleanupObserved','ownerDeviceLeaseReleasedObserved']:
  broken=copy.deepcopy(values);broken[3][1][key]=[True,False]
  require_rejection(lambda:compare(*broken))
 stale=copy.deepcopy(values);stale[3][1]['configurationSHA256']=pin(OLD/'configuration/controller.json')['sha256']
 require_rejection(lambda:compare(*stale))
 groups.append('new controller config and bilateral cleanup/release claims remain mandatory')
 for p in BASE.rglob('*.py'):ast.parse(p.read_text(),feature_version=(3,9))
 result=dict(schema='mtp_clean_rerun_assembly_checks_v1',status='passed',groups=groups,groupCount=len(groups),elapsedSeconds=time.monotonic()-started,policySHA256=policy_sha,requestID=request['requestID'],membershipEpoch=expected['membershipEpoch'],requestFingerprint=context(request)['fingerprint'],agreementFingerprint=agreement(expected,context(request)),sourcePins={n:pin(BASE/n)['sha256'] for n in ['check_assembly.py','request.json','configuration/controller.json','configuration/expected-agreement.json','run_physical.py','parent_settings.py','parent_cleanup.py','install_new_tree.py','deploy_copy_only.py','policy.json']},actualCandidateRead=False,subprocessCompilerNativeModelOrNetworkExecuted=False,oldUnchangedBehavioralSuitesReexecuted=False)
 out=BASE/'assembly-checks.json'
 with out.open('x') as f:json.dump(result,f,indent=2,sort_keys=True);f.write('\n')
 print(json.dumps(dict(status='passed',groups=len(groups),elapsedSeconds=result['elapsedSeconds'])))

if __name__=='__main__':main()
