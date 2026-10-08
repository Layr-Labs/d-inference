"""CPU-only supplement for one preserved failed legacy launcher run.

Uses only AST-extracted, hash-pinned existing numerical checker definitions.
Never imports its native launcher dependencies or changes the failed receipt.
"""
import argparse
import ast
import hashlib
import json
import math
from pathlib import Path

RECEIPT_SHA = 'bacb333546eada286d2a24eda8b376f786a70fec3e72b0e994ada4b0ba2fac32'
PROSPECTIVE_MANIFEST_SHA = '59fc32d25555f271d1f5940e1fd505e61fcfcf3ab9fd82081fecdd83fe457d01'
FUNCTIONS = {'check_fixture_records', 'check_lifecycle_records', 'check_records'}


def require(value, message):
    if not value: raise ValueError(message)


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def extracted_checker(research):
    manifest = research / 'profiled-tiny-audit-draft/source-review-20260914.json'
    require(digest(manifest) == PROSPECTIVE_MANIFEST_SHA, 'Prospective source manifest changed')
    entries = json.loads(manifest.read_bytes())['sourceBindings']
    expected = next(entry['sha256'] for entry in entries if entry['path'] == 'cluster-research/validate-qwen-layer-stage.py')
    original = research / 'validate-qwen-layer-stage.py'
    require(digest(original) == expected, 'Existing legacy numerical checker changed')
    tree = ast.parse(original.read_text())
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in FUNCTIONS]
    require({node.name for node in functions} == FUNCTIONS, 'Missing existing numerical checker definition')
    require(not any(isinstance(node, (ast.Import, ast.ImportFrom)) for f in functions for node in ast.walk(f)), 'Unexpected checker import')
    module = ast.Module(body=functions, type_ignores=[])
    scope = {'require': require}
    exec(compile(module, str(original) + ':numerical-definitions-only', 'exec'), scope)
    return scope['check_records'], expected


def strict_records(path):
    with path.open('rb') as stream: raw = stream.read(8 * 1024**2 + 1)
    require(0 < len(raw) <= 8 * 1024**2 and raw.endswith(b'\n'), 'Legacy stdout bound/completion differs')
    lines = raw.splitlines(); require(len(lines) == 11 and all(lines), 'Expected exactly eleven complete native records')
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON key'); result[key] = value
        return result
    def floating(raw):
        value = float(raw); require(math.isfinite(value), 'Nonfinite JSON float'); return value
    def invalid(_): raise ValueError('Nonfinite native JSON constant')
    return [json.loads(line, object_pairs_hook=pairs, parse_float=floating, parse_constant=invalid,
        parse_int=lambda raw: -0.0 if raw == '-0' else int(raw)) for line in lines]


def audit(run, research):
    receipt_path = run / 'receipt.json'
    require(digest(receipt_path) == RECEIPT_SHA, 'Preserved failed receipt differs')
    receipt = json.loads(receipt_path.read_bytes())
    require(receipt['status'] == 'failed' and receipt['nativeExitCode'] == 0 and receipt['nativeReaped'] is True
            and receipt['primaryFailure'] == 'ValueError: Successful native check emitted stderr'
            and receipt['ownedProcessGroupAfter'] == [] and not receipt['cleanupErrors'] and not receipt['postRunErrors'],
            'This supplement applies only to the preserved stderr-contract failure')
    for name in ('stdout.jsonl', 'stderr.log'):
        require(digest(run / name) == receipt[name]['sha256'] and (run / name).stat().st_size == receipt[name]['sizeBytes'],
                'Saved native bytes differ from failed launcher receipt')
    checker, checker_sha = extracted_checker(research)
    rows = strict_records(run / 'stdout.jsonl')
    summaries = checker(rows)
    fp16_loader = rows[6]
    converted = [entry for receipt in fp16_loader['receipts'] for entry in receipt['activeTensors'] if entry['sourceDType'] == 'float16']
    require(len(converted) == fp16_loader['fp16MetadataTensorCount'] == 124
            and all(entry['loadedDType'] == 'bfloat16' for entry in converted), 'Intentional conversion metadata differs')
    byte_count = sum(entry['byteCount'] for entry in converted)
    stderr = (run / 'stderr.log').read_bytes()
    require(stderr == '[bf16] converted 124 params (0.1 MB) fp16→bf16 in 40 ms\n'.encode(), 'Observed stderr bytes differ')
    require(digest(receipt_path) == RECEIPT_SHA, 'Original receipt changed during CPU audit')
    return dict(kind='legacy_stage_numeric_supplement', schemaVersion=1, numericalChecksPassed=True,
        launcherOverallStatus='failed', launcherFailureUnchanged=True, originalReceiptSHA256=RECEIPT_SHA,
        originalStdoutSHA256=digest(run / 'stdout.jsonl'), originalStderrSHA256=digest(run / 'stderr.log'),
        existingNumericalCheckerSHA256=checker_sha, extractedFunctions=sorted(FUNCTIONS), nativeRecords=11,
        nativeExitCode=0, nativeLeaderReaped=True, ownedProcessGroupAfter=[], fixtures=summaries,
        stderrObserved=stderr.decode(), intentionalFP16ConvertedTensorCount=len(converted),
        intentionalFP16ConvertedBytes=byte_count, stderrFormattedMiB=round(byte_count / 1024**2, 1),
        nativeExecutedByThisAudit=False, gpuExecutedByThisAudit=False, sshExecutedByThisAudit=False,
        frozenRunnerOrOracleModified=False, throughputQualified=False,
        limitations=['Numerical CPU audit passes the unchanged existing checker; it does not retroactively pass the failed launcher.',
            'Native state/logit byte equality declarations remain supported by the native check, not reconstructed model execution.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True); parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); research = Path(__file__).resolve().parents[1]
    require(not args.output.exists(), 'Refusing to replace an existing audit supplement')
    result = audit(args.run, research)
    args.output.write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    print(json.dumps(dict(numericalChecksPassed=True, launcherOverallStatus='failed',
        output=str(args.output), sha256=digest(args.output)), sort_keys=True))


if __name__ == '__main__': main()
