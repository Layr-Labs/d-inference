from pathlib import Path
import subprocess,time,json,os,signal,hashlib
root=Path('/Users/developer/DarkbloomDev/cluster-research');package=root/'peer24-short-reference-package-20260914';bundle=package/'unpacked/bundle';run=root/'runs/dense-stage-load-9b-stage0-sampled-peer24-20260914';trace=package/'stage0-sample.txt'
assert not run.exists() and not trace.exists()
args=['python3','-B',str(package/'unpacked/launcher/run_selected_stage_load.py'),'--runtime','/Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime','--release',str(bundle),'--model-dir','/Users/developer/DarkbloomDev/models/Qwen3.5-9B','--profile','registered_qwen35_9b','--stage-index','0','--expected-native-sha256','e3df3d3b272d6d18d86a6a666cc0d6fc8e822f068394052087eecb16445dbaf9','--output',str(run),'--reuse-bundle',str(bundle),'--expected-bundle-manifest-sha256','bb44960307dadfcd40ab2c673a6ae2ec74021851c4ed1a3cbadd6f924fd7c22d']
sampler=None;nativePID=None;started=time.monotonic()
with (package/'sampled-parent.stdout').open('xb') as po,(package/'sampled-parent.stderr').open('xb') as pe,(package/'sampler.stdout').open('xb') as so,(package/'sampler.stderr').open('xb') as se:
 parent=subprocess.Popen(args,stdout=po,stderr=pe,start_new_session=True)
 try:
  deadline=time.monotonic()+8
  while time.monotonic()<deadline and parent.poll() is None:
   try:r=json.loads((run/'receipt.json').read_text())
   except (FileNotFoundError,json.JSONDecodeError):time.sleep(.02);continue
   nativePID=r.get('nativePID')
   if type(nativePID) is int:
    sampler=subprocess.Popen(['/usr/bin/sample',str(nativePID),'4','1','-mayDie','-file',str(trace)],stdout=so,stderr=se,start_new_session=True)
    break
   time.sleep(.02)
  parent.wait(timeout=155)
 finally:
  if parent.poll() is None:
   os.killpg(parent.pid,signal.SIGTERM)
   try:parent.wait(timeout=15)
   except subprocess.TimeoutExpired:os.killpg(parent.pid,signal.SIGKILL);parent.wait(timeout=5)
  if sampler is not None:
   try:sampler.wait(timeout=15)
   except subprocess.TimeoutExpired:os.killpg(sampler.pid,signal.SIGTERM);sampler.wait(timeout=5)
result={'kind':'guarded_selected_stage_refusal_stack_diagnostic','parentExitCode':parent.returncode,'nativePID':nativePID,'samplerExitCode':None if sampler is None else sampler.returncode,'elapsedSeconds':round(time.monotonic()-started,3),'extraSamplingMayAffectTimingAndMemory':True,'nativeAndParentPoliciesUnchanged':True,'traceExists':trace.exists()}
(package/'sampled-stage0-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));print((package/'sampled-parent.stdout').read_text());print((package/'sampler.stderr').read_text()[-1500:])
