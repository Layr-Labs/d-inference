"""Root-run local input binding only; never starts a worker or grants capacity."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parent
HELPER = BASE.parent / 'qwen27b-8k-collection-comparison-20260915'
HELPER_SHA = 'bafad64fa13f02127c1bfffe5cd4b17324067c3e35162590b74ec123708f7ce9'
SPEC_SHA = 'cecda245d1224361ed0d1865ad3ad35d44876c2e1b530c0322031ed117576f1f'


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--reference', required=True)
    parser.add_argument('--reference-sha256', required=True)
    parser.add_argument('--output-directory', required=True)
    args = parser.parse_args()
    # Verify the imported helper before allowing it to establish the frozen
    # parent/comparator scope. This reads only its small source package.
    manifest = HELPER / 'manifest.json'
    if manifest.is_symlink() or hashlib.sha256(manifest.read_bytes()).hexdigest() != HELPER_SHA:
        raise ValueError('Frozen 8K helper differs')
    for name, row in json.loads(manifest.read_bytes())['files'].items():
        path = HELPER / name
        if path.is_symlink() or path.stat().st_size != row['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != row['sha256']:
            raise ValueError('Frozen 8K helper member differs')
    sys.path.insert(0, str(HELPER))
    import prepare_packet as inputs
    inputs.bootstrap()
    from audit_common import agreement, request_context, parse, exact, sha
    from audit_scope import pinned_scope
    from audit_reference import check_reference
    from audit_generation import write_result
    from snapshot import snapshot
    spec_raw = (BASE / 'specification.json').read_bytes()
    exact(hashlib.sha256(spec_raw).hexdigest(), SPEC_SHA, 'frozen timing specification')
    spec = json.loads(spec_raw)
    exact(sha(args.reference_sha256), spec['referenceSHA256'], 'matched reference identity')
    saved = []

    def read(path, expected, cap):
        value = snapshot(path, cap)
        exact(value['sha256'], expected, 'matched input pin')
        saved.append((path, cap, value))
        return value['raw']

    raw = {role: read(inputs.PARENT / name, expected, cap)
           for role, (name, expected, cap) in inputs.SOURCE_ROLES.items()}
    request = parse(raw['registered_request'])
    scope = pinned_scope(request, parse(raw['registered_plan']))
    context = request_context(raw['prompt'], request['requestID'], scope)
    agreement(parse(read(inputs.PARENT / 'expected-agreement.json', inputs.AGREEMENT_SHA, 65536)), context)
    reference = read(Path(args.reference).absolute(), args.reference_sha256, 32*1024**2)
    checked = check_reference(reference, context)
    for path, cap, before in saved:
        exact(snapshot(path, cap, keep=False), dict(before, raw=None), 'matched input recheck')
    output = Path(args.output_directory).absolute()
    output.mkdir(mode=0o700, exist_ok=False)
    expected_path = output / 'expected-token-ids.json'
    write_result(expected_path, checked['selected'])
    shared = dict(schema='private_qwen27b_matched_timing_inputs_v1',
        specification=spec, promptTokenIDs=parse(raw['prompt']), expectedTokenIDs=checked['selected'],
        expectedFileSHA256=inputs.digest(expected_path),
        referencePath=str(Path(args.reference).absolute()), referenceSHA256=args.reference_sha256,
        referenceValidated=True, numericalComparisonPerformed=False, capacityGranted=False,
        compilerModelOrRemoteExecuted=False)
    write_result(output / 'shared-inputs.json', shared)
    print(json.dumps(dict(expectedFileSHA256=inputs.digest(expected_path),
                         sharedInputsSHA256=inputs.digest(output / 'shared-inputs.json'))))


if __name__ == '__main__':
    main()
