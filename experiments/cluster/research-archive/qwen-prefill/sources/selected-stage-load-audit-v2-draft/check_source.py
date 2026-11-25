"""Static source and retained CPU metadata checks; no native or candidate IO."""
import ast
import hashlib
import json
from pathlib import Path
import re

import audit_selected_stage as audit
import selected_expected as expected_module
from arithmetic_fixture import native_arithmetic_receipt, SOURCE, SOURCE_SHA256

D=Path(__file__).resolve().parent
NATIVE=Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference')


def pin(path):
    raw=path.read_bytes()
    return dict(path=str(path),sizeBytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())


def fields(text):
    return set(re.findall(r'(?:\blet\s+|,\s*)(\w+)\s*(?:=|:)',text))


def run():
    for path in D.glob('*.py'):ast.parse(path.read_text(),feature_version=(3,9))
    assert SOURCE.read_bytes() == (NATIVE/'QwenLongPrefillArithmeticEnvironment.swift').read_bytes()
    arithmetic = native_arithmetic_receipt()
    tree = ast.parse((D/'audit_selected_stage.py').read_text())
    calls = [node for node in ast.walk(tree) if isinstance(node,ast.Call)
        and isinstance(node.func,ast.Name) and node.func.id=='exact' and len(node.args)==3
        and isinstance(node.args[2],ast.Constant) and node.args[2].value=='arithmeticEnvironment']
    assert len(calls)==1 and isinstance(calls[0].args[1],ast.Call) and calls[0].args[1].func.id=='dict'
    runtime_arithmetic = {item.arg:ast.literal_eval(item.value) for item in calls[0].args[1].keywords}
    expected_module.exact(runtime_arithmetic,arithmetic,'source-derived arithmetic DTO')
    probe=(NATIVE/'QwenDenseStageLoadProbe.swift').read_text()
    assert 'arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt' in probe
    assert 'arithmeticEnvironment: selection.metadata.arithmetic' in probe
    old=ast.parse((D/'originals/test_inventory_audit.py').read_text())
    new=ast.parse((D/'test_inventory_audit.py').read_text())
    old_class=next(node for node in old.body if isinstance(node,ast.ClassDef))
    new_class=next(node for node in new.body if isinstance(node,ast.ClassDef))
    assert ast.dump(old_class)==ast.dump(new_class)
    for name in ['selected_expected.py','constructor_metadata_base.py','stage_load_contract.py']:
        assert (D/name).read_bytes()==(D/'originals'/name).read_bytes()
    text=(NATIVE/'QwenLayerStageInventoryTypes.swift').read_text()
    assert fields(text.split('struct QwenLayerStageLoadReceipt: Codable {')[1])==audit.LOAD_KEYS
    assert fields(text.split('struct QwenLayerStageStorageCommitment: Codable {')[1].split('struct QwenLayerStageLoadReceipt')[0])==audit.STORAGE_KEYS
    budget=(NATIVE/'QwenDenseStageLoadBudget.swift').read_text().split('struct QwenDenseStageLoadBudget: Encodable {')[1].split('    private init')[0]
    assert fields(budget)==audit.BUDGET_KEYS
    materializer=(NATIVE/'VerifiedQwenLayerStageLoading.swift').read_text().split('func materializeVerifiedQwenLayerStage')[1]
    assert 'eval(array)' in materializer and 'eval(model)' not in materializer
    assert 'Freeze and parameter introspection do not evaluate unused placeholders' in materializer
    stats={}
    for model in audit.PROFILES:
        e=expected_module.expected(model)
        for modules in e['inert']:
            for module in modules:
                assert module['responsibility'] in (NATIVE/'QwenLayerStagePlan.swift').read_text()
        stats[model]=dict(sourceTensorCount=len(e['source']),sourceTensorBytes=e['sourceBytes'],
            canonicalInventorySHA256=e['canonicalInventorySHA256'],sourceLayoutSHA256=e['sourceLayoutSHA256'],
            stages=[dict(summary=e['summaries'][i],loadedDTypeCounts={tag:sum(r['loadedDType']==tag for r in e['active'][i])
                for tag in sorted({r['loadedDType'] for r in e['active'][i]})}) for i in (0,1)])
    names=['QwenLayerStageInventoryTypes.swift','QwenLayerStageInert.swift','QwenLayerStagePlan.swift',
        'PreparedQwenLayerSource.swift','ModelPartition.swift','CanonicalJSON.swift','QwenDenseStageLoadBudget.swift',
        'QwenDenseStageLoadProbe.swift','VerifiedQwenLayerStageLoading.swift','QwenDenseSelectedStageLoading.swift',
        'QwenLongPrefillArithmeticEnvironment.swift']
    return dict(kind='selected_stage_inventory_audit_source_checks',passed=True,
        actualNativeDTOKeysMatched=True,sourceActiveEvaluationAndLazyInertDistinctionConfirmed=True,
        fullArithmeticReceiptFieldsAndLiteralValuesMatchSource=True,
        arithmeticSourceSHA256=SOURCE_SHA256,arithmeticFieldCount=len(arithmetic),
        originalTwelveTestClassASTUnchanged=True,threeInheritedHelpersByteIdentical=True,
        retainedMetadata=pin(expected_module.FIXTURE),nativeSources=[pin(NATIVE/name) for name in names],
        localSources=[pin(path) for path in sorted(D.glob('*.py'))],expectedStatistics=stats,
        compilerNativeSSHOrCandidateAccessed=False,modelPayloadRead=False)


if __name__=='__main__':print(json.dumps(run(),indent=2,sort_keys=True))
