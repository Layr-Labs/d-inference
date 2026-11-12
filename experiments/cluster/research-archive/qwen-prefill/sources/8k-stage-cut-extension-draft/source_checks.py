#!/usr/bin/env python3
"""Packaging/order checks only; never compile Swift or construct native objects."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PREFIX = 'experiments/cluster/inference/Sources/ClusterInference/'
NEW = {'QwenLongPrefillStageCut.swift', 'QwenLongPrefillStageCutPlanCheck.swift',
       'QwenLongPrefillStageCutAdmissionCheck.swift'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


def patch(original, proposed):
    parts = []
    for name in sorted(proposed):
        old = original.get(name, '')
        parts.extend(difflib.unified_diff(old.splitlines(True), proposed[name].splitlines(True),
            fromfile='a/' + PREFIX + name if name in original else '/dev/null',
            tofile='b/' + PREFIX + name))
    return ''.join(parts)


def runtime_checks(old, p):
    helper = p['QwenLongPrefillStageCut.swift']
    assert 'let cut = selected ?? 16' in helper
    assert helper.index('guard legal.contains(cut)') < helper.index('ranges: [0..<cut, cut..<32]')
    assert 'plan.stages.map(\\.sourceRange) == [0..<cut, cut..<32]' in helper
    options = p['Options.swift']
    gate = options[options.index('if let cut = stageCut {'):options.index('guard mode == .capability')]
    assert all('.' + mode in gate for mode in ['qwenLayerStageCompare', 'qwenLayerStageRankCheck',
        'qwenLongPrefillReference', 'qwenLongPrefillPairCheck', 'qwenLongPrefillRankCheck'])
    assert 'qwenLongPrefillSoloCheck' not in gate and '(1...127).contains(cut)' in gate
    solo = p['QwenLongPrefillSoloCLI.swift']
    assert solo.index('guard options.stageCut == nil') < solo.index('var reference = options')
    for name, binding, later in [
        ('QwenLongPrefillReferenceCLI.swift', 'validateBinding(options.stageCut, plan: admission.plan)', 'let before ='),
        ('QwenLongPrefillPairCheck.swift', 'validateBinding(stageCut, plan: local.plan)', 'var memory ='),
        ('QwenLongPrefillRankCheck.swift', 'validateBinding(options.stageCut, plan: local.plan)', 'let collective ='),
    ]:
        assert p[name].index(binding) < p[name].index(later)
    assert 'local: longReferenceAdmission, stageCut: options.stageCut, check:' in p['Main.swift']
    for name in ['QwenLongPrefillReferenceCLI.swift', 'QwenLongPrefillRankAdmission.swift']:
        assert 'arithmetic: arithmetic, stageCut: options.stageCut)' in p[name]
    reference = once(old['QwenLongPrefillReferenceAdmission.swift'],
        'arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt) throws {',
        'arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt, stageCut: Int? = nil) throws {')
    reference = once(reference,
        'let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<16, 16..<32])',
        'let plan = try QwenLongPrefillStageCut.makePlan(configuration: configuration, stageCut: stageCut)')
    assert p['QwenLongPrefillReferenceAdmission.swift'] == reference
    digest = once(old['QwenLayerStageProfiledStateDigest.swift'],
        'let geometry = admission.local.resource.geometry\n',
        'let geometry = admission.local.resource.geometry\n        let componentCount = try QwenLongPrefillStageCut.componentCount(stage)\n')
    digest = once(digest, 'expected.count == 36', 'expected.count == componentCount')
    assert p['QwenLayerStageProfiledStateDigest.swift'] == digest
    compute = once(old['QwenLayerStageProfiledComputeAdmission.swift'],
        '              plan.stages[0].sourceRange == (0..<16), plan.stages[1].sourceRange == (16..<32),\n', '')
    compute = once(compute, 'loaded.layerCount == 16',
        'loaded.layerCount == plan.stages[loaded.stageIndex].layers.count')
    assert p['QwenLayerStageProfiledComputeAdmission.swift'] == compute
    assert p['QwenLongPrefillReferenceCLI.swift'].index('StageCut.resolved(value.stageCut)') < p['QwenLongPrefillReferenceCLI.swift'].index('BoundedProbeInput.data(')
    checks = p['QwenLongPrefillStageCutAdmissionCheck.swift'] + p['QwenLongPrefillStageCutPlanCheck.swift']
    assert 'accepted == 13, rejected == 58, plan.accepted == 8, plan.rejected == 14' in checks
    assert all(text in checks for text in ['nil with unequal supplied plan', 'direct solo reference clone',
        'mutated preflight before IO', 'Array(0..<32)', '[9, 18, 27, 36, 45, 54, 63]'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', type=Path, required=True)
    args = parser.parse_args()
    inventory = json.loads((ROOT / 'base-inventory.json').read_text())
    original = {name: (ROOT / 'originals' / name).read_text() for name in inventory}
    proposed = {f.name: f.read_text() for f in (ROOT / 'proposed').glob('*.swift')}
    assert len(original) == 16 and set(proposed) == set(original) | NEW
    for name, digest in inventory.items():
        assert sha((ROOT / 'originals' / name).read_bytes()) == digest
        assert sha((args.repository / PREFIX / name).read_bytes()) == digest
    protected = json.loads((ROOT / 'protected-source-pins.json').read_text())
    for name, digest in protected.items():
        assert name not in proposed and sha((args.repository / PREFIX / name).read_bytes()) == digest
    expected_patch = patch(original, proposed).encode()
    assert (ROOT / 'runtime.patch').read_bytes() == expected_patch
    runtime_checks(original, proposed)
    mutations = [
        ('QwenLongPrefillStageCut.swift', 'selected ?? 16', 'selected ?? 12'),
        ('QwenLongPrefillRankCheck.swift', 'validateBinding(options.stageCut, plan: local.plan)', 'ignoredBinding(options.stageCut, plan: local.plan)'),
        ('QwenLongPrefillSoloCLI.swift', 'guard options.stageCut == nil', 'guard true'),
        ('QwenLayerStageProfiledStateDigest.swift', '== Set(expected.keys)', '== Set(snapshot.entries.map { "\\($0.globalLayerIndex)|\\($0.component)" })'),
        ('QwenLayerStageProfiledComputeAdmission.swift', 'loaded.layerCount == plan.stages[loaded.stageIndex].layers.count', 'loaded.layerCount == 16'),
        ('QwenLongPrefillReferenceAdmission.swift', 'request.chunkSize == 512', 'request.chunkSize == 256'),
    ]
    for name, before, after in mutations:
        bad = dict(proposed); bad[name] = once(bad[name], before, after)
        try:
            runtime_checks(original, bad)
        except (AssertionError, ValueError):
            pass
        else:
            raise AssertionError('source mutation was not rejected: ' + name)
    print(json.dumps({'kind': 'long_stage_cut_source_checks', 'passed': True,
        'replacement_files': len(original), 'new_swift_files': len(NEW),
        'protected_source_files': len(protected), 'rejected_source_mutations': len(mutations),
        'runtime_patch_sha256': sha(expected_patch), 'swift_compiled': False,
        'swift_fixtures_executed': False, 'native_execution_performed': False,
        'candidate_output_accessed': False}, sort_keys=True))


if __name__ == '__main__':
    main()
