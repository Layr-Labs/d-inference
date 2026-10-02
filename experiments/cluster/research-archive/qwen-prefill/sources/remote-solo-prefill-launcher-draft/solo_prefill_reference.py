"""Bind original reference bytes separately from the unchanged worker's JSON bytes."""
import hashlib
import json
from pathlib import Path
from prefill_compute_archive import digest
from prefill_compute_contract import parse, require
from prefill_compute_inputs import ARTIFACT, CONFIGURATION, VOCABULARY

ORIGIN_REFERENCE_SHA256 = '782138cb276748af1b4a8d9f2d5d76461ae9973a5919e4f4317035c551b2976b'
BASELINE_EVIDENCE_SHA256 = '54213f9c90b92033cf9ea78976f3cd8f6af355dc45930f6432a49351f97bc1a8'
MAX_REFERENCE_BYTES = 128 * 1024


def worker_bytes(value):
    # rank_worker.py calls write_text(json.dumps(content)): ASCII JSON, no LF.
    return json.dumps(value, allow_nan=False).encode('ascii')


def rank_input_order(value):
    # Our rank.json writer sorts every object. Match its later json.loads order.
    return parse(json.dumps(value, sort_keys=True, allow_nan=False))


def archive_reference(path, prompt, output):
    path = Path(path)
    require(path.is_file() and not path.is_symlink()
            and 0 < path.stat().st_size <= MAX_REFERENCE_BYTES, 'Reference is not a bounded regular file')
    with path.open('rb') as stream:
        raw = stream.read(MAX_REFERENCE_BYTES + 1)
    require(len(raw) <= MAX_REFERENCE_BYTES and hashlib.sha256(raw).hexdigest() == ORIGIN_REFERENCE_SHA256,
            'Original reference file pin differs')
    descriptor = parse(raw)
    require(isinstance(descriptor, dict), 'Reference must be an object')
    require(descriptor.get('baselineEvidenceFingerprint') == BASELINE_EVIDENCE_SHA256,
            'Reference baseline evidence pin differs')
    source, request = descriptor.get('source', {}), descriptor.get('request', {})
    require(source.get('artifactAggregateSHA256') == ARTIFACT
            and source.get('sourceConfigurationSHA256') == CONFIGURATION,
            'Reference source artifact/configuration differs')
    require(type(prompt) is list and len(prompt) == 65
            and all(type(x) is int and 0 <= x < VOCABULARY for x in prompt), 'Wrong fixed prompt')
    prompt_hash = hashlib.sha256(','.join(map(str, prompt)).encode()).hexdigest()
    require(request.get('promptTokenIDsSHA256') == prompt_hash
            and request.get('promptCount') == 65 and request.get('chunkSize') == 32
            and request.get('outputCount') == 1 and request.get('vocabularySize') == VOCABULARY,
            'Reference prompt history/bounds differ')
    ordered = rank_input_order(descriptor)
    staged = worker_bytes(ordered)
    require(len(staged) <= MAX_REFERENCE_BYTES, 'Worker-serialized reference exceeds native admission bound')
    folder = output / 'inputs'
    folder.mkdir(mode=0o700, exist_ok=True)
    entries = []
    for name, content in (('solo-reference.origin.json', raw), ('solo-reference.staged.json', staged)):
        target = folder / name
        with target.open('xb') as stream:
            stream.write(content)
        target.chmod(0o400)
        entries.append(dict(path=target.relative_to(output).as_posix(), sha256=digest(target), size_bytes=len(content)))
    require(digest(path) == ORIGIN_REFERENCE_SHA256, 'Origin changed during reference staging')
    return dict(descriptor=ordered, source=source, origin_file_sha256=ORIGIN_REFERENCE_SHA256,
                staged_file_sha256=hashlib.sha256(staged).hexdigest(),
                baseline_evidence_sha256=BASELINE_EVIDENCE_SHA256, files=entries,
                worker_serialization='json.dumps(content), default separators/ensure_ascii, no newline',
                original_and_staged_bytes_identical=raw == staged,
                native_baseline_forward_required=False)


def verify_rank_serialization(rank_path, reference):
    """Read exact saved rank.json, as the worker will, before any upload/start."""
    config = parse(rank_path.read_bytes())
    value = config['input_files']['solo-reference.json']
    require(worker_bytes(value) == worker_bytes(reference['descriptor']),
            'Saved rank descriptor differs from the independently retained worker serialization')
    expected = reference['staged_file_sha256']
    require(hashlib.sha256(worker_bytes(value)).hexdigest() == expected, 'Saved worker reference SHA differs')
    args = config['arguments']
    for flag, value in (('--solo-reference-file', '@rank/solo-reference.json'),
                        ('--solo-reference-sha256', expected),
                        ('--solo-baseline-evidence-sha256', BASELINE_EVIDENCE_SHA256)):
        require(args.count(flag) == 1 and args[args.index(flag) + 1] == value,
                'Saved reference argument differs: ' + flag)
