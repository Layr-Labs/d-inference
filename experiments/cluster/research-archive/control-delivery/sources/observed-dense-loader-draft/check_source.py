#!/usr/bin/env python3
"""Bounded source/retained-metadata checks only; never invoke Swift or native code."""
import base64
import copy
import hashlib
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path('/Users/developer/DarkbloomDev/d-inference')
SOURCES = REPO / 'experiments/cluster/inference/Sources/ClusterInference'
PROFILE = HERE.parent / 'registered-dense-profile-draft'
INPUT_SHA = '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25'
HEADER_RECEIPT = HERE.parent / 'models/qwen38-downloaded-header-verification-20260914.json'
HEADER_SHA = '8d443bfbafe59d72a962ecdcbb8ba32e9459869a8fd3536b2e375a8a23efe33c'


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def bounded(path, limit=1_048_576):
    assert path.is_file() and not path.is_symlink(), str(path)
    raw = path.read_bytes()
    assert 0 < len(raw) <= limit, str(path)
    return raw


def stable_json(path, result):
    raw = (json.dumps(result, sort_keys=True, indent=2) + '\n').encode()
    if path.exists():
        assert path.read_bytes() == raw, 'Refusing to alter saved source receipt: ' + str(path)
    else:
        with path.open('xb') as output:
            output.write(raw)


def source_checks(parts):
    original = {p.name: bounded(p).decode() for p in (HERE / 'originals').glob('*.swift')}
    core = parts['core/QwenDenseObservedSource.swift']
    stage = parts['core/QwenDenseObservedStage.swift']
    full = parts['proposed/VerifiedQwenDiagnosticLoading.swift']
    layer = parts['proposed/PreparedQwenLayerSource.swift']
    bounds = parts['proposed/LocalCorrectnessStorage.swift']
    receipt = parts['proposed/QwenLayerStageLoadReceipt.swift']
    split = original['QwenLayerStageLoadReceipt.swift'].index('struct QwenStageSourceTensor:')
    assert receipt == original['QwenLayerStageLoadReceipt.swift'][:split]
    assert parts['core/QwenLayerStageInventoryTypes.swift'] == 'import Foundation\n\n' + original['QwenLayerStageLoadReceipt.swift'][split:]
    # Full materializer/return and all validation below the private storage struct are untouched.
    for boundary in ['private struct DiagnosticQwenStorage', 'private func validateDiagnosticQwen']:
        side = 0 if boundary.startswith('private struct') else 1
        assert full.split(boundary)[side] == original['VerifiedQwenDiagnosticLoading.swift'].split(boundary)[side]
    assert layer.split('        let validated = try QwenDenseObservedSourceValidation')[0] == original['PreparedQwenLayerSource.swift'].split('        let expected = Dictionary')[0]
    assert layer.split('        let mappings = try plan.parameters')[1] == original['PreparedQwenLayerSource.swift'].split('        let mappings = try plan.parameters')[1]
    assert bounds == original['LocalCorrectnessStorage.swift'].replace(
        'static let maximumSourceModelTensorBytes = 6 * 1024 * 1024 * 1024',
        'static let maximumSourceModelTensorBytes = QwenDenseLegacySourceBounds.maximumSourceModelTensorBytes').replace(
        'static let maximumHostTensorBytes = 512 * 1024 * 1024',
        'static let maximumHostTensorBytes = QwenDenseLegacySourceBounds.maximumHostTensorBytes')
    assert 'maximumSourceModelTensorBytes = 6 * 1024 * 1024 * 1024' in parts['core/QwenDenseLegacySourceBounds.swift']
    assert 'maximumHostTensorBytes = 512 * 1024 * 1024' in parts['core/QwenDenseLegacySourceBounds.swift']
    for token in ['observed.sourcePartCount == 1', 'tensor.shape == observed.preparedExpectedShape',
                  '(tensor.sourceDType == "U32") == packed', 'tensor.byteCount <= hostLimit',
                  'total.addingReportingOverflow(tensor.byteCount)', 'next.partialValue <= sourceLimit',
                  'identity.verifiedManifestSHA256 == profile.manifestSHA256',
                  'identity.retainedSourceCount == profile.canonicalTensors.count',
                  'identity.bf16ConversionEnabled == profile.requiredBF16ConversionPolicy',
                  'actual == profile.canonicalTensors', 'let runtimeExecutionAuthorized = false']:
        assert token in core, token
    for token in ['source.registeredRequirementFingerprint == requirement.fingerprint',
                  'requirement.role == .sequentialPair || requirement.role.stageIndex == stageIndex',
                  'actual.sourceName == mapping.sourceName', 'actual.shape == tensor.canonical.shape',
                  'parameter.dtype == profile.requiredNativeDType', 'actual.parameters.count == 1',
                  'summary.activeMappingSHA256 == (try QwenDenseProfileIdentity.encodedFingerprint(active))']:
        assert token in stage, token
    for name in ['proposed/PreparedQwenLayerSource.swift', 'proposed/VerifiedQwenDiagnosticLoading.swift']:
        assert 'validateRegistered' not in parts[name]
    # No new payload, evaluation, model construction or environment access in the metadata seam.
    for name, body in parts.items():
        if name.startswith(('core/', 'bridges/')) and name.endswith('.swift'):
            for token in ['eval(', '.read(', '.update(', 'constructQwenModel(', 'ProcessInfo.', 'GPU.', 'MLXArray(']:
                assert token not in body, (name, token)
    pinned = parts['manifest-pin/VerifiedCheckpoint.swift']
    assert pinned.index('try QwenCheckpointManifestPin.validateExpected') < pinned.index('let manifestURL =')
    assert pinned.index('let matchedManifest =') < pinned.index('JSONDecoder().decode') < pinned.index('let file = try File(')
    assert 'if maximumPayloadBytes != nil || expectedManifestSHA256 != nil {' in pinned
    assert pinned.split('        let manifest = try JSONDecoder()')[1].split('        self.aggregate =')[0] == original['VerifiedCheckpoint.swift'].split('        let manifest = try JSONDecoder()')[1].split('        self.aggregate =')[0]
    assert pinned.split('    let aggregate: String')[0] == original['VerifiedCheckpoint.swift'].split('    let aggregate: String')[0]
    assert pinned.index('self.verifiedManifestSHA256 = matchedManifest') > pinned.index('Verified checkpoint differs from expected aggregate')
    pin_helper = parts['manifest-pin/QwenCheckpointManifestPin.swift']
    assert 'guard let expected else { return nil }' in pin_helper
    assert pin_helper.index('guard let expected else { return nil }') < pin_helper.index('let actual = sha256(data)')
    prepared = parts['manifest-pin/PreparedQwenCheckpoint.swift']
    assert prepared.split('        let descriptors =')[1] == original['PreparedQwenCheckpoint.swift'].split('        let descriptors =')[1]
    assert 'expectedManifestSHA256: String? = nil' in pinned and 'expectedManifestSHA256: String? = nil' in prepared


def metadata_check():
    raw = bounded(PROFILE / 'retained-inputs.json')
    assert digest(raw) == INPUT_SHA
    inputs = json.loads(raw)
    result = []
    expected = {
        'nine': (927, 5_038_041_600, 508_559_360, 32, 4096, [463, 464], [16_384, 8_192]),
        'twentySeven': (1847, 15_132_802_048, 635_699_200, 64, 5120, [923, 924], [20_480, 10_240]),
    }
    for name, (count, byte_count, largest, layers, hidden, counts, inert) in expected.items():
        value = inputs[name]
        config, manifest = (base64.b64decode(value[key], validate=True) for key in ['configuration', 'manifest'])
        text = json.loads(config)['text_config']
        assert text['num_hidden_layers'] == layers and text['hidden_size'] == hidden
        entries = value['canonicalTensors']
        assert len(entries) == count and len({x['name'] for x in entries}) == count
        assert sum(x['byteCount'] for x in entries) == byte_count and max(x['byteCount'] for x in entries) == largest
        totals = [0, 0]; observed_counts = [0, 0]
        for entry in entries:
            assert math.prod(entry['shape']) * {'U32': 4, 'F32': 4, 'F16': 2, 'BF16': 2}[entry['sourceDType']] == entry['byteCount']
            key = entry['name']; assert key.startswith('language_model.')
            if key.startswith('language_model.model.layers.'):
                layer = int(key.split('.')[3]); assert 0 <= layer < layers
                owner = int(layer >= layers // 2)
            elif key.startswith('language_model.model.embed_tokens.'):
                owner = 0
            elif key.startswith('language_model.lm_head.') or key == 'language_model.model.norm.weight':
                owner = 1
            else:
                raise AssertionError('unknown canonical owner ' + key)
            totals[owner] += entry['byteCount']; observed_counts[owner] += 1
        assert observed_counts == counts
        if name == 'twentySeven':
            assert totals == [7_566_395_904, 7_566_406_144]
        result.append(dict(model=name, canonicalCount=count, sourceBytes=byte_count, largestBytes=largest,
            stageCounts=observed_counts, stageActiveBytes=totals, stageInertBytes=inert,
            configurationSHA256=digest(config), manifestSHA256=digest(manifest)))
    header_raw = bounded(HEADER_RECEIPT)
    assert digest(header_raw) == HEADER_SHA
    return result


def main():
    parts = {str(p.relative_to(HERE)): bounded(p).decode() for folder in ['core', 'bridges', 'proposed', 'manifest-pin'] for p in (HERE / folder).glob('*.swift')}
    source_checks(parts)
    mutations = [
        ('core/QwenDenseObservedSource.swift', 'observed.sourcePartCount == 1', 'observed.sourcePartCount <= 2'),
        ('core/QwenDenseObservedSource.swift', 'identity.verifiedManifestSHA256 == profile.manifestSHA256', 'true'),
        ('core/QwenDenseObservedSource.swift', 'actual == profile.canonicalTensors', 'true'),
        ('core/QwenDenseObservedStage.swift', 'source.registeredRequirementFingerprint == requirement.fingerprint', 'true'),
        ('proposed/VerifiedQwenDiagnosticLoading.swift', 'eval(array)', 'eval(model)'),
        ('core/QwenLayerStageInventoryTypes.swift', 'let byteCount: Int', 'let byteCount: Int64'),
        ('manifest-pin/VerifiedCheckpoint.swift', 'if maximumPayloadBytes != nil || expectedManifestSHA256 != nil {', 'if maximumPayloadBytes != nil {'),
        ('manifest-pin/QwenCheckpointManifestPin.swift', 'guard let expected else { return nil }', 'guard let expected else { return sha256(data) }'),
    ]
    for name, old, new in mutations:
        fake = copy.copy(parts); assert old in fake[name]; fake[name] = fake[name].replace(old, new, 1)
        try:
            source_checks(fake)
        except AssertionError:
            pass
        else:
            raise AssertionError('source mutation was not rejected: ' + old)
    metadata = metadata_check()
    dependencies = []
    old_pins = json.loads(bounded(PROFILE / 'source-pins.json'))['files']
    for record in old_pins:
        path = Path(record['path']); raw = bounded(path)
        assert digest(raw) == record['sha256']
        dependencies.append(dict(path=str(path), byteCount=len(raw), sha256=digest(raw), role='pure_fixture_dependency'))
    for p in sorted((PROFILE).glob('*.swift')):
        if p.name in ['ProfileCheckMain.swift', 'QwenRegisteredDenseProfileCheck.swift']:
            continue
        raw = bounded(p)
        assert raw == bounded(SOURCES / p.name)
        dependencies.append(dict(path=str(p), byteCount=len(raw), sha256=digest(raw), role='frozen_profile_core_matches_current'))
    for original in sorted((HERE / 'originals').glob('*.swift')):
        raw = bounded(original); live = bounded(SOURCES / original.name)
        assert raw == live
        dependencies.append(dict(path=str(SOURCES / original.name), byteCount=len(raw), sha256=digest(raw), role='current_loader_anchor'))
    for relative in ['experiments/cluster/inference/Sources/ClusterInference/SafeTensorReader.swift', 'libs/mlx-swift/Source/MLX/DType.swift']:
        path = REPO / relative; raw = bounded(path)
        dependencies.append(dict(path=str(path), byteCount=len(raw), sha256=digest(raw), role='descriptor_dtype_anchor'))
    stable_json(HERE / 'source-pins.json', dict(schemaVersion=1, files=dependencies,
        retainedInput=dict(path=str(PROFILE / 'retained-inputs.json'), sha256=INPUT_SHA),
        downloadedHeaderReceipt=dict(path=str(HEADER_RECEIPT), sha256=HEADER_SHA, replayedHeaderReads=False)))
    stable_json(HERE / 'source-checks-v2.json', dict(schemaVersion=1, status='passed', sourceMutationRejections=len(mutations),
        observedMetadata=metadata, swiftCompiled=False, swiftFixtureExecuted=False, nativeOrModelExecuted=False,
        modelPayloadRead=False, modelHeaderRead=False, newExecutionPermit=False,
        prospectiveSwiftFixtureCounts=dict(accepted=22, rejected=104), sourcePinsSHA256=digest(bounded(HERE / 'source-pins.json'))))
    print(json.dumps(dict(status='passed', sourceMutationRejections=len(mutations), models=len(metadata), swiftExecuted=False)))

if __name__ == '__main__':
    main()
