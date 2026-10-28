"""Bind the reviewed solo supervisor after build/check and matched-input creation; no launch or deployment."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import uuid
from build_inputs import BASE, digest, verify, verify_preparation

REMOTE = Path('/Users/developer/DarkbloomDev/qwen27b-resident-solo-generation-20260915')
PARENT = BASE.parent / 'qwen27b-8k-serial-owner-qualification-20260915'
PROMPT_SHA = 'ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--attempt', type=int, choices=range(1, 10), required=True)
    parser.add_argument('--matched-inputs', required=True)
    parser.add_argument('--matched-inputs-sha256', required=True)
    args = parser.parse_args()
    frozen = verify_preparation(); verify()
    template = BASE / 'run-template'
    sys.path.insert(0, str(template))
    from binding_inputs import snapshot
    from binding_common import canonical, parse, pin, require, same
    source = Path(args.matched_inputs).absolute()
    saved = snapshot(source, 1024**2)
    same(saved['sha256'], pin(args.matched_inputs_sha256), 'matched input pin')
    shared = parse(saved['raw'])
    same(shared['schema'], 'private_qwen27b_matched_timing_inputs_v1', 'matched input schema')
    spec_path = BASE.parent / 'qwen27b-matched-timing-inputs-draft-20260915/specification.json'
    same(digest(spec_path), 'cecda245d1224361ed0d1865ad3ad35d44876c2e1b530c0322031ed117576f1f', 'matched specification pin')
    same(shared['specification'], parse(spec_path.read_bytes()), 'frozen matched timing specification')
    same(shared['referenceSHA256'], shared['specification']['referenceSHA256'], 'matched reference identity')
    same(shared['referenceValidated'], True, 'reference gate')
    prompt = (PARENT / 'inputs/prompt.ids.json').read_bytes()
    same(hashlib.sha256(prompt).hexdigest(), PROMPT_SHA, 'shared raw prompt')
    same(shared['promptTokenIDs'], parse(prompt), 'shared prompt IDs')
    expected = shared['expectedTokenIDs']
    require(type(expected) is list and len(expected) == 128 and
            all(type(token) is int and 0 <= token < 248320 for token in expected), 'Expected128 reference IDs')
    expected_raw = canonical(expected) + b'\n'
    expected_sha = hashlib.sha256(expected_raw).hexdigest()
    same(expected_sha, shared['expectedFileSHA256'], 'shared expected ID file')
    attempt = str(args.attempt)
    build_path = BASE / ('build-' + attempt) / 'receipt.json'
    check_path = BASE / ('check-' + attempt) / 'receipt.json'
    built, checked = parse(build_path.read_bytes()), parse(check_path.read_bytes())
    require(built.get('passed') is True and checked.get('passed') is True,
            'Successful corresponding native build and CPU checks required')
    same(built['binarySHA256'], checked['binarySHA256'], 'checked executable')
    same(built['buildPreparationManifestSHA256'], frozen, 'build preparation')
    bundle_path = BASE / ('runtime-bundle-' + attempt) / 'bundle.json'
    bundle = parse(bundle_path.read_bytes())
    source_manifest = BASE / ('build-manifest-' + attempt + '.json')
    same(bundle['sourceManifestSHA256'], digest(source_manifest), 'bundle source manifest')
    files = {row['path']: row for row in bundle['files']}
    same(files['cluster-inference']['sha256'], built['binarySHA256'], 'bundle native')
    for name, row in files.items():
        file = bundle_path.parent / name
        require(not file.is_symlink() and file.stat().st_size == row['bytes'] and digest(file) == row['sha256'],
                'Actual built bundle differs')
    output = BASE / ('run-source-' + attempt); output.mkdir(mode=0o700)
    lineage = parse((BASE / 'run-template-lineage.json').read_bytes())
    for name, wanted in lineage['runtimeFiles'].items():
        raw = (template / name).read_bytes()
        same(hashlib.sha256(raw).hexdigest(), wanted, 'run source template')
        if name == 'solo_inputs.py':
            require(raw.count(b'UNBOUND_NATIVE_SHA256') == 1 and raw.count(b'UNBOUND_BUILD_MANIFEST_SHA256') == 1,
                    'Exactly two build-binding placeholders required')
            raw = raw.replace(b'UNBOUND_NATIVE_SHA256', built['binarySHA256'].encode()).replace(
                b'UNBOUND_BUILD_MANIFEST_SHA256', digest(source_manifest).encode())
        destination = output / name; destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with destination.open('xb') as stream: stream.write(raw)
    (output / 'inputs').mkdir(mode=0o700)
    for name, raw in [('prompt.ids.json', prompt), ('expected-token-ids.json', expected_raw)]:
        with (output / 'inputs' / name).open('xb') as stream: stream.write(raw)
    job = dict(schema='private_resident_solo_generation_job_v1', request_id=str(uuid.uuid4()),
        deployment=str(REMOTE / 'native'), model_dir='/Users/developer/DarkbloomDev/models/Qwen3.8-27B',
        prompt_file=str(REMOTE / 'supervisor/inputs/prompt.ids.json'), prompt_sha256=PROMPT_SHA,
        expected_file=str(REMOTE / 'supervisor/inputs/expected-token-ids.json'), expected_sha256=expected_sha,
        run_dir=str(REMOTE / ('runs/cohort-' + attempt)), bundle_sha256=digest(bundle_path),
        native_sha256=built['binarySHA256'], metallib_sha256=files['mlx.metallib']['sha256'],
        source_manifest_sha256=digest(source_manifest), stage_cut=16, output_count=128, stop_token_ids=[],
        native_seconds=300, parent_seconds=315, registered_model='registered_qwen38_27b',
        prompt_count=8192, chunk_size=512)
    require(job['request_id'] != shared['specification']['referenceRequestID'], 'Fresh timing request identity required')
    module_spec = importlib.util.spec_from_file_location('bound_solo_inputs', output / 'solo_inputs.py')
    module = importlib.util.module_from_spec(module_spec); module_spec.loader.exec_module(module)
    module.validate_job(job)
    with (output / 'job.json').open('xb') as stream: stream.write(canonical(job) + b'\n')
    same(snapshot(source, 1024**2, keep=False), dict(saved, raw=None), 'matched input recheck')
    same(verify_preparation(), frozen, 'preparation recheck')
    rows = [dict(path=str(p.relative_to(output)), bytes=p.stat().st_size, sha256=digest(p))
            for p in sorted(output.rglob('*')) if p.is_file()]
    require(len(rows) <= 64, 'Existing launcher member bound')
    manifest = dict(files=rows, schema='private_qwen27b_solo_supervisor_v1',
        templateLineageSHA256=digest(BASE / 'run-template-lineage.json'), matchedInputsSHA256=args.matched_inputs_sha256)
    with (output / 'manifest.json').open('xb') as stream: stream.write(canonical(manifest) + b'\n')
    print(json.dumps(dict(supervisor=str(output), launcherSHA256=digest(output / 'manifest.json'),
        jobSHA256=digest(output / 'job.json'), remoteRun=str(REMOTE / ('runs/cohort-' + attempt)),
        nativeModelOrRemoteExecuted=False)))


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    os.umask(0o077)
    main()
