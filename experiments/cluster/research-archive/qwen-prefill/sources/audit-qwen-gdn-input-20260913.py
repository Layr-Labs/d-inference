#!/usr/bin/env python3
"""CPU completion audit of four frozen GDN calls; never launches native code."""
import datetime
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True

RESEARCH = Path('/Users/developer/DarkbloomDev/cluster-research')
OUT = RESEARCH / 'runs/qwen-gdn-input-20260913'
REPO = Path('/Users/developer/DarkbloomDev/d-inference')
MODEL = Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B')
NATIVE = 'c1fef9e4950fe067787943c07fdfb1f58e514b7ea4658ca89c136bb34aa7063b'
AGGREGATE = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
CONFIG = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
DRIVER = '34f970701930c089d1713ef6efb0a56eea08363d1d3b896a9f6a99c8da7582af'
ORACLE = '8ce87bd399ec523bacf69cbd01dd15d0f0eab0d6b684aa2afc0e34d5eb984e1e'
EVIDENCE = {}


def require(value, message):
    if not value: raise ValueError(message)


def sha(path):
    path = Path(path)
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(4 * 1024**2), b''): h.update(block)
    result = h.hexdigest(); EVIDENCE[str(path)] = result
    return result


def read(path):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'Duplicate JSON field'); result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs,
        parse_int=lambda value: -0.0 if value == '-0' else int(value),
        parse_constant=lambda value: require(False, 'Nonfinite JSON'))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


def bind_metadata(receipt):
    require(receipt['status'] == 'failed' and receipt['error'] ==
        "TypeError: dict() got multiple values for keyword argument 'exact'", 'Unexpected original failure')
    require(receipt['expected_native_sha256'] == NATIVE and receipt['expected_aggregate_sha256'] == AGGREGATE,
        'Original binary/model pin changed')
    require(sha(OUT/'validate-qwen-gdn-input.py') == DRIVER and sha(OUT/'qwen_gdn_input_audit.py') == ORACLE,
        'Frozen driver or CPU oracle changed')
    for name, expected in receipt['driver_files_sha256'].items():
        require(sha(OUT/name) == expected, 'Archived helper differs: ' + name)
    require(sha(OUT/'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest changed')
    entries = read(OUT/'source-manifest.json')
    require(len(entries) == 157 and len({x['path'] for x in entries}) == 157, 'Source inventory changed')
    documentation_changes = []
    for entry in entries:
        archived = OUT/'source'/entry['path']; current = REPO/entry['path']
        require(archived.stat().st_size == entry['size_bytes'] and sha(archived) == entry['sha256'],
            'Archived source changed: ' + entry['path'])
        if sha(current) != entry['sha256']:
            require(current.suffix == '.md', 'Executable source changed: ' + entry['path'])
            documentation_changes.append(entry['path'])
    for name, expected in receipt['input_files_sha256'].items():
        require(sha(OUT/name) == expected, 'Frozen input changed')
    require(sha(OUT/'model-manifest.json') == receipt['model_manifest_sha256'] == sha(MODEL/'manifest.json'),
        'Manifest copy differs')
    require(sha(MODEL/'config.json') == CONFIG, 'Actual model config differs')
    return documentation_changes


def memory_and_cleanup(call):
    require(call['exit_code'] == 0 and call['outer_timeout_seconds'] == 195,
        'Native/launcher failure or deadline mismatch')
    require(0 < call['wall_seconds'] < 195, 'Native call exceeded its deadline')
    require(call['cleanup'] == dict(all_observed_owned_processes_exited=True,
        launcher_reaped=True, cancel_files_requested=False), 'Incomplete saved process cleanup')
    require(call['preflight']['passed'] is True and call['postflight']['passed'] is True,
        'Resource admission failed')
    samples = call['memory_samples']; require(len(samples) > 0, 'No resource samples')
    states = [call['preflight'], *samples, call['postflight']]
    for state in states:
        require(state['memory_pressure_level'] < 4 and state['severe_pressure'] is False,
            'Severe pressure observed')
        require(state['required_headroom_bytes'] == 7729163878 and
            state['diagnostic_extra_reserve_bytes'] == 512*1024**2 and
            state['diagnostic_known_extra_accounting_bytes'] == 380608512,
            'Resource planning bound differs')
        pages = dict((key, int(value)) for key,value in re.findall(r'^([^\n]+?):\s+(\d+)\.$',state['vm_stat'],re.M))
        reclaimable = sum(pages[k] for k in ('Pages free','Pages inactive','Pages speculative')) * state['page_size_bytes']
        require(reclaimable == state['estimated_reclaimable_bytes'], 'Saved reclaimable accounting differs')
        require(int(float(re.search(r'used = ([0-9.]+)M', state['swap_usage']).group(1))*1024**2)
            == state['swap_used_bytes'], 'Saved swap accounting differs')
    delta = max(s['swap_used_bytes'] for s in states)-states[0]['swap_used_bytes']
    require(delta == 0, 'This completed experiment claims zero new swap')
    require(call['peak_observed_owned_rss_bytes'] >= max(x['owned_process_rss_bytes'] for x in samples),
        'Peak RSS below saved samples')
    return dict(name=call['name'],native_exit_code=0,wall_seconds=call['wall_seconds'],
        resource_sample_count=len(samples),observed_pressure_levels=sorted({s['memory_pressure_level'] for s in states}),
        starting_swap_used_bytes=states[0]['swap_used_bytes'],maximum_new_swap_bytes=delta,
        peak_observed_owned_rss_bytes=call['peak_observed_owned_rss_bytes'],
        minimum_sampled_reclaimable_bytes=min(x['estimated_reclaimable_bytes'] for x in samples),
        saved_cleanup=call['cleanup'],memory_estimates_are_not_hard_process_caps=True)


def planned_commands(receipt, driver):
    common=['--prompt-tokens','32','--chunk-size','32','--decode-tokens','1','--repeats','1','--warmups','0',
        '--seed','7','--timeout-seconds','170','--execution-path','cbv2-contiguous',
        '--attention-output-precision','native','--ffn-output-precision','native','--ffn-branch-precision','native']
    expected=[]
    for dtype in ('float32','bfloat16'):
        expected.append(dict(name='tiny-'+dtype,command=[str(OUT/'bundle/cluster-inference'),'--mode',
            'qwen-gdn-input-check','--synthetic','--synthetic-profile','tiny','--synthetic-dtype',dtype,
            '--tokens-file',str(OUT/'synthetic-prompt-32.json'),*common]))
    launcher = receipt['planned_commands'][2]['command'][0]
    require(Path(launcher).name == 'python3.14', 'Unexpected original launcher interpreter')
    expected.append(dict(name='real9b-solo',command=[launcher,str(OUT/'source/experiments/cluster/run_inference.py'),
        '--spec',str(OUT/'real9b-solo.spec.json'),'--bundle',str(OUT/'bundle'),'--output',str(OUT/'real9b-solo')]))
    expected.append(dict(name='real9b-gdn',command=[str(OUT/'bundle/cluster-inference'),'--mode','qwen-gdn-input-check',
        '--model-dir',str(MODEL),'--artifact-aggregate-sha256',AGGREGATE,'--tokens-file',str(OUT/'prompt-32.json'),*common]))
    require(receipt['planned_commands'] == expected, 'Planned workload differs from independently reconstructed argv')
    require(receipt['planned_native_calls'] == len(receipt['native_calls']) == 4, 'Wrong native call count')
    for planned, call in zip(expected, receipt['native_calls']):
        require(call['name'] == planned['name'] and call['command'] == planned['command'], 'Actual argv differs')


def main():
    output = OUT/'independent-cpu-audit.json'
    require(not output.exists(), 'Preserve existing completion audit')
    original_hash = sha(OUT/'receipt.json'); receipt = read(OUT/'receipt.json')
    documentation_changes = bind_metadata(receipt)
    sys.path.insert(0,str(OUT)); sys.path.insert(0,str(OUT/'source/experiments/cluster'))
    # These archived modules have guarded mains. Only pure parsing/identity and
    # CPU selection functions are invoked; no launcher/preflight/model execution.
    driver = module('frozen_gdn_driver', OUT/'validate-qwen-gdn-input.py')
    oracle = sys.modules['qwen_gdn_input_audit']
    from runtime.artifacts import verify_model, verify_files
    from runtime.configuration import validate, rank_configuration
    from runtime.reports import reports
    bundle = read(OUT/'bundle/bundle.json')
    require(sha(OUT/'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest differs')
    require(verify_files(OUT/'bundle',bundle['files']) == receipt['bundle_files'], 'Archived bundle differs')
    for item in bundle['files']: sha(OUT/'bundle'/item['path'])
    # Exactly one complete actual-artifact rehash in this audit.
    require(verify_model(MODEL,AGGREGATE) == AGGREGATE, 'Actual artifact aggregate differs')
    print('Frozen source/bundle and actual model aggregate verified; no native execution.',flush=True)
    planned_commands(receipt,driver)
    prompt = read(OUT/'prompt-32.json'); synthetic_prompt = read(OUT/'synthetic-prompt-32.json')
    require(prompt == read(OUT/'prompt-96.json')[:32] and synthetic_prompt == list(range(3,35)), 'Prompt prefix differs')
    require(hashlib.sha256(oracle.canonical(read(OUT/'prompt-96.json'))).hexdigest() == receipt['frozen_96_prompt_sha256'],
        '96-token origin commitment differs')
    spec = read(OUT/'real9b-solo.spec.json'); require(validate(spec) == spec,'Invalid saved solo spec')
    require(spec['workload'] == dict(synthetic=False,prompt_ids=prompt,prompt_tokens=32,chunk_size=32,decode_tokens=1,
        repeats=1,warmups=0,seed=7,execution_path='cbv2-contiguous',attention_output_precision='native',
        ffn_output_precision='native',ffn_branch_precision='native'),'Wrong matched solo workload')
    run = read(OUT/'real9b-solo/run.json')
    require(run['spec'] == spec and run['exit_codes'] == [0] and run['verified_execution'] is True and
        run['hardware_throughput_candidate'] is False and run['cancellation_reason'] is None,'Solo execution differs')
    require(run['bundle_manifest_sha256'] == receipt['bundle_manifest_sha256'],'Solo bundle binding differs')
    require(verify_files(OUT/'real9b-solo/bundle',bundle['files']) == receipt['bundle_files'],'Staged solo bundle differs')
    rank = read(OUT/'real9b-solo/rank-0/rank.json')
    require(rank == rank_configuration(spec,0,OUT/'real9b-solo/bundle',receipt['bundle_manifest_sha256'],None),
        'Staged native solo arguments differ')
    require(read(OUT/'real9b-solo/rank-0/prompt.json') == prompt,'Staged solo prompt differs')
    require(reports(run['ranks'],spec) == run['reports'],'Raw solo report differs from validated saved reports')
    solo_report=run['reports'][0]
    require(solo_report['schemaVersion'] == 9 and solo_report['configurationSHA256'] == CONFIG and
        solo_report['runs'][0]['decodeForwardCount'] == 0 and solo_report['runs'][0]['decodeSeconds'] == 0,
        'Wrong solo schema/config/schedule')
    solo = driver.one_row(read(OUT/'real9b-solo/rank-0/logits.json'),248320)
    diagnostics={}; resources=[]; text=read(MODEL/'config.json')['text_config']
    for call in receipt['native_calls']:
        name=call['name']; resources.append(memory_and_cleanup(call))
        require(sha(OUT/(name+'-launcher')/'stdout.txt') == call['stdout_sha256'] and
            sha(OUT/(name+'-launcher')/'stderr.txt') == call['stderr_sha256'],'Raw launcher output changed')
        require((OUT/(name+'-launcher')/'stderr.txt').stat().st_size == 0,'Unexpected launcher stderr')
        for path,expected in call.get('evidence_sha256',{}).items(): require(sha(OUT/path)==expected,'Saved evidence changed')
        require(call['model_before_aggregate_sha256']==AGGREGATE,'Call artifact differs')
        if name!='real9b-gdn':require(call['status']=='validated' and call['model_after_aggregate_sha256']==AGGREGATE,'Prior call not validated')
        if name=='real9b-solo':
            require(call['result']==solo_report and sha(OUT/'real9b-solo/run.json')==call['run_sha256'] and
                sha(OUT/'real9b-solo/rank-0/logits.json')==call['logits_sha256'],'Saved solo receipt differs')
            continue
        require(sha(OUT/(name+'-launcher')/'stdout.txt') == call['result_sha256'],'Diagnostic hash differs')
        result=driver.read_diagnostic(OUT/(name+'-launcher')/'stdout.txt')
        synthetic=name.startswith('tiny-'); dtype=name.removeprefix('tiny-') if synthetic else 'bfloat16'
        driver.diagnostic_identity(result,synthetic,dtype,synthetic_prompt if synthetic else prompt,None if synthetic else CONFIG)
        computed=oracle.projection_oracle(result,driver.synthetic_text(dtype) if synthetic else text)
        oracle.verify_native_differences(result['componentDifferences'],computed)
        require(computed==call['cpu_projection_oracle'],'Independent recomputation differs from frozen partial receipt')
        if synthetic:require(computed['reassembled']['exact'],'Tiny control differs')
        diagnostics[name]=dict(oracle=computed,normalized_input_sha256=result['normalizedInput']['logicalBytesSHA256'],
            first_logits_sha256=result['firstLogits']['logicalBytesSHA256'],raw_output_sha256=call['result_sha256'])
        if not synthetic:
            load=result['verifiedDiagnosticLoad']
            require(load == dict(schemaVersion=1,verifiedAggregateSHA256=AGGREGATE,configurationSHA256=CONFIG,
                sourceModelTensorBytes=5038041600,loadedTensorBytes=5038041600,largestHostTensorBytes=508559360,
                tensorCount=927,sourceTensorCount=927,parameterLayoutSHA256=solo_report['parameterLayoutSHA256'],
                bf16ConversionEnabled=True),'Verified full-loader receipt differs')
            weight_checks=oracle.verify_real_weight_bytes(result,MODEL,text)
            require(weight_checks==call['independent_source_byte_checks'] and len(weight_checks)==10,'Source byte replay differs')
            diagnostics[name].update(verifiedDiagnosticLoad=load,selected_source_byte_checks=weight_checks,
                original_projection_tensor_hash_checks=12,fused_projection_tensor_hash_checks=9,input_norm_tensor_hash_checks=1)
            row=oracle.capture(result['firstLogits']); comparison=oracle.metrics(solo,row)
            require(comparison['exact'] and len(row)==248320,'Capture changed matched 32-token solo logits')
            require(oracle.logical_bytes(solo,result['firstLogits']['dtype']) ==
                oracle.logical_bytes(row,result['firstLogits']['dtype']),'Original-dtype logit bytes differ')
            require(solo_report['runs'][0]['generatedTokens']==[result['firstLogitArgmaxToken']],'Selected first token differs')
            comparison.update(original_dtype_bytes_exact=True,prior96_not_used_as_control=True)
            measured=computed['reassembled']
            require(measured['comparedValues']==395264 and measured['differingValues']==125801 and
                measured['maximumAbsoluteError']==.25 and math.isclose(measured['relativeRMSError'],.0026891772928119588,rel_tol=1e-14),
                'Frozen real projection result differs')
            require(all(not c['aggregate']['exact'] for r in computed['ranks'] for c in r['components']),
                'Expected every real rank/component to differ')
    # Current process enumeration is optional and denied by the managed sandbox.
    # Bind the four saved supervisor cleanup records; do not claim a fresh check.
    prior_attempt = read(RESEARCH/'qwen-gdn-input-audit-process-inventory-failure-20260913.json')
    require(prior_attempt['exit_code'] == 1 and prior_attempt['native_executions'] == 0 and
        sha(Path(prior_attempt['preserved_script'])) == prior_attempt['script_sha256'],
        'Preserved optional-inventory failure differs')
    sha(RESEARCH/'qwen-gdn-input-audit-process-inventory-failure-20260913.json')
    require(sha(OUT/'receipt.json')==original_hash,'Original failed receipt was mutated')
    require(sha(OUT/'validate-qwen-gdn-input.py')==DRIVER,'Original failed driver was mutated')
    error_line=[i for i,line in enumerate((OUT/'validate-qwen-gdn-input.py').read_text().splitlines(),1)
        if "dict(**comparison,exact=True,prior96_not_used_as_control=True)" in line]
    require(error_line==[210],'Known summary failure expression differs')
    fix=read(RESEARCH/'qwen-gdn-input-driver-summary-fix-20260913.json')
    require(fix['original_driver_sha256']==DRIVER and sha(Path(fix['preserved_original']))==DRIVER and
        fix['native_runs_after_fix']==0 and fix['native_source_changes']==0,'Future-driver correction evidence differs')
    sha(RESEARCH/'qwen-gdn-input-driver-summary-fix-20260913.json')
    result=dict(schema_version=1,status='passed',cpu_only=True,audited_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        audit_script_sha256=sha(Path(__file__)),original_driver_sha256=DRIVER,cpu_oracle_sha256=ORACLE,
        binary_sha256=NATIVE,source_manifest_sha256=receipt['source_manifest_sha256'],source_entries_verified=157,
        current_documentation_drift=documentation_changes,model_aggregate_sha256=AGGREGATE,actual_model_full_rehashes=1,
        planned_argv_matches=4,native_calls=4,native_exit_codes=[0,0,0,0],native_execution_and_completion_verified=True,
        original_driver_status='failed',original_driver_error=receipt['error'],original_summary_failure_line=210,
        original_failed_receipt_preserved=True,original_failed_receipt_sha256=original_hash,
        completion_reason='All four native calls completed and cleaned up; the driver failed only when duplicating an existing exact keyword in its post-comparison summary. This separate CPU audit completes the omitted checks without changing original evidence.',
        current_process_inventory_performed=False,saved_cleanup_all_four_calls_verified=True,
        prior_audit_attempt=prior_attempt,actual_model_full_rehashes_across_both_audit_attempts=2,
        matching_32_token_solo=comparison,diagnostics=diagnostics,resources=resources,
        scope=dict(throughput_qualified=False,numerical_fix_qualified=False,model_quality_qualified=False,
            physical_two_machine_execution=False,stage_pipeline_exercised=False,private_fused_output_captured=False),
        limitations=['Only normalized input is captured from the real model; full and local-width fused projections are reconstructed.',
            'Exact no-hook first logits qualify this diagnostic harness control only.',
            'The CPU oracle checks logical bytes, semantic row selection and metrics; it does not emulate Metal matmul or prove a kernel cause.',
            'Pressure level2 and existing swap are recorded; zero NEW swap does not mean swap-free operation.',
            'Sampled RSS/reclaimable memory and stored-byte budgets are not hard peak process-memory guarantees.',
            'Process cleanup is bound to saved supervisor receipts; optional current process enumeration was denied by the managed sandbox and not repeated.'],
        evidence_sha256=dict(sorted(EVIDENCE.items())))
    with output.open('x') as stream:json.dump(result,stream,indent=2,sort_keys=True,allow_nan=False);stream.write('\n')
    print(json.dumps(dict(status='passed',receipt=str(output),receipt_sha256=sha(output),native_calls=4,
        source_entries=157,matched_solo_logits_exact=True,real_projection=diagnostics['real9b-gdn']['oracle']['reassembled']),indent=2))


if __name__=='__main__': main()
