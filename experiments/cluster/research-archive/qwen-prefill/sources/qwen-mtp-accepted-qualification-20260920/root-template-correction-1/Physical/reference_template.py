"""Bind the existing guarded full-reference supervisor to actual same-source artifacts."""
import json
from pathlib import Path
from common import BASE, REMOTE, canonical, file_manifest, replace, sha, write, write_json


def stage(output, binding, bundle, prompt):
    target = output / 'reference'
    for source in sorted((BASE / 'templates/reference').rglob('*')):
        if not source.is_file():
            continue
        relative = source.relative_to(BASE / 'templates/reference'); raw = source.read_bytes()
        if source.suffix == '.py':
            text = raw.decode()
            text = text.replace('/Users/developer/DarkbloomDev/qwen9b-protected-reference-20260917', REMOTE + '/reference')
            if str(relative) == 'package/reference_settings.py':
                text = replace(text, '/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/native-aligned-payload', REMOTE + '/native')
                text = replace(text, "'f6a06d14-9138-4a19-aece-39207e1c874e'", repr(binding['requestID']))
                text = replace(text, 'output_count=2, stage_cut=16', 'output_count=8, stage_cut=4')
            if str(relative) == 'package/reference_inputs.py':
                text = replace(text, "NATIVE = 'd71726f61ff5cef6c2a7722b0a06fb7d6b7c61af2cb081ff3aef083803f32aac'", 'NATIVE = ' + repr(binding['referenceSHA256']))
                text = replace(text, "SOURCE = 'c80556866c63de8ff800cef947ea6467366bd561f6abcbdf5b73c919df30e183'", 'SOURCE = ' + repr(binding['sourceSnapshotSHA256']))
                text = replace(text, "bundle = fields(parse(raw), 'schemaVersion scope sourceManifestSHA256 files', 'bundle')\n    same(bundle['schemaVersion'], 1, 'bundle version')\n    require(type(bundle['scope']) is str and 1 <= len(bundle['scope']) <= 512, 'Bundle scope missing')\n    require(bundle['sourceManifestSHA256'] == job['source_manifest_sha256'], 'Bundle source reference differs')", "bundle = fields(parse(raw), 'schema files buildReceiptSHA256 sourceSnapshotSHA256 dependencySnapshotSHA256 acceptedManifestSHA256 nativeMTPQualified correctnessOnly servingEnabled physicalExecuted', 'bundle')\n    same(bundle, " + repr(bundle) + ", 'Exact actual same-source bundle metadata')\n    require(bundle['sourceSnapshotSHA256'] == job['source_manifest_sha256'], 'Bundle source reference differs')")
                text = replace(text, "expected = {'cluster-inference': NATIVE, 'mlx.metallib': METALLIB,", "expected = {'cluster-inference': NATIVE, 'darkbloom-cluster-worker': " + repr(binding['workerSHA256']) + ", 'mlx.metallib': METALLIB,")
                text = replace(text, "len(bundle['files']) == 3, 'Exactly three bundle members required'", "len(bundle['files']) == 4, 'Exactly four same-source bundle members required'")
            if str(relative) == 'package/reference_resources.py':
                text = replace(text, "integer(value['pressureLevel'],0,2)", "integer(value['pressureLevel'],1,1)")
            if str(relative) == 'validate_collected.py':
                for old, new in [("completedFrames'], 3, 'Two prefill frames plus one decode'", "completedFrames'], 9, 'Two prefill frames plus seven decode'"),
                                 ("committedTokens'], 33", "committedTokens'], 39"),
                                 ("maximumTokens'], 34", "maximumTokens'], 40"),
                                 ("selectedTokenIDs']), 2", "selectedTokenIDs']), 8")]:
                    text = replace(text, old, new)
            raw = text.encode()
        write(target / relative, raw)
    verify = '''"""Exact generated source closure, checked before and after the root action."""
import hashlib,json
from pathlib import Path
BASE=Path(__file__).resolve().parent
def verify():
    for root in (BASE, BASE/'package'):
        for row in json.loads((root/'manifest.json').read_bytes())['files']:
            p=root/row['path']; raw=p.read_bytes()
            if p.is_symlink() or len(raw)!=row['bytes'] or hashlib.sha256(raw).hexdigest()!=row['sha256']:
                raise ValueError('Bound reference source differs')
'''
    write(target / 'verify_sources.py', verify.encode())
    file_manifest(target / 'package')
    job = dict(schema='private_registered_full_generation_reference_job_v1', request_id=binding['requestID'],
        registered_model='registered_qwen35_9b', deployment=REMOTE + '/native',
        model_dir='/Users/developer/DarkbloomDev/models/Qwen3.5-9B', prompt_file=REMOTE + '/reference/inputs/prompt.ids.json',
        prompt_sha256=binding['promptSHA256'], run_dir=REMOTE + '/reference/runs/reference-1',
        bundle_sha256=binding['bundleSHA256'], native_sha256=binding['referenceSHA256'],
        metallib_sha256='2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2',
        source_manifest_sha256=binding['sourceSnapshotSHA256'], stage_cut=4, output_count=8,
        prompt_count=32, chunk_size=16, stop_token_ids=[], native_seconds=300, parent_seconds=315)
    write(target / 'inputs/prompt.ids.json', prompt)
    write_json(target / 'inputs/job.json', job)
    write_json(target / 'inputs/binding.json', dict(jobSHA256=sha(target / 'inputs/job.json'),
        promptSHA256=binding['promptSHA256'], launcherSHA256=sha(target / 'package/manifest.json'),
        nativeSHA256=binding['referenceSHA256'], referenceExecuted=False, selectedTokenIDs=None))
    file_manifest(target)
    return target
