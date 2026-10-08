"""AST/byte conservation check for the narrow, out-of-tree oracle variant."""
import ast
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PAIRS = [
    ('long-prefill-reference-audit-draft/qwen_long_prefill_reference_audit.py','qwen_long_prefill_reference_cut12_audit.py',{'context','verify_pins'}),
    ('long-prefill-pair-audit-draft/pair_storage.py','cut12_pair_storage.py',{'check_storage'}),
    ('long-prefill-pair-audit-draft/pair_final.py','cut12_pair_final.py',{'expected_final'}),
    ('long-prefill-pair-audit-draft/pair_wire.py','cut12_pair_wire.py',set()),
    ('long-prefill-pair-audit-draft/qwen_long_prefill_pair_audit.py','qwen_long_prefill_pair_cut12_audit.py',{'check_pair'}),
]


def functions(source):
    return {n.name:ast.dump(n,include_attributes=False) for n in ast.parse(source).body if isinstance(n,ast.FunctionDef)}


def check():
    pins = json.loads((HERE/'original-helper-pins.json').read_bytes())
    checked = []
    for old,new,allowed in PAIRS:
        before,after = (ROOT/old).read_bytes(),(HERE/new).read_bytes()
        assert hashlib.sha256(before).hexdigest() == pins[old], old
        a,b = functions(before),functions(after)
        assert set(a) == set(b), new
        changed = {name for name in a if a[name] != b[name]}
        assert changed == allowed, (new,changed,allowed)
        checked.append(dict(original=old,variant=new,changedFunctions=sorted(changed),
            unchangedFunctions=sorted(set(a)-changed),originalSHA256=hashlib.sha256(before).hexdigest(),
            variantSHA256=hashlib.sha256(after).hexdigest()))
    assert (ROOT/PAIRS[3][0]).read_bytes() == (HERE/PAIRS[3][1]).read_bytes()
    original = (ROOT/PAIRS[-1][0]).read_text()
    variant = (HERE/PAIRS[-1][1]).read_text()
    for a,b in [('from pair_storage import','from cut12_pair_storage import'),
                ('from pair_wire import','from cut12_pair_wire import'),
                ('from pair_final import','from cut12_pair_final import'),
                ("scope='registered9b_8192_chunk512_output1_one_process_pair'", "scope='registered9b_8192_chunk512_output1_cut12_one_process_pair'"),
                ('stageStateComponents=[36,36]','stageStateComponents=[27,45]'),
                ('stageLogicalStateBytes=[159973392,159973392]','stageLogicalStateBytes=[119980044,199966740]')]:
        assert original.count(a) == 1
        original = original.replace(a,b)
    assert original == variant
    return dict(kind='cut12_long_pair_oracle_source_delta',schemaVersion=1,status='passed',
        numericalReferenceBodyUnchanged=True,wireFileByteIdentical=True,
        parserSignedZeroAndFiniteByteHashLogicUnchanged=True,
        pairBodyOnlyChangesSummaryScopeCountsAndBytes=True,files=checked,
        runtimeOrNumericalCandidateQualification=False)


if __name__ == '__main__': print(json.dumps(check(),indent=2,sort_keys=True))
