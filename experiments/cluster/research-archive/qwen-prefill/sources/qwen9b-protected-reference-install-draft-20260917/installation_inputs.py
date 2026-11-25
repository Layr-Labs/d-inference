"""Bind exact frozen launcher files to an actual tokenizer-generated input packet."""
import hashlib
import json
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parent
REFERENCE = BASE.parent / 'qwen9b-protected-ordinary-reference-draft-20260917'
sys.path.insert(0, str(REFERENCE))
sys.path.insert(0, str(REFERENCE / 'package'))
from binding_common import parse, require, same
from binding_inputs import snapshot
from reference_inputs import validate_job, write_json
from reference_settings import require_short
from verify_sources import verify as verify_reference


def verify():
    manifest = json.loads((BASE / 'manifest.json').read_bytes())
    for row in manifest['files']:
        path = BASE / row['path']
        item = snapshot(path, 2*1024**2, empty=True)
        same((item['size_bytes'], item['sha256']), (row['bytes'], row['sha256']), 'Installer source pin')
    lineage = parse((BASE / 'lineage.json').read_bytes())
    same(snapshot(REFERENCE / 'manifest.json', 1024**2)['sha256'], lineage['referenceManifestSHA256'], 'Frozen ordinary reference')
    verify_reference()
    for row in lineage['reused']:
        same(snapshot(Path(row['path']), 1024**2, empty=True)['sha256'], row['sha256'], 'Reused helper pin')


def bound_inputs(directory, wanted):
    lineage = parse((BASE / 'lineage.json').read_bytes())
    retained = {Path(row['path']).name: row for row in lineage['actualRootInputPins']}
    same(wanted, retained['binding.json']['sha256'], 'Reviewed actual input binding')
    binding = snapshot(directory / 'binding.json', 16384)
    same(binding['sha256'], wanted, 'Actual root-generated input binding')
    value = parse(binding['raw'])
    job = snapshot(directory / 'job.json', 16384)
    same(job['sha256'], value['jobSHA256'], 'Actual job pin')
    parsed = validate_job(parse(job['raw'])); require_short(parsed)
    prompt = snapshot(directory / 'prompt.ids.json', 4096)
    same(prompt['sha256'], value['promptSHA256'], 'Actual prompt pin')
    same(prompt['sha256'], parsed['prompt_sha256'], 'Job/prompt join')
    tokens = parse(prompt['raw'])
    require(type(tokens) is list and len(tokens) == 32 and all(type(x) is int and 0 <= x < 248320 for x in tokens), 'Pinned32 tokens')
    same(snapshot(REFERENCE / 'package/manifest.json', 1024**2)['sha256'], value['launcherSHA256'], 'Exact launcher pin')
    same(parsed['native_sha256'], value['nativeSHA256'], 'Existing native pin')
    require(value['referenceExecuted'] is False and value['selectedTokenIDs'] is None, 'Prospective input packet required')
    return value


def prepare_tree(directory, binding, output):
    package = json.loads((REFERENCE / 'package/manifest.json').read_bytes())
    members = [('package/' + row['path'], REFERENCE / 'package' / row['path'], row['sha256']) for row in package['files']]
    members += [('package/manifest.json', REFERENCE / 'package/manifest.json', binding['launcherSHA256']),
                ('inputs/job.json', directory / 'job.json', binding['jobSHA256']),
                ('inputs/prompt.ids.json', directory / 'prompt.ids.json', binding['promptSHA256'])]
    require(len(members) == 24 and len({name for name, _, _ in members}) == 24, 'Exact small-tree membership')
    sources = {}
    for name, path, wanted in members:
        item = snapshot(path, 1024**2, empty=True)
        same(item['sha256'], wanted, 'Bound copy source changed: ' + name)
        sources[name] = dict(path=str(path), sha256=item['sha256'], bytes=item['size_bytes'], mode=0o600)
    manifest = dict(schema='qwen9b_reference_copy_only_tree_v1',
                    files={'check/' + name: {k: row[k] for k in ('bytes', 'sha256', 'mode')} for name, row in sources.items()})
    require(sum(x['bytes'] for x in sources.values()) < 2*1024**2, 'Small tree only; native/model transfer forbidden')
    write_json(output / 'deployment.json', manifest)
    write_json(output / 'sources.json', sources)
    return snapshot(output / 'deployment.json', 1024**2)['sha256'], manifest
