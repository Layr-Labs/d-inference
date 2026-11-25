"""Source-only compatibility checks; no model, native, network or candidate IO."""
import ast
import difflib
import hashlib
import json
from pathlib import Path
import re
import short_parity_contract as contract

D=Path(__file__).resolve().parent
NATIVE=D.parent/'registered-dense-short-parity-draft'
EXPECTED_NATIVE_MANIFEST='73afb184abf8ef290df1d9e7ec7624a7d4087487ec7da4eccd8d6d8352219586'
EXPECTED_PARENT_MANIFEST='21d0cbfdadb6876fd5dab8a4eab11c35f3c1ec2d89463d8ab0b7604e527fc4b6'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def pin(path):return dict(path=str(path),sha256=sha(path),sizeBytes=path.stat().st_size)
def function(path,name):return next(x for x in ast.parse(path.read_text()).body if isinstance(x,ast.FunctionDef) and x.name==name)
def fields(source,name):
    text=source.split('struct '+name+': Encodable {',1)[1].split('\n}',1)[0].split('    init(',1)[0]
    return set(re.findall(r'(?:\blet\s+|,\s*)([A-Za-z_]\w*)\s*(?:=|:)',text))


def check():
    for path in D.glob('*.py'):ast.parse(path.read_text(),feature_version=(3,9))
    old=D/'originals/stage_load_contract.py'
    assert sha(D/'originals/manifest.json')==EXPECTED_PARENT_MANIFEST
    upstream=D.parent/'selected-stage-load-parent-v2-draft'
    original_manifest=json.loads((upstream/'manifest.json').read_text())
    assert sha(upstream/'manifest.json')==EXPECTED_PARENT_MANIFEST
    for f in original_manifest['files']:
        assert sha(upstream/f['path'])==f['sha256']
    for name in ['tiny_support.py','prefill_compute_archive.py','owned_bundle_reference.py','stage_load_contract.py']:
        assert (D/name).read_bytes()==(upstream/name).read_bytes()
    resource=function(old,'resource_policy')
    for node in ast.walk(resource):
        if isinstance(node,ast.Constant) and isinstance(node.value,str):node.value=node.value.replace('qwen-dense-stage-load-check','qwen-dense-short-parity-check')
    assert ast.dump(resource)==ast.dump(function(D/'short_parity_contract.py','resource_policy'))
    for name in ['observe','sha','interrupted']:
        a=function(D/'originals/run_selected_stage_load.py',name);b=function(D/'run_short_parity.py',name)
        for node in ast.walk(a):
            if isinstance(node,ast.Constant) and isinstance(node.value,str):node.value=node.value.replace('Selected-stage','Short-parity').replace('selected-stage','short-parity')
        assert ast.dump(a)==ast.dump(b)
    assert (contract.MINIMUM_FREE,contract.NATIVE_SECONDS,contract.PARENT_SECONDS,contract.MAX_STDERR)==(6*1024**3,120,135,65536)
    assert [x['maximumSampledRSSBytes'] for x in contract.PROFILES.values()]==[8*1024**3,20*1024**3]
    assert sha(NATIVE/'manifest.json')==EXPECTED_NATIVE_MANIFEST
    types=(NATIVE/'proposed/QwenDenseShortParityTypes.swift').read_text()
    assert fields(types,'QwenDenseShortBaselineCheckpoint')==contract.BASE_KEYS
    assert fields(types,'QwenDenseShortParityReport')==contract.FINAL_KEYS
    assert fields(types,'QwenDenseShortPairComparisonReport')==contract.PAIR_KEYS
    cli=(NATIVE/'proposed/QwenDenseShortParityCLI.swift').read_text()
    block=cli.split('let allowed = Set([',1)[1].split('])',1)[0]
    flags=set(re.findall(r'"(--[a-z0-9-]+)"',block))
    assert flags==set(contract.native_command('/exe','/model','registered_qwen35_9b','/prompt','/teacher','a'*64,'b'*64)[1::2])
    output=(NATIVE/'proposed/QwenDenseShortParityOutput.swift').read_text()
    assert 'recordByteLimit = 32 * 1_048_576, totalByteLimit = 64 * 1_048_576' in output
    assert 'bytes.count < Self.recordByteLimit' in output and 'bytes.append(10)' in output
    entry=(NATIVE/'proposed/QwenDenseShortParityEntry.swift').read_text()
    assert 'requestID: UUID()' in entry
    assert 'output.publish(baseline, as: .baseline' in entry and 'output.publish(result, as: .comparison' in entry
    return dict(kind='short_parity_parent_source_checks',passed=True,python39Syntax=True,
        exactInheritedHelpers=True,resourceASTChangesOnlyMode=True,ownedObservationASTUnchanged=True,
        closedNativeTopDTOsAndEightFlagsMatch=True,nativeManifest=pin(NATIVE/'manifest.json'),
        nativeSources=[pin(NATIVE/'proposed'/name) for name in ['QwenDenseShortParityTypes.swift','QwenDenseShortParityCLI.swift','QwenDenseShortParityOutput.swift','QwenDenseShortParityEntry.swift','QwenDenseShortParityBinding.swift']],
        sources=[pin(p) for p in sorted(D.glob('*.py'))],candidateNativeCompilerSSHOrModelPayloadAccess=False)


if __name__=='__main__':print(json.dumps(check(),indent=2,sort_keys=True))
