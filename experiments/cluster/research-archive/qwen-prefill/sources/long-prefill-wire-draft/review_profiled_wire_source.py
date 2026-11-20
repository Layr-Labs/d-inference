"""CPU recipe/source checks only; does not compile or execute Swift/native code."""
import argparse
import ast
import base64
import hashlib
import json
from pathlib import Path
import runpy

GEOMETRY_MANIFEST = '8ca2a1d13792501ba13f37322766e30fd232a59e373883dc0c36bd010ddf7ca3'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def metadata(path):
    data = path.read_bytes()
    return dict(path=path.name, sha256=sha(data), size_bytes=len(data))


def review(folder, geometry, source):
    recipe = runpy.run_path(str(folder / 'profiled_wire_vectors.py'), run_name='source_recipe')
    vectors = json.loads((folder / 'wire-vectors-20260914.json').read_bytes())
    assert vectors['profiled'] == recipe['make'](True)
    assert vectors['legacy'] == recipe['make'](False)
    assert vectors['domains'] == recipe['DOMAINS']
    assert (folder / 'QwenLayerStageProfiledWireGoldenCheck.swift').read_text() == recipe['swift_check'](vectors)
    manifest = geometry / 'source-review-20260914.json'
    assert sha(manifest.read_bytes()) == GEOMETRY_MANIFEST
    geometry_receipt = json.loads(manifest.read_bytes())
    for entry in geometry_receipt['files']:
        assert metadata(geometry / entry['path']) == entry
    geometry_vectors = json.loads((geometry / 'fingerprint-vectors-20260914.json').read_bytes())
    new = vectors['profiled']
    assert '\n'.join(geometry_vectors['profile_material']) == new['profileMaterial']
    assert geometry_vectors['profileFingerprint'] == new['profileFingerprint']
    for entry in geometry_vectors['vectors']:
        request = '\n'.join(['qwen-stage-profiled-prefill-request-v1', 'long_prefill_8k_v1',
            new['profileFingerprint'], geometry_vectors['requestID'], 'batch=1',
            f'prompt={entry["promptCount"]}', f'chunk={entry["chunkSize"]}', 'output=1'])
        assert sha(request.encode()) == entry['requestFingerprint']
        recorded = '\n'.join(['qwen-layer-stage-profiled-prefill-recorded-request-v1', 'long_prefill_8k_v1',
            new['profileFingerprint'], entry['requestFingerprint'], 'vocabulary=32',
            'prompt=' + ','.join(str(i % 32) for i in range(entry['promptCount'])), 'teacher='])
        assert sha(recorded.encode()) == entry['recordedRequestFingerprint']
    packets = 0
    for namespace in ('profiled', 'legacy'):
        for name in ('inner', 'start', 'boundary', 'token', 'lookahead'):
            if name not in vectors[namespace]:
                continue
            item = vectors[namespace][name]
            raw = base64.b64decode(item['encodedBase64'], validate=True)
            assert len(raw) == item['byteCount'] and sha(raw) == item['wireBytesSHA256']
            assert raw == recipe['canonical'](item['content'])
            if namespace == 'profiled' and name in ('start', 'boundary', 'token'):
                assert sha(recipe['DOMAINS'][name].encode() + b'\n' + raw) == item['fingerprint']
                assert item['fingerprint'] != item['wireBytesSHA256']
                assert len(raw) <= dict(start=8192, boundary=16384, token=4096)[name]
            packets += 1
    # Every source-level textual mutation must actually exist in the fabricated
    # bytes; a missed target must not masquerade as a decoder rejection later.
    mutation_targets = dict(start=['"version":4', '"agreement":{'],
        boundary=['"version":4', '"byteCount":131072', '"frame":{', '"phase":"prefill"'],
        token=['"version":4', '"tokenOffset":7680'])
    for name, targets in mutation_targets.items():
        text = base64.b64decode(new[name]['encodedBase64']).decode()
        assert all(target in text for target in targets)
    swift = sorted(folder.glob('*.swift'))
    assert len(swift) == 11
    for path in swift:
        text = path.read_text()
        assert [line for line in text.splitlines() if line.startswith('import ')] == ['import Foundation']
        assert all(term not in text for term in ('ProcessInfo.processInfo', 'getenv(', 'Stream.', 'MLXArray(', '/Users/'))
    for path in folder.glob('*.py'):
        ast.parse(path.read_text(), filename=path.name)
    for entry in geometry_receipt['legacy_dependencies_unchanged']:
        assert sha((source / entry['path']).read_bytes()) == entry['sha256']
    dependencies = ['QwenLayerStageBoundaryWireHeader.swift', 'QwenLayerStageLookaheadWireEnvelope.swift',
        'QwenLayerStagePrefillStartAgreement.swift', 'QwenLayerStagePrefillWireJSON.swift',
        'QwenLayerStagePrefillBoundaryEnvelope.swift', 'QwenLayerStagePrefillFirstTokenWirePacket.swift',
        'QwenLayerStagePrefillWireCheckFixture.swift', 'QwenLayerStagePrefillComputeTypes.swift']
    files = sorted(p for p in folder.iterdir() if p.suffix in ('.swift', '.py', '.md', '.json')
                   and p.name != 'source-review-20260914.json')
    return dict(kind='long_prefill_wire_source_review', schema_version=1, date='2026-09-14', passed=True,
        files=[metadata(p) for p in files], geometry_manifest_sha256=GEOMETRY_MANIFEST,
        legacy_dependency_snapshot=[metadata(source / name) for name in dependencies],
        geometry_legacy_dependency_pins_still_match=True, independent_packet_recipe_checks=packets,
        independent_geometry_request_history_vector_pairs=2, textual_mutation_targets_verified=True,
        generated_swift_golden_matches_recipe=True, swift_files=11,
        pure_check_entry='checkQwenLayerStageProfiledPrefillWire()',
        swift_compiled=False, swift_fixtures_executed=False, native_executed=False,
        gpu_executed=False, ssh_performed=False, model_payload_read=False, repository_sources_edited=False,
        limitations=['Python checks validate source-derived recipes and stale-file consistency, not Swift codec behavior.',
            'Root must compile/run new and unchanged legacy fixtures; native transport/resource/model qualification is separate.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--geometry', type=Path, required=True)
    parser.add_argument('--legacy-source', type=Path, required=True)
    args = parser.parse_args()
    folder = Path(__file__).resolve().parent
    value = review(folder, args.geometry, args.legacy_source)
    output = folder / 'source-review-20260914.json'
    with output.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')
    print(json.dumps(dict(passed=True, receipt=output.name, sha256=sha(output.read_bytes()),
        swift_files=value['swift_files'], packet_recipes=value['independent_packet_recipe_checks'],
        swift_compiled=False, native_executed=False), sort_keys=True))


if __name__ == '__main__':
    main()
