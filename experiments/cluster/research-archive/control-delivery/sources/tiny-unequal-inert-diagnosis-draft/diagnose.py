"""Independent bounded CPU diagnosis; preserves frozen v1 and actual run."""
import hashlib
import json
from pathlib import Path

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
RUN = ROOT/'runs/qwen-layer-stage-unequal-tiny-20260914'
V1 = ROOT/'tiny-unequal-audit-draft'


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def read(path, maximum=1048576):
    assert path.is_file() and not path.is_symlink() and path.stat().st_size <= maximum
    with path.open('rb') as handle:
        raw = handle.read(maximum+1)
    assert len(raw) <= maximum
    return raw


def diagnose():
    paths = [RUN/'stdout.jsonl', RUN/'receipt.json', RUN/'cpu-audit-execution.json',
        RUN/'cpu-audit.stderr', RUN/'source-manifest.json', V1/'manifest.json',
        V1/'source-derived-expected.json', V1/'tiny12_expected.py', V1/'tiny_unequal_audit.py']
    source_root = RUN/'source/experiments/cluster/inference/Sources/ClusterInference'
    paths += [source_root/name for name in ['QwenLayerStageInert.swift','QwenLayerStageLoadReceipt.swift','QwenLayerStagePlan.swift']]
    raw = {str(path):read(path,8*1024**2) for path in paths}
    assert sha(raw[str(RUN/'stdout.jsonl')]) == '9960b0fbbc1c5c87d6fb2a95bc94b33348f53f163ab249fc74d7e67198d06f84'
    assert sha(raw[str(RUN/'receipt.json')]) == '3478ee71212ee75fe30577e43af6ea05d91f080f3e719a1c55078bda3b5b9d94'
    assert sha(raw[str(V1/'manifest.json')]) == '9b9c07179fda9fa92b657e9b703c40f7062f27b628ad3ee5b742043cc37a2e47'
    rows = [json.loads(line) for line in raw[str(RUN/'stdout.jsonl')].splitlines()]
    assert len(rows) == 13 and rows[12]['kind'] == 'qwen_layer_stage_unequal_cut_recording_check'
    report = rows[12]['comparison']
    expected = json.loads(raw[str(V1/'source-derived-expected.json')])
    archive = json.loads(raw[str(RUN/'source-manifest.json')])
    launcher = json.loads(raw[str(RUN/'receipt.json')])
    assert launcher['sourceManifestSHA256'] == sha(raw[str(RUN/'source-manifest.json')])
    frozen = json.loads(raw[str(V1/'manifest.json')])
    for name in ['source-derived-expected.json','tiny12_expected.py','tiny_unequal_audit.py']:
        entry = next(item for item in frozen['files'] if item['path'] == name)
        assert entry['sha256'] == sha(raw[str(V1/name)])
    for name in ['QwenLayerStageInert.swift','QwenLayerStageLoadReceipt.swift','QwenLayerStagePlan.swift']:
        relative = 'experiments/cluster/inference/Sources/ClusterInference/'+name
        entry = next(item for item in archive['files'] if item['path'] == relative)
        assert entry['sha256'] == sha(raw[str(source_root/name)])
    source = raw[str(source_root/'QwenLayerStageInert.swift')].decode()
    assert 'return try stage.inertModules.sorted(by: { $0.path < $1.path }).map' in source
    findings = []
    for index, stage in enumerate(report['stageLoads']):
        actual, wanted = stage['inertModules'], expected['stages'][index]['inertModules']
        sort = lambda values: sorted(values,key=lambda item:item['path'])
        assert len(actual) == len(wanted) == (2 if index == 0 else 1)
        assert len({item['path'] for item in actual}) == len(actual)
        assert actual == sort(actual) and sort(actual) == sort(wanted)
        other_keys = ['constructionConfigurationSHA256','stagePlanSHA256','activeTensors',
            'activeMappingSHA256','activeParameterLayoutSHA256','parameterLayoutSHA256',
            'loadedTensorBytes','largestHostTensorBytes','inertTensorBytes']
        assert all(stage[key] == expected['stages'][index][key] for key in other_keys)
        findings.append(dict(stageIndex=index,actualPaths=[item['path'] for item in actual],
            expectedV1Paths=[item['path'] for item in wanted],exactListEquality=actual==wanted,
            sameCompleteDescriptorsWhenGroupedByPath=True,otherSourceDerivedStageFieldsExact=other_keys))
    audit = json.loads(raw[str(RUN/'cpu-audit-execution.json')])
    assert audit['auditExit'] == 1 and audit['auditorSourceUnchanged'] is True
    assert b'Source-derived tiny12 stage metadata differs: inertModules' in raw[str(RUN/'cpu-audit.stderr')]
    for path in paths:
        assert read(path,8*1024**2) == raw[str(path)]
    return dict(kind='tiny_unequal_inert_metadata_failure_diagnosis',schemaVersion=1,
        status='confirmed_v1_expected_loader_order_bug',stages=findings,
        correction='Sort only generated loader-receipt inertModules by path. Preserve Plan norm/head order and fingerprints. Keep exact candidate-list validation.',
        candidateStdoutSHA256=sha(raw[str(RUN/'stdout.jsonl')]),
        v1FailurePreserved=True,numericalParityReplayed=False,nativeExecutionPerformed=False,
        modelTensorPayloadsRead=False,archivedSourceFilesRead=True,
        scope='Metadata/source diagnosis only. Complete V2 numerical replay and separate launcher/resource/provenance checks remain separate.',
        inputs=[dict(path=str(path),sha256=sha(raw[str(path)]),sizeBytes=len(raw[str(path)])) for path in paths])


if __name__ == '__main__':
    print(json.dumps(diagnose(),sort_keys=True,indent=2))
