"""Root-scheduled CPU qualification; --check performs source checks only."""
import argparse
import ast
import hashlib
import json
import time
from pathlib import Path
from owned_process import invoke_controller

ROOT = Path(__file__).resolve().parent
BONUS = ROOT.parent / 'gemma4-remote-mtp-bonus-continuation-20260920'
BONUS_MANIFEST = '4a0f58defd022b625bb614860fb2197f3080134211cb758a5749d7f8fe40d671'
STRICT_LINE = 'PASS 13 Foundation proposal-ledger groups; no native, physical or numerical qualification'


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path, maximum=2 * 1024**2):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'Not a regular non-symlink file: ' + str(path))
    require(0 < path.stat().st_size <= maximum, 'Source/read bound differs: ' + str(path))
    return path.read_bytes()


def pin(path, maximum=2 * 1024**2, empty=False):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'Not a regular file: ' + str(path))
    size = path.stat().st_size
    require((size > 0 or empty) and size <= maximum, 'File bound differs: ' + str(path))
    return dict(path=str(path), bytes=size, sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def verify_manifest(root, manifest):
    rows = json.loads(read(manifest))['members']
    require(isinstance(rows, list) and rows, 'Missing source inventory')
    seen = set()
    for row in rows:
        require(set(row) == {'path', 'bytes', 'sha256'}, 'Source record schema differs')
        rel = Path(row['path'])
        require(not rel.is_absolute() and '..' not in rel.parts and str(rel) not in seen,
                'Duplicate or nonlocal source path')
        seen.add(str(rel))
        actual = pin(root / rel)
        require(actual['bytes'] == row['bytes'] and actual['sha256'] == row['sha256'],
                'Source pin differs: ' + str(rel))
    return rows


def check():
    local_rows = verify_manifest(ROOT, ROOT / 'source-inputs.json')
    require(pin(BONUS / 'source-inputs.json')['sha256'] == BONUS_MANIFEST, 'Bonus freeze differs')
    bonus_rows = verify_manifest(BONUS, BONUS / 'source-inputs.json')
    labels = {name: json.loads(read(ROOT / (name + '-labels.json'))) for name in ('strict', 'bonus')}
    for name, values in labels.items():
        require(len(values) == len(set(values)) == 13 and all(type(x) is str for x in values),
                name + ' labels differ')
    # This reporting copy preserves every original executable assertion and operation.
    original = read(BONUS / 'Tests/StrictLedgerChecks.swift').decode()
    labeled = read(ROOT / 'StrictLedgerLabeledChecks.swift').decode()
    require(original.count('        var groups = 0\n') == 1, 'Strict group declaration differs')
    expected = original.replace('        var groups = 0\n',
                                '        var groups = 0\n        var passed: [String] = []\n', 1)
    needle = '            groups += 1\n'
    require(expected.count(needle) == 13, 'Strict group positions differ')
    parts = expected.split(needle)
    expected = parts[0] + ''.join(needle + '            passed.append(' + json.dumps(label) + ')\n' + part
                                 for label, part in zip(labels['strict'], parts[1:]))
    terminal = '        print("PASS \\(groups) Foundation proposal-ledger groups; no native, physical or numerical qualification")\n'
    require(expected.count(terminal) == 1, 'Strict terminal differs')
    expected = expected.replace(terminal, terminal +
        '        let bytes = try JSONSerialization.data(withJSONObject: ["schema":"gemma4_strict_ledger_labeled_checks_v1", "passed":passed, "nativeExecuted":false, "targetMathQualified":false], options:[.sortedKeys])\n'
        '        print(String(decoding:bytes,as:UTF8.self))\n')
    require(labeled == expected, 'Strict reporting copy changes more than labels/output')
    for name in ('run_controls.py', 'owned_process.py'):
        ast.parse(read(ROOT / name), filename=name)
    return dict(runnerManifest=pin(ROOT / 'source-inputs.json'),
                bonusManifest=pin(BONUS / 'source-inputs.json'),
                runnerMembers=local_rows, bonusMembers=bonus_rows, labels=labels)


def phase(out, name, argv, timeout):
    record = dict(argv=argv, timeoutSeconds=timeout)
    started = time.monotonic()
    try:
        with (out / (name + '.stdout')).open('xb') as stdout, (out / (name + '.stderr')).open('xb') as stderr:
            invoke_controller(argv, stdout, stderr, record, timeout=timeout)
        require(record.get('exitCode') == 0 and record.get('reaped') is True
                and record.get('groupAbsent') is True and record.get('killedOwnedGroup') is False,
                name + ' did not naturally succeed and retire its process group')
        record['status'] = 'passed'
    except BaseException as error:
        record.update(status='failed', error=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        record['elapsedSeconds'] = time.monotonic() - started
        # Logs remain on disk on every failure. Read/hash only bounded diagnostic logs.
        for suffix in ('stdout', 'stderr'):
            path = out / (name + '.' + suffix)
            if path.exists():
                size = path.stat().st_size
                record[suffix] = pin(path, maximum=1024**2, empty=True) if size <= 1024**2 else dict(path=str(path), bytes=size, boundExceeded=True)
        with (out / (name + '.json')).open('x') as stream:
            json.dump(record, stream, indent=2); stream.write('\n')
    require(all(record[x].get('boundExceeded') is not True for x in ('stdout', 'stderr')), name + ' log exceeds read bound')
    return record


def validate_output(path, labels, strict):
    lines = read(path, maximum=16384).decode().splitlines()
    if strict:
        require(len(lines) == 2 and lines[0] == STRICT_LINE, 'Strict summary differs')
        lines = lines[1:]
    require(len(lines) == 1, 'Unexpected fixture output')
    result = json.loads(lines[0])
    require(set(result) == {'schema', 'passed', 'nativeExecuted', 'targetMathQualified'}, 'Fixture output schema differs')
    schema = 'gemma4_strict_ledger_labeled_checks_v1' if strict else 'gemma4_bonus_continuation_checks_v1'
    require(result['schema'] == schema and result['passed'] == labels, 'Exact group labels differ')
    require(result['nativeExecuted'] is False and result['targetMathQualified'] is False, 'Unsupported execution claim')
    return result


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--check', action='store_true')
    modes.add_argument('--run', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    require(args.run == (args.output is not None), '--output is required only with --run')
    before = check()
    if args.check:
        print(json.dumps(dict(sourceOnly=True, strictGroups=13, bonusGroups=13, compilerExecuted=False, checksExecuted=False)))
        return
    out = args.output.resolve()
    out.mkdir(mode=0o700)  # Create-only; preserve all prior successful and failed attempts.
    receipt = dict(schema='gemma4_bonus_continuation_cpu_qualification_v1', inputs=before,
                   nativeInferenceExecuted=False, gpuExecuted=False, physicalCompletionEstablished=False,
                   targetMathQualified=False, phases={}, suites={})
    try:
        common = [BONUS / 'Runtime/AsyncMTPBonusContinuationPolicy.swift', BONUS / 'Runtime/AsyncMTPProposalLedger.swift']
        sources = dict(strict=common + [ROOT / 'StrictLedgerLabeledChecks.swift'],
                       bonus=common + [BONUS / 'Tests/Inputs/Gemma4MTPPullRecord.swift', BONUS / 'Runtime/Gemma4MTPPullMirror.swift', BONUS / 'Tests/BonusContinuationChecks.swift'])
        for name in ('strict', 'bonus'):
            binary = out / (name + '-checks')
            argv = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-j', '2',
                    '-module-cache-path', str(out / 'module-cache'), *map(str, sources[name]), '-o', str(binary)]
            receipt['phases'][name + 'Compile'] = phase(out, name + '-compile', argv, 90)
            receipt['phases'][name + 'Run'] = phase(out, name + '-run', [str(binary)], 10)
            require((out / (name + '-run.stderr')).stat().st_size == 0, 'Unexpected fixture stderr')
            result = validate_output(out / (name + '-run.stdout'), before['labels'][name], name == 'strict')
            receipt['suites'][name] = dict(groups=result['passed'], count=len(result['passed']),
                                          binary=pin(binary, maximum=32 * 1024**2))
        after = check()
        require(after == before, 'Pinned source changed during qualification')
        receipt.update(status='passed', totalPassed=26, sourcesUnchanged=True)
    except BaseException as error:
        receipt.update(status='failed', error=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        with (out / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2); stream.write('\n')
        print(json.dumps(dict(status=receipt['status'], receipt=str(out / 'receipt.json'),
                              totalPassed=receipt.get('totalPassed', 0))), flush=True)


if __name__ == '__main__':
    main()
