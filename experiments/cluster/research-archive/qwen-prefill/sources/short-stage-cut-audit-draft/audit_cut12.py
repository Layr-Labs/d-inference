#!/usr/bin/env python3
"""Bounded CPU replay for one completed registered9B cut12 short comparison."""
import argparse
from pathlib import Path
import sys
sys.dont_write_bytecode = True
from cut12_expected import canonical, digest, parse, require
from qwen_layer_stage_cut12_audit import check_recorded_pair

EXPECTED_RAW_SHA256 = '3f0d18b1d47eeb1e7eadff19fd813e92a4b3b0eab12ceac2360bfc5c716fb3c3'
PROMPT_IDS_SHA256 = 'efeae75f37c991053666b8e9e27c42f5bd0f04ffab696af958c022054844bd7b'
TEACHER_IDS_SHA256 = '0da2bf1076361795826d14d9f301fdd3724b63c0003884c361ca305902e06bea'


def bounded(path, limit):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= limit, 'Input path/type/size differs')
    with path.open('rb') as stream:
        raw = stream.read(limit+1)
    require(0 < len(raw) <= limit, 'Input exceeds byte bound')
    return raw


def records(raw):
    require(0 < len(raw) <= 64*1024**2 and raw.endswith(b'\n'), 'Incomplete/oversized stdout')
    lines = raw.splitlines()
    require(len(lines) == 2 and all(0 < len(line) <= 60*1024**2 for line in lines), 'Expected exactly two complete JSON records')
    rows = [parse(line) for line in lines]
    require(all(type(row) is dict for row in rows), 'Records must be objects')
    return rows


def check_inputs(prompt, teacher):
    for value, count, pin in [(prompt,65,PROMPT_IDS_SHA256),(teacher,3,TEACHER_IDS_SHA256)]:
        require(type(value) is list and len(value) == count and all(type(token) is int and 0 <= token < 248320 for token in value),
                'Wrong bounded token history')
        require(digest(canonical(value)) == pin, 'Actual history differs from pinned natural prefix/teacher origin')


def validate(stdout_path, prompt_path, teacher_path, expected_path=None):
    expected_path = expected_path or Path(__file__).with_name('cut12-expected.json')
    paths = [Path(path).resolve() for path in (stdout_path,prompt_path,teacher_path,expected_path)]
    require(len(set(paths)) == 4, 'Distinct stdout/input/expected paths required')
    limits = [64*1024**2,65536,65536,2*1024**2]
    inputs = [bounded(path,limit) for path,limit in zip(paths,limits)]
    stdout, prompt_raw, teacher_raw, expected_raw = inputs
    require(digest(expected_raw) == EXPECTED_RAW_SHA256, 'Frozen expected inventory file differs')
    prompt, teacher, expected = map(parse,(prompt_raw,teacher_raw,expected_raw))
    check_inputs(prompt,teacher)
    checkpoint, report = records(stdout)
    recorded = checkpoint['baseline']['request']
    require(canonical(recorded['promptTokenIDs']) == canonical(prompt)
            and canonical(recorded['teacherTokenIDs']) == canonical(teacher), 'Output history differs from supplied pinned files')
    result = check_recorded_pair(checkpoint,report,expected)
    for path,limit,old in zip(paths,limits,inputs):
        require(bounded(path,limit) == old, 'Audit input changed during replay')
    result.update(kind='qwen_short_stage_cut12_cpu_audit', schemaVersion=1,
        inputs=[dict(path=str(path),sizeBytes=len(raw),sha256=digest(raw)) for path,raw in zip(paths,inputs)],
        modelPayloadRead=False,nativeExecutionPerformed=False,sourceAndRuntimeProvenanceIndependentlyVerified=False,
        planControlIsProspectiveMetadata=True,
        limits='Eight complete native logit rows reconstructed from recorded values; paired raw state arrays are not exported. Source/build/resource/process provenance remains a separate audit.')
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stdout',required=True,type=Path)
    parser.add_argument('--prompt',required=True,type=Path)
    parser.add_argument('--teacher',required=True,type=Path)
    parser.add_argument('--expected',type=Path)
    args = parser.parse_args(argv)
    import json
    print(json.dumps(validate(args.stdout,args.prompt,args.teacher,args.expected),sort_keys=True,allow_nan=False))


if __name__ == '__main__':
    main()
