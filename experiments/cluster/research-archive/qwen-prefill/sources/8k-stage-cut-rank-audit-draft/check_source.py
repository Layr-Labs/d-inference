"""Source-only proof of the narrow rank/container variant."""
import ast
import hashlib
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
OLD=HERE.parent/'long-prefill-rank-audit-draft'


def defs(raw):
    return {x.name:ast.dump(x,include_attributes=False) for x in ast.parse(raw).body if isinstance(x,ast.FunctionDef)}


def check():
    pins=json.loads((HERE/'original-helper-pins.json').read_bytes())
    for name,pin in pins.items():assert hashlib.sha256((OLD/name).read_bytes()).hexdigest()==pin,name
    for name in ['rank_trace.py','rank_wire.py']:
        assert (OLD/name).read_bytes()==(HERE/('cut12_'+name)).read_bytes(),name
    old=(OLD/'qwen_long_prefill_rank_audit.py').read_text()
    new=(HERE/'qwen_long_prefill_rank_cut12_audit.py').read_text()
    a,b=defs(old),defs(new)
    assert set(a)==set(b)
    assert {name for name in a if a[name]!=b[name]}=={'check_rank_pair','validate'}
    before=next(x for x in ast.parse(old).body if isinstance(x,ast.FunctionDef) and x.name=='check_rank_pair')
    after=next(x for x in ast.parse(new).body if isinstance(x,ast.FunctionDef) and x.name=='check_rank_pair')
    source=ast.get_source_segment(old,before)
    one="    baseline = a.validate_reports(baseline_rows, prompt_data, expected_prompt_sha256)\n    reference = baseline_rows[1]['evidence']"
    two="    dependencies.pair_oracle().check_pair(a, baseline_rows, prompt_data, expected_prompt_sha256)\n    reference = baseline_rows[0]['reference']\n    baseline = a.check_reference(reference, prompt_data, expected_prompt_sha256)"
    assert source.count(one)==1
    source=source.replace(one,two).replace("scope='registered9b_long_prefill_8192_chunk512_output1_v4_rank_pair'",
        "scope='registered9b_long_prefill_8192_chunk512_output1_cut12_v4_rank_pair'")
    assert source==ast.get_source_segment(new,after)
    fixture=(HERE/'cut12_rank_fixture.py').read_text()
    assert 'baseline_ready' not in fixture and 'baseline_report' not in fixture
    assert 'baseline=pair' in fixture
    return dict(kind='cut12_long_rank_source_delta',schemaVersion=1,status='passed',
        wireAndTraceByteIdentical=True,rankNumericalBodyOnlyChangesReferenceContainerAndScope=True,
        fabricatedLegacyReferenceContainerRemoved=True,newFileAdapterUsesExplicitIndependentOriginPins=True,
        unchangedCoreFunctions=sorted(set(a)-{'check_rank_pair','validate'}),
        newCandidateAccess=False,nativeOrModelPayloadExecution=False,
        originals=pins)


if __name__=='__main__':print(json.dumps(check(),indent=2,sort_keys=True))
