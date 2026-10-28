"""Source/package consistency only; never compiles or executes Swift."""
from pathlib import Path
import difflib
import hashlib
import json

HERE = Path(__file__).resolve().parent
REPO = Path('/Users/developer/DarkbloomDev/d-inference')
REL = Path('experiments/cluster/inference/Sources/ClusterInference')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    originals = sorted((HERE / 'originals').glob('*.swift'))
    proposed = sorted((HERE / 'proposed').glob('*.swift'))
    assert len(originals) == 7 and len(proposed) == 9
    expected_patch = []
    for original in originals:
        path = REL / original.name
        replacement = HERE / 'proposed' / original.name
        assert original.read_bytes() == (REPO / path).read_bytes(), str(path)
        expected_patch.extend(difflib.unified_diff(
            original.read_text().splitlines(True), replacement.read_text().splitlines(True),
            fromfile='a/' + str(path), tofile='b/' + str(path)))
    assert (HERE / 'runtime.patch').read_text() == ''.join(expected_patch)
    for path in proposed:
        assert '/Users/' not in path.read_text() and 'darkbloom-24' not in path.read_text()
    options = (HERE / 'proposed/Options.swift').read_text()
    assert '[--prefill-owner-trace-file NEW_PATH]' in options
    assert options.index('if let cut = stageCut') < options.index('QwenLayerStageComparisonAdmission.validateOptions(self)')
    admission = (HERE / 'proposed/QwenLayerStageComparisonAdmission.swift').read_text()
    old_admission = (HERE / 'originals/QwenLayerStageComparisonAdmission.swift').read_text()
    budget_marker = '    /// Pinned Qwen configuration'
    assert admission[admission.index(budget_marker):] == old_admission[old_admission.index(budget_marker):]
    assert admission.index('guard cut > 0, cut < layers') < admission.index('ranges: [0..<cut, cut..<layers]')
    for name in ['QwenLayerStageRankAdmission.swift', 'QwenLayerStagePrefillAdmission.swift',
                 'QwenLayerStageSoloPrefillCLIAdmission.swift']:
        text = (HERE / 'proposed' / name).read_text()
        assert text.index('guard options.stageCut == nil') < text.index('QwenLayerStageComparisonAdmission.validateOptions')
    runner = (HERE / 'proposed/QwenLayerStageComparison.swift').read_text()
    assert runner.index('validatePlanBinding(options, inputs: inputs)') < runner.index('let request =')
    fixture = (HERE / 'proposed/QwenLayerStageFixture.swift').read_text()
    assert 'layerCount: Int = 8' in fixture and '[8, 12].contains(layerCount)' in fixture
    assert 'layerCount == 8 || prefillProfile == nil' in fixture
    assert 'if layerCount == 12 { text["cluster_fixture_profile"] = "tiny-layer-stage-12x4" }' in fixture
    old_fixture = (HERE / 'originals/QwenLayerStageFixture.swift').read_text()
    begin, end = '    _qwen35MTPEnabled = false', '    let parameters = model.parameters().flattened()'
    assert fixture[fixture.index(begin):fixture.index(end)] == old_fixture[old_fixture.index(begin):old_fixture.index(end)]
    return {
        'kind': 'stage_cut_draft_source_checks', 'passed': True,
        'existing_files_match_repository': len(originals), 'proposed_swift_files': len(proposed),
        'runtime_patch_matches_proposed_files': True, 'owner_help_preserved': True,
        'named_state_budget_source_unchanged': True, 'original_mode_precedes_adapter_dispatch': True,
        'bounds_precede_range_construction': True, 'explicit_runner_binding_precedes_model_io': True,
        'three_helper_entries_protected': True, 'default_generator_operator_source_unchanged': True,
        'new_tiny12_identity_and_profile_exclusion_explicit': True, 'public_swift_private_path_scan_passed': True,
        'swift_tests_executed': False, 'swift_compiled': False, 'native_execution': False,
        'checks_script_sha256': sha(Path(__file__)),
    }


if __name__ == '__main__':
    print(json.dumps(main(), indent=2, sort_keys=True))
