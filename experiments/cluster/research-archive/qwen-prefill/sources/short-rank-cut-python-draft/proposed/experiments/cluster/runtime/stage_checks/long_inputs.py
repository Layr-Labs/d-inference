"""Retain exact raw inputs; registered full-payload verification remains shared."""
from pathlib import Path
import os
import stat
from .common import digest, integer, parse, require, sha
from .inputs import retain
from . import long_phase
from .long_profile import ARTIFACT, CONFIGURATION, COMMANDS, VOCABULARY


def bounded_bytes(path, maximum):
    with Path(path).open('rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum, 'Metadata exceeds its regular-file bound')
        raw = stream.read(maximum + 1); after = os.fstat(stream.fileno())
    require(0 < len(raw) <= maximum and len(raw) == before.st_size,
            'Metadata grew or was truncated while retained')
    require((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns) ==
            (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns), 'Metadata changed during bounded reread')
    return raw


def prompt_ids(raw):
    require(0 < len(raw) <= 65536, 'Long prompt exceeds its raw 64 KiB bound')
    prompt = parse(raw)
    require(type(prompt) is list and len(prompt) == 8192, 'Long prompt requires exactly8192 IDs')
    for value in prompt: integer(value, 0, VOCABULARY - 1)
    return prompt


def prepare(args, output, epoch, artifacts):
    require(args.command in COMMANDS and args.artifact_aggregate_sha256 == ARTIFACT,
            'Only the explicitly pinned registered9B long profile is admitted')
    model = args.model_dir.expanduser().resolve(strict=True)
    folder = output / 'inputs'; folder.mkdir(mode=0o700)
    raw = retain(args.tokens_file, folder / 'prompt.json', 65536, sha(args.tokens_sha256))
    prompt = prompt_ids(raw)
    origin = retain(args.prompt_origin_file, folder / 'prompt-origin.json', 2 * 1024**2,
                    sha(args.prompt_origin_sha256))
    config = retain(model / 'config.json', folder / 'config.json', 1024**2, CONFIGURATION)
    manifest_raw = retain(model / 'manifest.json', folder / 'manifest.json', 4 * 1024**2)
    manifest = parse(manifest_raw)
    require(manifest['aggregate_sha256'] == ARTIFACT, 'Registered artifact declaration differs')
    integer(manifest['total_size_bytes'], 1, 8 * 1024**3)
    entries = [value for value in manifest['files'] if value.get('path') == 'config.json']
    require(len(entries) == 1 and entries[0]['sha256'] == CONFIGURATION, 'Configuration is not declared by artifact')
    artifacts.verify_model(model, ARTIFACT)
    require(digest(bounded_bytes(model / 'manifest.json', 4 * 1024**2)) == digest(manifest_raw), 'Manifest changed during verification')
    captured = [('prompt.json',raw),('prompt-origin.json',origin),('config.json',config),('manifest.json',manifest_raw)]
    files = []
    for name, value in captured:
        require(bounded_bytes(folder / name, len(value)) == value, 'Retained bytes changed during admission')
        files.append(dict(path='inputs/' + name, size_bytes=len(value), sha256=digest(value)))
    context = dict(mode=args.command, epoch=epoch, model=str(model), artifact=ARTIFACT,
        configuration_sha256=digest(config), manifest_sha256=digest(manifest_raw),
        prompt=prompt, prompt_file_sha256=digest(raw), prompt_token_ids_sha256=digest(','.join(map(str, prompt)).encode()),
        prompt_origin_sha256=digest(origin), raw_prompt_reencoded=False,
        prompt_origin_schema_audited=False, files=files,
        stage_prefill_policy=getattr(args, 'stage_prefill_policy', None),
        stage_logits_dtype=getattr(args, 'stage_logits_dtype', None))
    if long_phase.requested(args): context['prefill_phase_trace'] = True
    return context


def verify(context, output, artifacts):
    model = Path(context['model']); artifacts.verify_model(model, context['artifact'])
    require(digest(bounded_bytes(model / 'config.json', 1024**2)) == context['configuration_sha256'], 'Model configuration changed')
    require(digest(bounded_bytes(model / 'manifest.json', 4 * 1024**2)) == context['manifest_sha256'], 'Model manifest changed')
    for item in context['files']:
        path = output / item['path']
        require(digest(bounded_bytes(path, item['size_bytes'])) == item['sha256'],
                'Retained raw input or model metadata changed')
