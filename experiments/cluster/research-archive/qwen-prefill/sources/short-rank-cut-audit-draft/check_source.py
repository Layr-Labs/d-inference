#!/usr/bin/env python3
"""Prove the narrow rank-oracle delta without native or model execution."""
import ast
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent


def check():
    old=(ROOT.parent/'qwen_layer_stage_rank_audit.py').read_bytes()
    recipe=json.loads((ROOT/'mechanical-substitutions.json').read_bytes())
    assert hashlib.sha256(old).hexdigest()==recipe['sourceSHA256']=='489a4904d6ba947b33fabd7acf840c5f524bf37835ee2f6b81afaab80e0f0c9a'
    new=old.decode()
    for item in recipe['changes']:
        assert new.count(item['before'])==1
        new=new.replace(item['before'],item['after'])
    assert new.encode()==(ROOT/'qwen_layer_stage_rank_cut12_audit.py').read_bytes()
    old_nodes={n.name:n for n in ast.parse(old).body if isinstance(n,ast.FunctionDef)}
    new_nodes={n.name:n for n in ast.parse(new).body if isinstance(n,ast.FunctionDef)}
    changed=[k for k in old_nodes if ast.dump(old_nodes[k],include_attributes=False)!=ast.dump(new_nodes[k],include_attributes=False)]
    assert changed==['base_helper','validate_reports']
    original=ast.get_source_segment(old.decode(),old_nodes['validate_reports'])
    revised=ast.get_source_segment(new,new_nodes['validate_reports'])
    for item in recipe['changes'][5:]:revised=revised.replace(item['after'],item['before'])
    assert original==revised
    original_tests=ast.parse((ROOT.parent/'test_qwen_layer_stage_rank_audit.py').read_bytes())
    original_functions={n.name:ast.dump(n,include_attributes=False) for n in original_tests.body if isinstance(n,ast.FunctionDef)}
    mutations=ast.parse((ROOT/'rank_mutations.py').read_bytes())
    mutation_functions=[n for n in mutations.body if isinstance(n,ast.FunctionDef)]
    assert len(mutation_functions)==9
    assert all(ast.dump(n,include_attributes=False)==original_functions[n.name] for n in mutation_functions)
    files=list(ROOT.glob('*.py'))
    for path in files:ast.parse(path.read_bytes(),feature_version=(3,9))
    return dict(kind='short_rank_cut12_prospective_source_checks',status='passed',literalSubstitutions=9,
        wholeFunctionASTUnchanged=sorted(k for k in old_nodes if k not in changed),modifiedFunctions=changed,
        validateReportsChangesOnlyRangeAndComponentExpectations=True,originalMutationFunctionsASTUnchanged=9,
        python39SyntaxFiles=len(files),sourceSHA256=hashlib.sha256(old).hexdigest(),
        newSHA256=hashlib.sha256(new.encode()).hexdigest(),nativeExecution=False,newRankCandidateAccess=False)


if __name__=='__main__':print(json.dumps(check(),sort_keys=True,indent=2))
