"""Bind the actual tokenizer packet to one reference job and shared member input."""
import argparse
import hashlib
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE / 'package'))
from binding_common import canonical, parse, require, same
from binding_inputs import snapshot
from reference_inputs import NATIVE, METALLIB, SOURCE, validate_job, write_json, write_new
from reference_settings import MODEL_DIRECTORY, NATIVE_DIRECTORY, REMOTE, REQUEST_ID, require_short
from prepare_prompt import ARTIFACT, MANIFEST, TOKENIZER


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--prompt-directory', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    prompt = snapshot(args.prompt_directory / 'prompt.ids.json', 65536)
    receipt = parse(snapshot(args.prompt_directory / 'prompt-receipt.json', 65536)['raw'])
    ids = parse(prompt['raw'])
    require(type(ids) is list and len(ids) == 32 and all(type(x) is int and 0 <= x < 248320 for x in ids), 'Actual 32-token packet')
    require(prompt['raw'] == canonical(ids) + b'\n', 'Canonical prompt bytes')
    for key, expected in dict(manifestSHA256=MANIFEST, artifactSHA256=ARTIFACT, tokenizerSHA256=TOKENIZER,
                              tokenizerBytes=19989343, promptFileSHA256=prompt['sha256'], tokenIDs=ids, promptCount=32,
                              modelOrGPUExecuted=False, generatorSHA256=hashlib.sha256((BASE / 'prepare_prompt.py').read_bytes()).hexdigest()).items():
        same(receipt.get(key), expected, 'Tokenizer receipt ' + key)
    same(receipt['allTokenIDs'][:32], ids, 'Actual selected prefix')
    job = dict(schema='private_registered_full_generation_reference_job_v1', request_id=REQUEST_ID,
        registered_model='registered_qwen35_9b', deployment=str(NATIVE_DIRECTORY), model_dir=str(MODEL_DIRECTORY),
        prompt_file=str(REMOTE / 'inputs/prompt.ids.json'), prompt_sha256=prompt['sha256'],
        run_dir=str(REMOTE / 'runs/reference-1'), bundle_sha256='3f312fd2cc9060b9ca960f8cc200983f371d52c0b64423a4266f0cd08f1f11aa',
        native_sha256=NATIVE, metallib_sha256=METALLIB, source_manifest_sha256=SOURCE,
        stage_cut=16, output_count=2, prompt_count=32, chunk_size=16, stop_token_ids=[], native_seconds=300, parent_seconds=315)
    validate_job(job); require_short(job)
    require(args.output.is_absolute() and args.output.parent.resolve() == args.output.parent, 'Canonical fresh output parent')
    args.output.mkdir(mode=0o700)
    write_new(args.output / 'prompt.ids.json', prompt['raw'])
    write_json(args.output / 'job.json', job)
    write_json(args.output / 'member-request.json', dict(schema='qwen9b_protected_shared_input_v1', requestID=REQUEST_ID,
        modelID='registered_qwen35_9b', profileID='registered_qwen35_9b_greedy_generation_v1',
        stageCut=16, prefillSchedule='serial_v1', promptTokenIDs=ids, chunkSize=16, outputCount=2, stopTokenIDs=[],
        promptFileSHA256=prompt['sha256'], artifactSHA256=ARTIFACT, mtpEnabled=False))
    write_json(args.output / 'binding.json', dict(jobSHA256=hashlib.sha256(canonical(job)+b'\n').hexdigest(),
        promptSHA256=prompt['sha256'], promptReceiptSHA256=snapshot(args.prompt_directory / 'prompt-receipt.json', 65536)['sha256'],
        launcherSHA256=snapshot(BASE / 'package/manifest.json', 1024**2)['sha256'], nativeSHA256=NATIVE,
        referenceExecuted=False, selectedTokenIDs=None))


if __name__ == '__main__':
    main()
