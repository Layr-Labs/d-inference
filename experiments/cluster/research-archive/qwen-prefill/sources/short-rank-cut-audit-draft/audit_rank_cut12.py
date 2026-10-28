#!/usr/bin/env python3
"""Bounded saved-record replay for the explicit registered9B short12/20 rank pair."""
import argparse
import importlib.util
import json
from pathlib import Path
import stat
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
CORE_PATH = ROOT / 'qwen_layer_stage_rank_cut12_audit.py'
CORE_SHA256 = '9f78cf424b1b5c0a50cc7eaef00925332929e9cbded8e6fc55a1c4f4b1159be3'
BASE_PATH = ROOT.parent / 'short-stage-cut-audit-draft/qwen_layer_stage_cut12_audit.py'
BASE_SHA256 = '00e07565fab523fded70caa3aabbcaa2064ede8291e1886e9701b455c446c2fe'
EXPECTED_PATH = ROOT.parent / 'short-stage-cut-audit-draft/cut12-expected.json'
EXPECTED_SHA256 = '3f0d18b1d47eeb1e7eadff19fd813e92a4b3b0eab12ceac2360bfc5c716fb3c3'
PROMPT_SHA256 = '667b2e8232e3fc941469be79c3a178469b7d90c23d6f3ef1de4bd8bd87a813fc'
TEACHER_SHA256 = 'aad3b6387a197e052f32d75bd3d0aead834da80e577279665e04966e81c27fbc'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(raw):
    import hashlib
    return hashlib.sha256(raw).hexdigest()


def bounded(path, limit):
    path = Path(path)
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= limit, 'Wrong input type/size')
    with path.open('rb') as stream:
        raw = stream.read(limit + 1)
    require(0 < len(raw) <= limit, 'Input exceeded byte limit')
    return raw


def core():
    require(digest(bounded(CORE_PATH, 65536)) == CORE_SHA256, 'Frozen rank oracle changed')
    require(digest(bounded(BASE_PATH, 65536)) == BASE_SHA256, 'Frozen comparison oracle changed')
    spec = importlib.util.spec_from_file_location('short_rank_cut12_core', CORE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate(paths, reference_path, epoch, prompt_path, teacher_path, expected_path=None):
    """Caller supplies two complete rank files plus the actual retained input files."""
    require(type(paths) in (list, tuple) and len(paths) == 2, 'Need ordered rank0/rank1 paths')
    supplied = [Path(p) for p in (*paths, reference_path, prompt_path, teacher_path, expected_path or EXPECTED_PATH)]
    require(len({p.resolve() for p in supplied}) == 6, 'Distinct input paths required')
    limits = [32 * 1024**2] * 3 + [65536, 65536, 2 * 1024**2]
    saved = [bounded(p, n) for p, n in zip(supplied, limits)]
    require(all(raw.endswith(b'\n') for raw in saved[:3]), 'Incomplete stdout line')
    require(digest(saved[3]) == PROMPT_SHA256, 'Actual raw prompt pin differs')
    require(digest(saved[4]) == TEACHER_SHA256, 'Actual raw teacher pin differs')
    require(digest(saved[5]) == EXPECTED_SHA256, 'Frozen expected inventory differs')
    helper_saved = [bounded(p, 65536) for p in (CORE_PATH, BASE_PATH)]
    audit = core()
    reference_rows, reference_sha = audit.read_rows(supplied[2])
    require(reference_sha == audit.BASELINE_STDOUT_SHA, 'Frozen reference raw bytes differ')
    prompt, teacher, expected = [audit.base_helper().parse_json(raw.decode('utf-8')) for raw in saved[3:]]
    recorded = reference_rows[0]['baseline']['request']
    audit.exact(recorded['promptTokenIDs'], prompt, 'Actual retained prompt')
    audit.exact(recorded['teacherTokenIDs'], teacher, 'Actual retained teacher')
    result = audit.validate(supplied[:2], supplied[2], epoch, expected)
    for path, limit, old in zip(supplied, limits, saved):
        require(bounded(path, limit) == old, 'Input changed during CPU replay')
    for path, old in zip((CORE_PATH, BASE_PATH), helper_saved):
        require(bounded(path, 65536) == old, 'Helper changed during CPU replay')
    result.update(kind='qwen_short_rank_cut12_cpu_audit', schemaVersion=1,
        explicitStageCut=12, sourceLayerRanges=[[0,12],[12,32]],
        inputs=[dict(path=str(p.resolve()), sizeBytes=len(raw), sha256=digest(raw)) for p,raw in zip(supplied,saved)],
        helpers=[dict(path=str(p),sizeBytes=len(raw),sha256=digest(raw)) for p,raw in zip((CORE_PATH,BASE_PATH),helper_saved)],
        sourceAndRuntimeProvenanceIndependentlyVerified=False,
        candidateRawLogitRowsReconstructed=4, referenceRawLogitRowsReconstructed=8,
        physicalTransferQualified=False, throughputQualified=False,
        inputFilesUnchangedAfterReplay=True)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rank0', required=True, type=Path)
    parser.add_argument('--rank1', required=True, type=Path)
    parser.add_argument('--reference', required=True, type=Path)
    parser.add_argument('--epoch', required=True)
    parser.add_argument('--prompt', required=True, type=Path)
    parser.add_argument('--teacher', required=True, type=Path)
    parser.add_argument('--expected', type=Path)
    args = parser.parse_args(argv)
    result = validate([args.rank0,args.rank1],args.reference,args.epoch,args.prompt,args.teacher,args.expected)
    print(json.dumps(result,sort_keys=True,allow_nan=False))


if __name__ == '__main__':
    main()
