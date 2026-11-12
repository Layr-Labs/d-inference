"""Freeze the completed synthetic CPU test evidence once; no native execution."""
from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import re

HERE=Path(__file__).resolve().parent
if (HERE/'manifest.json').exists():
    raise SystemExit('Freeze already exists; preserve it and create a separately named revision if needed')
def pin(path):
    path=Path(path);data=path.read_bytes()
    return dict(path=str(path),byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())
def write(name,value):
    (HERE/name).write_text(json.dumps(value,indent=2,sort_keys=True,allow_nan=False)+'\n')
spec=importlib.util.spec_from_file_location('frozen_long_reference_oracle',HERE/'qwen_long_prefill_reference_audit.py')
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
dependencies=a.verify_pins()
log=(HERE/'test-output.log').read_text()
match=re.search(r'Ran (\d+) tests in [\d.]+s\n\nOK\s*$',log)
if match is None or int(match[1])!=51:
    raise SystemExit('Missing expected completed 51-test passing log')
prompt=HERE.parent/'long-prefill-input-20260914/prompt-8192.json'
prompt_sha='ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'
tokenization=HERE.parent/'long-prefill-input-20260914/tokenization.json'
if pin(tokenization)['sha256']!='b9e70184956db293c3d76d224728ae773c51971a60244cd930aea9e06bf67320':
    raise SystemExit('Authorized tokenization receipt changed')
a.prompt_tokens(prompt.read_bytes(),prompt_sha)
helper=pin(HERE/'qwen_long_prefill_reference_audit.py')
tests=pin(HERE/'test_qwen_long_prefill_reference_audit.py')
factory=pin(HERE/'reference_fixture.py')
receipt=dict(kind='qwen_long_prefill_reference_cpu_validator_tests',schemaVersion=1,status='passed',exitCode=0,
    testsPassed=int(match[1]),helperPath=helper['path'],helperSHA256=helper['sha256'],testPath=tests['path'],testSHA256=tests['sha256'],
    fixturePath=factory['path'],fixtureSHA256=factory['sha256'],testLog=pin(HERE/'test-output.log'),
    completedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    command=['python3','-B',tests['path']],authorizedPrompt=pin(prompt),tokenization=pin(tokenization),
    nativeCandidateOutputAccessed=False,freezeBeforeFirstCandidateAccess=True,freezeBeforeNativeExecution=False,
    independenceNote='Root began native execution while the prospective oracle was being completed; no candidate output was accessed or disclosed before this freeze.',
    testsUseSyntheticNumericalValues=True,nativeInferencePerformed=False,gpuWorkPerformed=False,sshPerformed=False,
    modelPayloadReadsPerformed=False,newNativeProcessInspectionPerformed=False,
    sourceScope='Frozen source drafts and metadata controls; current reference CLI schema observed separately, actual executable/runtime provenance remains root-owned.',
    frozenDependencies=dependencies,
    currentCLIContractSource=pin(HERE.parent.parent/'d-inference/experiments/cluster/inference/Sources/ClusterInference/QwenLongPrefillReferenceCLI.swift'),
    numericalCoverage=dict(frames=16,finalTokens=8192,finalStateEntries=72,finalStateLogicalBytes=319946784,
        reconstructedNativeLogitBytes=496640,reconstructedOffsetComponents=8,opaqueNumericalStateDigests=64),
    limitations=['Synthetic passing records do not qualify a native model output.',
        'The 64 non-offset state digests and native source/commit/retirement assertions require independent archived native provenance.',
        'No timing, physical transport, representative workload, process-memory bound, or speedup claim is established.'])
if a.verify_pins()!=dependencies or pin(prompt)['sha256']!=prompt_sha:
    raise SystemExit('Frozen dependencies or prompt changed during receipt creation')
write('cpu-tests.json',receipt)
files=[pin(HERE/name) for name in ['qwen_long_prefill_reference_audit.py','reference_fixture.py',
    'test_qwen_long_prefill_reference_audit.py','test-output.log','README.md','freeze_cpu_audit.py','cpu-tests.json']]
write('manifest.json',dict(kind='qwen_long_prefill_reference_cpu_validator_freeze',schemaVersion=1,status='frozen',files=files,
    nativeCandidateOutputAccessed=False,freezeBeforeFirstCandidateAccess=True,freezeBeforeNativeExecution=False))
print(json.dumps(dict(helper=helper,fixture=factory,receipt=pin(HERE/'cpu-tests.json'),manifest=pin(HERE/'manifest.json')),indent=2))
