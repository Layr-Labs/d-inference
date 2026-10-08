"""CPU-only independent audits of the saved Qwen output experiments."""
import collections
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

RUNS = Path('/Users/developer/DarkbloomDev/cluster-research/runs')
HASHES = {}


def sha(path):
    path = Path(path)
    key = str(path)
    if key not in HASHES:
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        HASHES[key] = digest.hexdigest()
    return HASHES[key]


def read(path):
    sha(path)
    return json.loads(Path(path).read_text())


def f32(value):
    assert type(value) in (float, int) and math.isfinite(value)
    return struct.unpack('<f', struct.pack('<f', value))[0]


def native_bytes(values, dtype):
    output = bytearray()
    for value in values:
        bits = struct.unpack('<I', struct.pack('<f', f32(value)))[0]
        if dtype == 'bfloat16':
            assert bits & 65535 == 0, (value, hex(bits))
            output += struct.pack('<H', bits >> 16)
        else:
            assert dtype == 'float32'
            output += struct.pack('<I', bits)
    return bytes(output)


def verify_archive(base, driver):
    receipt = read(base / 'receipt.json')
    assert receipt['synthetic_only'] is True and receipt['performance_qualification'] is False
    assert sha(base / driver) == receipt['driver_sha256']
    assert sha(base / 'source-manifest.json') == receipt['source_manifest_sha256']
    manifest = read(base / 'source-manifest.json')
    for item in manifest:
        assert sha(base / 'source' / Path(item['path']).relative_to('experiments/cluster')) == item['sha256']
    for name, fingerprint in receipt['bundle_files'].items():
        assert sha(base / 'bundle' / name) == fingerprint
    return receipt, len(manifest)


def comparison(reference, candidate):
    assert len(reference) == len(candidate) == 8
    rows = []
    for index, (a, b) in enumerate(zip(reference, candidate)):
        assert len(a) == len(b) == 512 and all(math.isfinite(x) for x in a + b)
        rows.append(dict(row=index, max_absolute=max(abs(x-y) for x, y in zip(a, b)),
            relative_rms=math.sqrt(math.fsum((x-y)**2 for x, y in zip(a, b)) / math.fsum(x*x for x in a)),
            argmax_equal=max(range(512), key=a.__getitem__) == max(range(512), key=b.__getitem__)))
    return dict(rows=rows, exact=reference == candidate,
                passed=all(x['max_absolute'] < 1e-3 and x['relative_rms'] < 1e-4 and x['argmax_equal'] for x in rows))


def same_metrics(actual, recorded):
    assert actual['exact'] == recorded['exact'] and actual['passed'] == recorded['passed']
    for a, b in zip(actual['rows'], recorded['rows']):
        assert a['row'] == b['row'] and a['argmax_equal'] == b['argmax_equal']
        for key in ('max_absolute', 'relative_rms'):
            assert math.isclose(a[key], b[key], rel_tol=1e-13, abs_tol=1e-15), (key,a[key],b[key])


def summarize(records):
    groups = collections.defaultdict(list)
    for record in records:
        groups[(record['dtype'], record['policy'], record['partition'])].append(record)
    return [dict(dtype=key[0], policy=key[1], partition=key[2], cases=len(values),
        passed=sum(x['native_float32_metrics']['passed'] for x in values),
        exact=sum(x['native_float32_metrics']['exact'] for x in values),
        matching_argmax_rows=sum(y['argmax_equal'] for x in values for y in x['native_float32_metrics']['rows']),
        compared_rows=sum(len(x['native_float32_metrics']['rows']) for x in values),
        worst_row_relative_rms=max(y['relative_rms'] for x in values for y in x['native_float32_metrics']['rows']))
        for key, values in sorted(groups.items())]


def matrix_audit():
    base = RUNS / 'qwen-ffn-output-precision-20260913'
    receipt, source_count = verify_archive(base, 'validate-qwen-ffn-output-precision.py')
    # Re-run the frozen strict report/commitment validator too; numerical
    # calculations below are independent of both this validator and the driver.
    sys.path.insert(0, str(base / 'source'))
    from runtime.reports import reports as validate_reports
    from runtime.configuration import validate
    runs = {}
    rank_count = 0
    for execution in receipt['executions']:
        name = execution['name']; directory = base / name; run = read(directory / 'run.json')
        assert execution['exit_code'] == 0 and execution['verified_execution'] is True
        assert all(x == 0 for x in run['exit_codes']) and run['verified_execution'] is True
        assert run['hardware_throughput_candidate'] is False and run['cancellation_reason'] is None
        assert run['spec'] == validate(read(base / (name + '.spec.json')))
        bundle = directory / 'bundle'; manifest = read(bundle / 'bundle.json')
        assert sha(bundle / 'bundle.json') == execution['bundle_manifest_sha256'] == run['bundle_manifest_sha256']
        for item in manifest['files']:
            path = bundle / item['path']
            assert path.stat().st_size == item['size_bytes'] and sha(path) == item['sha256']
            if item['path'] in receipt['bundle_files']:
                assert item['sha256'] == receipt['bundle_files'][item['path']]
            else:
                assert item['sha256'] == sha(base / 'source/runtime' / item['path'])
        assert validate_reports(run['ranks'], run['spec']) == run['reports']
        work = run['spec']['workload']; dtype = work['synthetic_dtype']; peers = []
        for rank, report in enumerate(run['reports']):
            rank_count += 1
            target = directory / f'rank-{rank}'
            rank_config = read(target / 'rank.json')
            assert rank_config['bundle_sha256'] == run['bundle_manifest_sha256']
            sha(target / 'stdout.jsonl'); sha(target / 'stderr.log')
            assert report['schemaVersion'] == 9 and report['executionPath'] == 'cbv2-contiguous'
            assert report['modelFamily'] == 'qwen35' and report['feedForwardKind'] == 'dense'
            assert report['correctnessOnly'] is True and report['throughputMeasurementValid'] is False
            assert report['syntheticWeights'] is True and report['mtpEnabled'] is False
            for key, expected in [('attentionOutputPrecision',work['attention_output_precision']),
                                  ('ffnOutputPrecision',work['ffn_output_precision']),('ffnBranchPrecision','native')]:
                assert report[key] == expected
            prompt = read(target / 'prompt.json'); teacher = read(target / 'teacher.json')
            assert prompt == work['prompt_ids'] and teacher == work['teacher_tokens']
            assert hashlib.sha256(json.dumps(prompt,separators=(',',':')).encode()).hexdigest() == report['promptSHA256']
            assert hashlib.sha256(json.dumps(teacher,separators=(',',':')).encode()).hexdigest() == report['teacherSHA256']
            result = report['runs'][0]
            assert result['decodeInputTokens'] == teacher and result['decodeForwardCount'] == 7
            data = read(target / 'logits.json')
            assert len(data) == 8 and all(len(row) == 512 for row in data)
            for row in data:
                native_bytes(row, dtype)
            native = [[f32(value) for value in row] for row in data]
            argmax = [max(range(512),key=row.__getitem__) for row in native]
            assert argmax == result['localArgmaxTokens'] == result['generatedTokens']
            assert result['localArgmaxDisagreementCount'] == 0
            peers.append(data)
        assert all(peer == peers[0] for peer in peers)
        runs[name] = dict(raw=peers[0], native=[[f32(v) for v in row] for row in peers[0]], run=run)
    assert len(runs) == 78 and rank_count == 130

    def entry_name(item, policy=None, partition=None):
        return (f"{item['profile']}-{item['dtype']}-seed{item['seed']}-prompt{item['prompt_tokens']}-"
                f"{policy or item['policy']}-{partition or item['partition']}")

    output = dict(source_files_verified=source_count, executions_verified=len(runs),
                  rank_reports_and_logits_verified=rank_count, paired_ranks_exact=True,
                  comparisons=[], policy_departures=[], native_regressions=[])
    common_fields = ['model','modelFamily','configurationSHA256','promptSHA256','teacherSHA256','seed',
                     'chunkSize','embeddingActivationDType','ffnScaleDTypes','bf16ConversionEnabled',
                     'syntheticProfile','syntheticWeights','executionPath','ffnBranchPrecision']
    for kind in ('comparisons','policy_departures','native_regressions'):
        for item in receipt[kind]:
            candidate = runs[entry_name(item)]
            if kind == 'native_regressions':
                previous = RUNS / 'cbv2-inference-20260913' / f"{item['profile']}-bfloat16-seed7-cbv2-contiguous-{item['partition']}"
                reference_run = read(previous / 'run.json')
                raw = read(previous / 'rank-0/logits.json')
                reference = dict(raw=raw,native=[[f32(v) for v in row] for row in raw],run=reference_run)
            else:
                reference = runs[entry_name(item, partition='solo') if kind == 'comparisons'
                                 else entry_name(item, policy='native')]
            a, b = reference['run']['reports'][0], candidate['run']['reports'][0]
            for key in common_fields:
                assert a[key] == b[key], (kind,key)
            if kind == 'comparisons':
                assert a['attentionOutputPrecision'] == b['attentionOutputPrecision']
                assert a['ffnOutputPrecision'] == b['ffnOutputPrecision']
            else:
                assert a['parameterLayoutSHA256'] == b['parameterLayoutSHA256']
            serialized = comparison(reference['raw'], candidate['raw']); same_metrics(serialized, item)
            native = comparison(reference['native'], candidate['native'])
            assert native['passed'] == serialized['passed'] and native['exact'] == serialized['exact']
            result = {k:item[k] for k in ('profile','seed','prompt_tokens','dtype','policy','partition')}
            result.update(native_float32_metrics=native, serialized_metrics_reproduced=True,
                changed_argmax_rows=[x['row'] for x in native['rows'] if not x['argmax_equal']],
                reference_tokens=a['runs'][0]['generatedTokens'], candidate_tokens=b['runs'][0]['generatedTokens'])
            output[kind].append(result)
    # An already-F32 input makes both explicit promotions identities, per partition.
    output['float32_policy_identity_exact'] = all(
        runs[f'qwen27-heads-float32-seed7-prompt65-native-{p}']['native'] ==
        runs[f'qwen27-heads-float32-seed7-prompt65-both-{p}']['native'] for p in ('solo','ffn','full'))
    assert output['float32_policy_identity_exact']
    output['comparison_summary'] = summarize(output['comparisons'])
    output['solo_policy_departure_summary'] = summarize([x for x in output['policy_departures'] if x['partition']=='solo'])
    output['metrics_note'] = ('Driver metrics use parsed JSON decimal values. This audit reproduces those metrics, '
        'then reconstructs the exact Float32/BF16 values by IEEE754 rounding and recomputes metrics. '
        'Tiny decimal serialization differences change trailing digits, not any exact/pass/argmax conclusion.')
    output['limitations'] = ['Synthetic matched-policy numerical evidence only; no model-quality or real-artifact qualification.',
        'Explicit two-process loopback CBv2-contiguous path; no production scheduler, RDMA or throughput qualification.',
        'Source snapshot binds experiments, not the complete dependency build or model weight-content provenance.']
    return base, output


def head_audit():
    base = RUNS / 'qwen-output-boundaries-20260913'
    receipt, source_count = verify_archive(base, 'validate-qwen-synthetic-output-boundaries.py')
    assert receipt['status'] == 'passed'
    result = dict(source_files_verified=source_count, records=[], tail_crosschecks=[])
    zero = lambda n: dict(comparedValues=n,differingValues=0,exactValues=True,
                         maximumAbsoluteError=0,relativeRMSError=0,rootMeanSquareError=0)
    for execution in receipt['executions']:
        record = read(base / (execution['name']+'.json'))
        assert sha(base / (execution['name']+'.json')) == execution['result_sha256']
        assert record == execution['record'] and execution['exit_code'] == 0
        assert (base / (execution['name']+'.stderr')).read_bytes() == b''
        assert record['diagnosticOnly'] is True and record['throughputValid'] is False
        assert record['executionPath']=='ordinary' and record['mtpEnabled'] is False
        assert record['normAfterFullValues']==record['normAfterSliceValues']
        for key, values in [('normAfterFull',record['normAfterFullValues']),('normAfterSlice',record['normAfterSliceValues'])]:
            tensor=record[key];assert tensor['shape']==[1,128] and len(values)==128
            assert hashlib.sha256(native_bytes(values,tensor['dtype'])).hexdigest()==tensor['logicalBytesSHA256']
        assert record['normAfterFull']==record['normAfterSlice']
        assert record['normFullVersusSliced']==zero(128)
        assert record['originalVersusRecomputedFull']==zero(512)
        assert record['narrowedNormContribution']==zero(512)
        assert record['ordinaryFullLast']==record['recomputedFullLast']
        assert record['sliceAfterNormBeforeHead']==record['sliceBeforeNormAndHead']
        assert record['headFullVersusSingleRow']==record['ordinaryVersusFullyNarrowed']
        width=record['evaluatedChunkWidths'][-1];assert width in (1,2,32)
        assert sum(record['evaluatedChunkWidths'])==len(record['promptTokenIDs'])
        if width<32:assert record['headFullVersusSingleRow']==zero(512)
        else:assert record['headFullVersusSingleRow']['differingValues']>0
        result['records'].append(dict(name=execution['name'],last_chunk=width,
            norm_hashes_and_values_exact=True,full_replay_hash_exact=True,
            head_metrics=record['headFullVersusSingleRow'],
            argmax_equal=record['ordinaryFullLast']['argmaxToken']==record['sliceBeforeNormAndHead']['argmaxToken']))
    for dtype in ('float32','bfloat16'):
        probe=read(base / f'qwen27-heads-{dtype}-96-seed31.json');values=[]
        for path,key in [('ordinary','ordinaryFullLast'),('cbv2-contiguous','sliceBeforeNormAndHead')]:
            directory=RUNS/'cbv2-tail-shapes-20260913'/f'qwen27-heads-{dtype}-seed31-{path}-solo'
            run=read(directory/'run.json');report=run['reports'][0];raw=read(directory/'rank-0/logits.json')
            assert run['verified_execution'] and report['schemaVersion']==8
            for field in ('model','configurationSHA256','parameterLayoutSHA256','promptSHA256','syntheticProfile',
                          'embeddingActivationDType','ffnScaleDTypes','bf16ConversionEnabled','seed','chunkSize'):
                assert report[field]==probe[field]
            assert hashlib.sha256(native_bytes(raw[0],dtype)).hexdigest()==probe[key]['tensor']['logicalBytesSHA256']
            values.append([f32(v) for v in raw[0]])
        a,b=values;delta=[y-x for x,y in zip(a,b)];squares=math.fsum(x*x for x in delta)
        metrics=dict(comparedValues=512,differingValues=sum(x!=y for x,y in zip(a,b)),exactValues=a==b,
            maximumAbsoluteError=max(map(abs,delta)),rootMeanSquareError=math.sqrt(squares/512),
            relativeRMSError=math.sqrt(squares/math.fsum(x*x for x in a)))
        for key,value in metrics.items():assert math.isclose(value,probe['headFullVersusSingleRow'][key],rel_tol=1e-13,abs_tol=1e-16)
        result['tail_crosschecks'].append(dict(dtype=dtype,first_row_hashes_exact=True,recomputed_metrics=metrics))
    result.update(norm_arrays_reconstructed=24,norm_values_reconstructed=3072,
        limitations=['Probe exports norm values, but only hashes/metrics for logits. Independent head metric recomputation is possible for the two matching archived qwen27 tail cases, not the tiny32 case.',
                     'Projection shape alone reproduces those particular old first-output differences; CBv2 trunk/cache byte equality is not established.',
                     'No quality, scheduler, RDMA or throughput qualification.'])
    return base,result


if __name__=='__main__':
    assert len(sys.argv)==2 and sys.argv[1] in ('matrix','head')
    base,result=matrix_audit() if sys.argv[1]=='matrix' else head_audit()
    result.update(status='passed',audit_script_sha256=sha(Path(__file__)),evidence_sha256=HASHES,
                  native_processes_executed=False)
    output=base/'independent-cpu-audit.json'
    assert not output.exists(),output
    output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n')
    output.chmod(0o600)
    print('Saved',output,flush=True)
    if 'comparison_summary' in result:
        print(json.dumps(result['comparison_summary'],indent=2))
        print('SOLO DEPARTURES',json.dumps(result['solo_policy_departure_summary'],indent=2))
    else:print('Verified12 records,24 reconstructed native norm arrays and2 raw-tail crosschecks.')
