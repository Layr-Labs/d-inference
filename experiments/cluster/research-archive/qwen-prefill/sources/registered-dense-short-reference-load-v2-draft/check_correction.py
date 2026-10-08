#!/usr/bin/env python3
"""Source/metadata correction checks, not Swift execution or model validation."""
from pathlib import Path
import hashlib,json,difflib
D=Path(__file__).resolve().parent
A=D.parent/'registered-dense-short-reference-load-draft'

def sha(raw):return hashlib.sha256(raw).hexdigest()
def require(value,message):
    if not value:raise AssertionError(message)

def run():
    require(sha((A/'manifest.json').read_bytes())=='0ee6fcc7d45ac60a20c9c3b31547edf7cc1518cab582482d9f1dec3a19c4e16a','V1 manifest changed')
    for r in json.loads((A/'manifest.json').read_text())['files']:
        raw=(A/r['path']).read_bytes();require(len(raw)==r['bytes'] and sha(raw)==r['sha256'],'V1 member changed')
    old=(A/'QwenDenseShortReferenceLoadBudget.swift').read_text()
    before='source.tensors.allSatisfy({ ["uint32", "bfloat16"].contains($0.loadedDType) })'
    after='source.tensors.allSatisfy({ $0.loadedDType ==\n                  ["U32": "uint32", "BF16": "bfloat16", "F32": "float32"][$0.canonical.sourceDType] })'
    require(old.count(before)==1 and (D/'QwenDenseShortReferenceLoadBudget.swift').read_text()==old.replace(before,after),'runtime differs beyond exact source/loaded dtype map')
    previous=json.loads((A/'fixture-source-list.json').read_text()); current=json.loads((D/'fixture-source-list.json').read_text())
    require(len(current['sources'])==38 and current['stdin']==previous['stdin'],'fixture source count/stdin changed')
    changed=[]
    for oldr,newr in zip(previous['sources'],current['sources']):
        raw=Path(newr['path']).read_bytes();require(len(raw)==newr['bytes'] and sha(raw)==newr['sha256'],'V2 source pin differs')
        if oldr!=newr:changed.append(Path(newr['path']).name)
    require(changed==['QwenDenseShortReferenceLoadBudget.swift','ShortReferenceLoadCheck.swift'],'unrelated source override')
    metadata=Path(current['stdin']['path']).read_bytes()
    require(sha(metadata)==current['stdin']['sha256'] and len(metadata)==current['stdin']['bytes'],'retained metadata changed')
    data=json.loads(metadata)
    expected={'nine':{'U32':250,'BF16':653,'F32':24},'twentySeven':{'U32':498,'BF16':1349}}
    counts={}
    for name in expected:
        tensors=data[name]['canonicalTensors'];actual={}
        for t in tensors:actual[t['sourceDType']]=actual.get(t['sourceDType'],0)+1
        require(actual==expected[name],'registered source dtype inventory changed')
        f32=[t for t in tensors if t['sourceDType']=='F32']
        require(all(t['name'].endswith('.linear_attn.A_log') and t['shape']==[32] and t['byteCount']==128 for t in f32),'registered F32 identity changed')
        counts[name]=dict(types=actual,f32_bytes=sum(t['byteCount'] for t in f32))
    fixture=(D/'ShortReferenceLoadCheck.swift').read_text(); start=fixture.index('        let f32 = observed.tensors.filter')
    end=fixture.index('        try require(label + " complete full ownership without inert storage"',start)
    removed=fixture[:start]+fixture[end:]
    require(removed.replace('accepted.count == 22, rejected.count == 101','accepted.count == 20, rejected.count == 98')==(A/'ShortReferenceLoadCheck.swift').read_text(),'old fixture bodies changed')
    require(current['prospective_cases']==dict(accepted=22,rejected=101),'V2 case contract changed')
    correction='';root='experiments/cluster/inference/'
    for name in ['QwenDenseShortReferenceLoadBudget.swift','ShortReferenceLoadCheck.swift']:
        target=root+('Sources/ClusterInference/' if name.startswith('Qwen') else 'Tests/ShortReferenceLoading/')+name
        correction+=''.join(difflib.unified_diff((A/name).read_text().splitlines(True),(D/name).read_text().splitlines(True),fromfile='a/'+target,tofile='b/'+target))
    require(correction==(D/'correction.patch').read_text(),'two-file correction patch differs')
    native=root+'Sources/ClusterInference/'
    runtime=''.join(difflib.unified_diff((A/'originals/VerifiedQwenDiagnosticLoading.swift').read_text().splitlines(True),(A/'proposed/VerifiedQwenDiagnosticLoading.swift').read_text().splitlines(True),fromfile='a/'+native+'VerifiedQwenDiagnosticLoading.swift',tofile='b/'+native+'VerifiedQwenDiagnosticLoading.swift'))
    for p in sorted(A.glob('Qwen*.swift')):
        source=D/p.name if p.name=='QwenDenseShortReferenceLoadBudget.swift' else p
        runtime+=''.join(difflib.unified_diff([],source.read_text().splitlines(True),fromfile='/dev/null',tofile='b/'+native+p.name))
    require(runtime==(D/'runtime.patch').read_text(),'whole runtime patch differs')
    for r in json.loads((D/'diagnosis-pins.json').read_text())['files']:
        raw=Path(r['path']).read_bytes();require(len(raw)==r['bytes'] and sha(raw)==r['sha256'],'diagnosis source/evidence pin changed')
    return dict(kind='short_full_reference_dtype_correction_source_checks',schema_version=1,passed=True,
        v1_frozen_members_unchanged=16,fixture_sources=38,unchanged_fixture_sources=36,
        runtime_delta='one source-to-loaded dtype predicate',unchanged_previous_case_bodies=True,
        retained_metadata_dtype_counts=counts,prospective_swift_cases=dict(accepted=22,rejected=101),
        failed_v1_cpu_receipt_inspected=True,v2_swift_compiler_or_fixture_executed=False,
        model_candidate_or_payload_accessed=False)

if __name__=='__main__':print(json.dumps(run(),indent=2,sort_keys=True))
