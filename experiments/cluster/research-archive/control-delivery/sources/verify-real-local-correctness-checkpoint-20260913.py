"""CPU-only source/evidence checkpoint; no model, archive replay, GPU or SSH run."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path('/Users/developer/DarkbloomDev/d-inference')
RESEARCH=ROOT.parent/'cluster-research'
TESTED=RESEARCH/'runs/qwen9-local-tp-full-20260913'
PEER=RESEARCH/'runs/qwen9-peer24-20260913/run'
BINARY='26fe9543a617d97309c581bfdf80fc929b85fb2c652d9cd560f61191d1794770'
FINAL_AUDITOR='307f09f57e31141c18fac2d4010d0ad607fc6d61887600a746d57e2241f1c260'
HASHES={}


def digest(path):
    path=Path(path)
    if str(path) not in HASHES:
        value=hashlib.sha256()
        with path.open('rb') as source:
            for chunk in iter(lambda:source.read(4*1024*1024),b''):value.update(chunk)
        HASHES[str(path)]=value.hexdigest()
    return HASHES[str(path)]


def read(path):
    def closed(pairs):
        result={}
        for key,value in pairs:
            assert key not in result, 'Duplicate JSON key'
            result[key]=value
        return result
    digest(path)
    return json.loads(Path(path).read_text(),object_pairs_hook=closed,
        parse_constant=lambda value:(_ for _ in ()).throw(ValueError('Nonfinite JSON')))


def command(*args,cwd=ROOT):
    return subprocess.check_output(args,cwd=cwd,text=True,timeout=30).strip()


def check_sources_and_bundle():
    receipt=read(TESTED/'receipt.json');manifest=read(TESTED/'source-manifest.json')
    assert receipt['status']=='completed' and receipt['binary_sha256']==BINARY
    assert len(manifest)==146 and len({x['path'] for x in manifest})==146
    assert digest(TESTED/'source-manifest.json')==receipt['source_manifest_sha256']
    changes=[]
    for item in manifest:
        assert digest(TESTED/'source'/item['path'])==item['sha256']
        if digest(ROOT/item['path'])!=item['sha256']:changes.append(item['path'])
    assert all(Path(p).suffix=='.md' for p in changes), changes
    bundle=read(TESTED/'bundle/bundle.json')
    assert digest(TESTED/'bundle/bundle.json')==receipt['bundle_manifest_sha256']
    assert {e['path']:e['sha256'] for e in bundle['files']}==receipt['bundle_files']
    release=ROOT/'experiments/cluster/inference/.build/arm64-apple-macosx/release'
    for entry in bundle['files']:
        name=entry['path'];saved=TESTED/'bundle'/name
        assert saved.stat().st_size==entry['size_bytes'] and digest(saved)==entry['sha256']
        actual=(ROOT/'experiments/cluster/runtime'/name if name in ('artifacts.py','rank_worker.py') else release/name)
        assert actual.stat().st_size==entry['size_bytes'] and digest(actual)==entry['sha256'], name
    return receipt,manifest,changes


def check_cpu_and_native_records():
    cpu=read(RESEARCH/'real-local-correctness-python-20260913.json')
    assert (cpu['tests'],cpu['source_files'],cpu['exit_code'])==(187,37,0)
    assert cpu['source_hashes_unchanged'] and cpu['changed_sources']==[] and len(cpu['source_hashes'])==37
    assert cpu['native_report_schema']==9 and cpu['worker_protocol_version']==5
    for name,expected in cpu['source_hashes'].items():assert digest(ROOT/name)==expected,name
    log=RESEARCH/'real-local-correctness-python-20260913.log'
    assert digest(log)==cpu['log_sha256'] and re.search(r'Ran 187 tests in [0-9.]+s\s+OK\s*$',log.read_text())
    protocol=read(RESEARCH/'real-local-correctness-protocol-20260913.json')
    assert (protocol['version'],protocol['acceptedFixtures'],protocol['rejectedFixtures'])==(5,4112,97)
    assert protocol['canonicalFixtureSHA256']==read(RESEARCH/'qwen-ffn-output-protocol-20260913.json')['canonicalFixtureSHA256']
    for field in ('cpuOnly','correctnessOnly','strictDuplicateKeys','integerSyntaxOnly',
        'sequenceMutatesOnlyAfterValidation','shortPipeFrameReturnsBeforeWriterCloses','truncatedFrameRejected'):
        assert protocol[field] is True,field
    path=RESEARCH/'real-local-correctness-admission-20260913.jsonl';digest(path)
    records=[json.loads(line) for line in path.read_text().splitlines()]
    classifications=[r.get('kind',r.get('type')) for r in records]
    assert classifications==['local_correctness_admission_check','local_correctness_storage_check',
        'partition_storage_commitment_check','gemma_partition_plan','gemma_partition_plan','gemma_partition_plan_checks']
    admission,storage,commitment,plan8,plan4,gemma=records
    assert admission['cpuOnly'] and admission['retainedPromptAndTeacher'] and admission['rejectedFixtures']==47
    assert (storage['acceptedFixtures'],storage['rejectedFixtures'],storage['selectedTensorReads'])==(5,18,0)
    for field in ('cpuOnly','boundedManifestCheckedBeforePayloadFileOpen','expectedAggregateAndPayloadLimitCheckedBeforeFileOpen','metadataOnlyDescriptors'):
        assert storage[field] is True,field
    assert commitment['cpuOnly'] and commitment['disjointCoverageValidated'] and commitment['equalByteOverlapRejected']
    assert commitment['rejectedFixtures']==8 and commitment['loadedDTypeBound']
    assert plan8['defaultBits']==8 and plan4['defaultBits']==4 and plan4['mixedDenseRouterW8']
    assert all(x['scope']=='metadata_only' for x in (plan8,plan4,gemma))
    assert (gemma['acceptedChecks'],gemma['rejectedFixtures'])==(9174,26)
    for name in ('real-local-correctness-admission-20260913.stderr','real-local-correctness-protocol-20260913.stderr'):
        assert not (RESEARCH/name).read_bytes();digest(RESEARCH/name)
    return cpu,protocol,records,classifications


def check_completed_audits(source_sha):
    local=read(TESTED/'independent-cpu-audit.json')
    assert local['audit_script_sha256']==digest(RESEARCH/'audit-qwen9-local-tp.py')
    peer=read(PEER/'independent-cpu-audit.json')
    completion=read(RESEARCH/'qwen9-peer24-independent-audit-completion-20260913.json')
    assert completion['status']=='completed' and completion['exit_code']==0
    assert digest(RESEARCH/'audit-qwen9-peer24.py')==peer['audit_script_sha256']==completion['script_sha256']==FINAL_AUDITOR
    assert digest(PEER/'independent-cpu-audit.json')==completion['json_sha256']
    assert digest(RESEARCH/'qwen9-peer24-independent-audit-20260913.log')==completion['log_sha256']
    assert digest(RESEARCH/'qwen9-peer24-independent-audit-20260913.md')==completion['note_sha256']
    assert completion['failure_preserved']
    correction=peer['archive_layout_audit_correction']
    assert digest(correction['failed_log'])==correction['failed_log_sha256']
    assert (completion['archive_entries'],completion['regular_files'])==(358,295)
    assert (peer['archive_entries_verified'],peer['archive_regular_files_verified'])==(358,295)
    assert (local['logical_runs'],local['rank_reports'],local['graph_hook_total'])==(4,6,1536)
    assert (peer['logical_runs'],peer['rank_reports'],peer['logit_rows'],peer['logit_values'],peer['graph_hook_total'])==(6,10,40,9932800,2304)
    for audit,comparisons in ((local,2),(peer,4)):
        assert audit['status']=='passed' and audit['source_files']==146
        assert audit['source_manifest_sha256']==source_sha and audit['native_binary_sha256']==BINARY
        conclusion=audit['conclusions']
        assert conclusion['matched_strict_passes']==0 and conclusion['matched_comparisons']==comparisons
        assert conclusion['peer_logit_equality'] and conclusion['prior_solo_regressions_exact']
        assert not conclusion['throughput_qualified'] and not conclusion['model_quality_qualified'] and not conclusion['physical_two_machine_execution']
        assert len(audit['matched_comparisons'])==comparisons
        assert all(len(c['rows'])==4 and not any(r['passed'] for r in c['rows']) for c in audit['matched_comparisons'])
    assert peer['conclusions']['cross_hardware_matching_modes_exact'] and peer['conclusions']['ffn_plan_executed']
    assert len(peer['cross_hardware_comparisons'])==4 and all(c['serialized_file_bytes_exact'] and c['exact'] for c in peer['cross_hardware_comparisons'])
    assert all(r['sampled_pressure_levels']==[1] and r['observed_swap_increase_bytes']==0 and r['observed_processes_exited'] for r in peer['runs'])
    assert peer['portable_package']['files']==164 and peer['portable_package']['execution']['package_unchanged_after']
    assert peer['staging_receipt']['status']=='staged_not_executed' and peer['staging_receipt']['native_runs']==0
    # Bind completed audits rather than repeating their model, tar or logit replay.
    return local,peer,completion


def check_dependencies(origin):
    results=[]
    for name in ('libs/mlx','libs/mlx-swift','libs/mlx-swift-lm'):
        head=command('git','rev-parse','HEAD',cwd=ROOT/name)
        expected=command('git','ls-tree','HEAD',name).split()[2]
        clean=not command('git','status','--porcelain','--untracked-files=all',cwd=ROOT/name)
        assert head==expected and clean,name
        results.append(dict(path=name,head=head,tracked_and_untracked_clean=clean))
    for name,record in origin['dependencies'].items():
        assert not record['status'] and command('git','rev-parse','HEAD',cwd=ROOT/name)==record['head']
        assert not command('git','status','--porcelain','--untracked-files=all',cwd=ROOT/name)
    paths=['experiments/cluster/inference/.generated-dependencies/overlay.json',
        'experiments/cluster/inference/.generated-dependencies/mlx-swift/Package.swift',
        'libs/mlx-swift/Package.swift','experiments/cluster/inference/Package.resolved']
    hashes={name:digest(ROOT/name) for name in paths}
    assert hashes==read(RESEARCH/'cbv2-final-verification-20260913.json')['dependency_manifest_hashes']
    overlay=read(ROOT/paths[0]);assert overlay['source_manifest_sha256']==hashes[paths[2]]
    assert overlay['generated_manifest_sha256']==hashes[paths[1]]
    return results,hashes


def scan_public(tested):
    names=sorted(set(command('git','ls-files','--cached','--others','--exclude-standard',
        'experiments/cluster','docs/design/README.md','docs/design/distributed-inference-goal.md',
        'docs/developer/build.md','docs/developer/test.md').splitlines()))
    extra=set(names)-{item['path'] for item in tested}
    assert all(Path(n).suffix=='.md' or n in {'experiments/cluster/inference/.gitignore','experiments/cluster/transport/.gitignore'} for n in extra),extra
    credentials=(ROOT.parent/'machines/CREDENTIALS.private.md').read_text()
    values=[value for line in credentials.splitlines() if 'password' in line.lower()
            for value in re.findall(r'`([^`]+)`',line) if len(value)>=8]
    assert values
    patterns=[r'/Users/gaj',r'100\.109\.199\.72',r'100\.96\.148\.101',
              r'BEGIN (?:OPENSSH|RSA|EC) PRIVATE KEY',r'id_ed25519_darkbloom_dev']
    exceptions=[]
    for name in names:
        content=(ROOT/name).read_text();assert '\x00' not in content,name
        for number,line in enumerate(content.splitlines(),1):
            assert line.rstrip()==line,(name,number,'trailing whitespace')
            assert not any(re.search(p,line) for p in patterns),(name,number,'private identifier')
            if any(value in line for value in values):
                assert name=='docs/developer/build.md' and line.startswith('FROM '),(name,number,'private value')
                assert line in command('git','show','HEAD:'+name).splitlines()
                exceptions.append(dict(path=name,reason='Unchanged public base-image namespace; not a credential declaration'))
    link_pages=['experiments/cluster/inference/REAL_QWEN_TP_VALIDATION.md',
        'experiments/cluster/inference/README.md','experiments/cluster/README.md',
        'docs/design/distributed-inference-goal.md','docs/design/README.md']
    links=0
    for name in link_pages:
        page=ROOT/name
        for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)',page.read_text()):
            if re.match(r'[a-zA-Z][a-zA-Z0-9+.-]*:',target):continue
            relative=target.split('#')[0].strip('<>')
            assert (page.parent/relative).resolve().exists(),(name,target)
            links+=1
    return names,sorted(extra),exceptions,links


def main():
    output=RESEARCH/'real-local-correctness-final-verification-20260913.json'
    snapshot_path=RESEARCH/'real-local-correctness-final-source-manifest-20260913.json'
    assert not output.exists() and not snapshot_path.exists(),'Preserve an existing final receipt; choose a new checkpoint name'
    origin,tested,changes=check_sources_and_bundle()
    cpu,protocol,admission,kinds=check_cpu_and_native_records()
    local,peer,completion=check_completed_audits(origin['source_manifest_sha256'])
    submodules,dependencies=check_dependencies(origin)
    paths,extra,exceptions,links=scan_public(tested)
    subprocess.run(['git','diff','--check'],cwd=ROOT,check=True,timeout=30)
    docs=RESEARCH/'real-local-correctness-docs-check-final-20260913.log'
    assert docs.read_text().strip()=='docs-check: 280 file(s) OK';digest(docs)
    build=RESEARCH/'real-local-correctness-build-final-20260913.log'
    assert "Build of product 'cluster-inference' complete!" in build.read_text() and '{"jacclAvailable":true}' in build.read_text();digest(build)
    cleanup=read(RESEARCH/'real-local-correctness-process-cleanup-final-20260913.json')
    for place in ('local','peer24'):
        entry=cleanup[place];assert entry['exit_code']==0 and entry['native_probes']==[] and entry['native_probe_count']==0 and not entry['stderr']
    probes=[line for line in command('ps','-axo','pid=,comm=').splitlines() if Path(line.strip().split(maxsplit=1)[-1]).name in
            {'cluster-inference','cluster-transport','cluster-transport-probe'}]
    assert not probes,probes
    for name in ('peer24-thunderbolt-recheck-20260913.json','peer24-thunderbolt-recheck-20260913.md',
        'qwen9-peer24-portable-preparation-20260913.json','qwen9-peer24-independent-audit-before-extraction-check-20260913.json',
        'audit-qwen9-peer24-archive-layout-failed.py','qwen9-peer24-independent-audit-archive-layout-failed-20260913.log'):
        digest(RESEARCH/name)
    snapshot=[dict(path=name,sha256=digest(ROOT/name)) for name in paths]
    snapshot_path.write_text(json.dumps(snapshot,indent=2)+'\n')
    result=dict(status='passed',cpu_only=True,timestamp_utc=datetime.now(timezone.utc).isoformat(),goal_status='active',
        verifier_sha256=digest(Path(__file__)),git_head=command('git','rev-parse','HEAD'),branch=command('git','branch','--show-current'),
        binary_sha256=BINARY,bundle_files=origin['bundle_files'],tested_source_entries=len(tested),
        tested_source_manifest_sha256=origin['source_manifest_sha256'],current_source_manifest_sha256=digest(snapshot_path),
        only_changes_since_native_checkpoint=changes,additional_public_files=extra,
        cpu_tests=cpu['tests'],cpu_source_files=cpu['source_files'],cpu_suite_sources_unchanged=True,
        worker_protocol_check=protocol,admission_jsonl_records=len(admission),admission_record_kinds=kinds,
        local_correctness_admission=admission[0],local_correctness_storage=admission[1],
        local_audit_conclusions=local['conclusions'],peer_audit_conclusions=peer['conclusions'],
        final_peer_audit_script_sha256=peer['audit_script_sha256'],completed_peer_audit_binding=completion,
        peer_archive_entries_verified=peer['archive_entries_verified'],peer_archive_regular_files_verified=peer['archive_regular_files_verified'],
        existing_audit_artifact_replay_repeated=False,submodules=submodules,dependency_manifest_hashes=dependencies,
        toolchain=command('xcodebuild','-version')+'\n'+command('swift','--version'),sdk=command('xcrun','--show-sdk-version'),
        docs_check=docs.read_text().strip(),git_diff_check=True,public_files_scanned=len(paths),public_relative_links_checked=links,
        private_identifier_and_whitespace_scan_passed=True,existing_public_reference_exceptions=exceptions,
        current_local_native_probes=0,final_cleanup_receipt=cleanup,
        documentation_review='No material mismatch in admission, audited numerical results, goal links or remaining work.',
        limitations=['Registered real9B local TP completes but all16 matched M4 Pro rows and all8 M4 Max rows fail the unchanged numerical gate.',
            'Exact cross-hardware files and peer agreement do not qualify model quality or correctness against solo.',
            'Both-wide TP changes the first selected token; later rows share fixed teacher history.',
            'Two separate one-host experiments; no physical two-machine RDMA inference, production scheduler or M3 Ultra throughput qualification.',
            'The48GB peer remains unavailable in the preserved physical check; no new network probe was performed.',
            'Final remote process absence is bound to the saved read-only cleanup receipt, not re-observed by this CPU verifier.'],
        evidence_sha256=dict(sorted(HASHES.items())))
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(status='passed',receipt=str(output),receipt_sha256=digest(output),
        public_files=len(paths),tested_source_entries=len(tested),cpu_tests=cpu['tests'],
        admission_records=len(admission),native_probes_remaining=0),indent=2))


if __name__=='__main__':main()
