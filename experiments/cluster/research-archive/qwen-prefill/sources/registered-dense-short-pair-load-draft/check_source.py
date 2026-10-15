#!/usr/bin/env python3
"""Pure source/byte invariants. No Swift compiler, payload or native process."""
from pathlib import Path
import difflib,hashlib,json,re
D=Path(__file__).resolve().parent
NAMES=['QwenDenseShortPairLoadBudget.swift','QwenDenseShortPairResourcePolicy.swift',
       'QwenDenseShortPairLoadTypes.swift','QwenDenseShortPairLoading.swift','QwenDenseShortPairLoadSupport.swift']
def require(v,m):
    if not v:raise AssertionError(m)
def sha(x):return hashlib.sha256(x).hexdigest()
def validate(files):
    budget=files[NAMES[0]]
    for token in ['requirement.role == .sequentialPair','source.registeredRequirementFingerprint == pair.fingerprint',
        'source.tensors.map(\\.canonical) == profile.canonicalTensors','ledger.scope == .sequentialStagePair',
        'ledger.recordedRequestFingerprint == admission.request.fingerprint','ledger.maximumTokens == 5',
        'stages.map(\\.stageIndex) == [0, 1]','stage.selectedRequirementFingerprint == selected.fingerprint',
        'Set(names).count == names.count','Set(names) == Set(profile.canonicalTensors.map(\\.name))',
        'stages.prefix(progress.completedStages).map(\\.inertAllocationBound)',
        'guard progress.completedStages < 2 else { return completedInert }',
        'sum([completedInert, current]','stageIndex == progress.completedStages',
        'progress.tensorOrdinal == stages[stageIndex].active.count']:
        require(token in budget,'pair budget/progress invariant absent: '+token)
    policy=files[NAMES[1]]
    for token in ['QwenDenseStageLoadPolicy.requireInitial(os, now: now)',
        'max(QwenDenseStageLoadPolicy.minimumActualFreeBytes',
        'sum([r, h, h, q, QwenDenseStageLoadPolicy.loadingHeadroomBytes])',
        'sum([native.activeBytes, native.cacheBytes, r, h, q,',
        'os.actualFreeBytes >= free','native.allocatorLimitBytes >= allocator',
        'reclaimableUsedForAdmission = false']:
        require(token in policy,'pair resource invariant absent: '+token)
    owner=files[NAMES[3]]
    require('private final class QwenDenseShortPairLoadGate' in owner and owner.count('let gate = try QwenDenseShortPairLoadGate(')==1,'private gate construction changed')
    for token in ['observations.count < 8192','completed == 2, next == 0',
        'try budget.requireEntry(entry, stageIndex: stageIndex, progress: progress)',
        'try budget.requireCompletion(stageIndex: stageIndex, progress: progress)',
        'try QwenDenseStageLoadResources.observeOS()','QwenDenseStageLoadResources.observeNative()',
        'try observe(); completed += 1; next = 0; try observe()',
        'return try withExtendedLifetime(values)',
        'withoutActuallyEscaping(check)',
        'try borrowedCheck(); try gate.beforeRead(entry, stageIndex: index); try borrowedCheck()',
        'guard retired0 == nil, retired1 == nil']:
        require(token in owner,'pair gate/ownership invariant absent: '+token)
    require(owner.count('failed = true')>=5,'gate poison missing')
    require(owner.index('let values = try plan.stages.map') < owner.index('let budget = try QwenDenseShortPairLoadBudget.derive') < owner.index('let gate = try QwenDenseShortPairLoadGate') < owner.index('try materializeVerifiedQwenLayerStage('),'both inventories/Q admission do not precede reads')
    require(owner.index('try materializeVerifiedQwenLayerStage(') < owner.index('try gate.completeStage(index)'),'stage completed before materializer')
    producer=files[NAMES[4]]
    require(producer.index('QwenDenseStageLoadResources.requireInitial()')<producer.index('MLX.withError'),'initial OS screen follows native')
    require(producer.count('VerifiedCheckpoint(directory:')==1,'checkpoint verification count changed')
    require(producer.index('guard retiredFiles == nil')<producer.index('return QwenDenseShortPairLoadReport('),'file retirement follows CPU report')
    require('do { try nativeError.check() }' in producer and 'if !cleanup.isEmpty' in producer,'error precedence or cleanup removed')
    types=files[NAMES[2]]
    for token in ['activeStageParametersEvaluated = true','inertParametersMayRemainLazy = true',
        'remainingInertAllowanceRetained = true','forwardExecuted = false, requestStateCreated = false',
        'referenceExecutionVerified = false, baselineComparisonPerformed = false, numericalParityEstablished = false']:
        require(token in types,'report scope changed: '+token)
    core='\n'.join(re.sub(r'//[^\n]*','',files[n]) for n in NAMES)
    for denied in [r'\beval\s*\(',r'\bforward\s*\(',r'\bCBv2RequestSession\s*\(',r'Memory\.(?:memoryLimit|cacheLimit)\s*=',r'\bProcess\s*\(',r'\bprint\s*\(']:
        require(re.search(denied,core) is None,'new pair owner adds excluded work')
    fixture=files['ShortPairLoadCheck.swift']
    for token in ['accepted.count == 24, rejected.count == 82','let hugeStages = try [0, 1].map',
        'completed pair still reserves inert but no host read','stage1 cannot omit stage0 resident allocation',
        'combined individually valid stage budgets overflow']:
        require(token in fixture,'fixture invariant changed: '+token)

def run():
    files={n:(D/n).read_text() for n in NAMES+['ShortPairLoadCheck.swift','ShortPairLoadCheckMain.swift']}
    validate(files)
    mutations=[
        (NAMES[0],'ledger.scope == .sequentialStagePair','ledger.scope == .fullReference'),
        (NAMES[0],'stages.map(\\.stageIndex) == [0, 1]','stages.count == 2'),
        (NAMES[0],'guard progress.completedStages < 2 else { return completedInert }','guard progress.completedStages < 2 else { return 0 }'),
        (NAMES[0],'sum([completedInert, current]','sum([current]'),
        (NAMES[1],'os.actualFreeBytes >= free','os.estimatedReclaimableBytes >= free'),
        (NAMES[1],'sum([native.activeBytes, native.cacheBytes, r, h, q,','sum([r, h, q,'),
        (NAMES[3],'return try withExtendedLifetime(values)','return try autoreleasepool'),
        (NAMES[3],'completed == 2, next == 0','completed <= 2, next == 0'),
        (NAMES[2],'inertParametersMayRemainLazy = true','inertParametersMayRemainLazy = false'),
    ]
    rejects=[]
    for n,a,b in mutations:
        require(a in files[n],'missing mutation target');changed=dict(files);changed[n]=files[n].replace(a,b,1)
        try:validate(changed)
        except (ValueError,AssertionError):rejects.append(n+': '+a)
        else:raise AssertionError('source mutation accepted')
    counts={}
    for name in ['fixture-source-list.json','source-dependencies.json']:
        listing=json.loads((D/name).read_text());records=listing['sources']+([listing['stdin']] if 'stdin'in listing else [])
        for record in records:
            raw=Path(record['path']).read_bytes();require(len(raw)==record['bytes'] and sha(raw)==record['sha256'],'dependency pin changed: '+record['path'])
        counts[name]=len(records)
    deps=json.loads((D/'source-dependencies.json').read_text())
    stage=Path(deps['unchanged_stage_materializer']).read_text()
    code=re.sub(r'//[^\n]*','',stage)
    require('eval(array)' in code and 'model.freeze()' in code and re.search(r'eval\s*\(model\)',code) is None,'shared stage evaluation contract changed')
    patch='';root='experiments/cluster/inference/Sources/ClusterInference/'
    for n in sorted(NAMES):patch+=''.join(difflib.unified_diff([],files[n].splitlines(True),fromfile='/dev/null',tofile='b/'+root+n))
    require(patch==(D/'runtime.patch').read_text(),'additive runtime patch differs')
    return dict(kind='registered_dense_short_pair_source_checks',schema_version=1,passed=True,
        source_mutations_rejected=rejects,dependency_pin_reads=counts,existing_runtime_files_changed=False,
        shared_stage_materializer_unchanged=True,inert_allowance_retained_after_both_stages=True,
        prospective_swift_cases=dict(accepted=24,rejected=82),swift_compiler_native_or_ssh_executed=False,
        candidate_or_model_payload_accessed=False,private_gate_or_partial_load_not_executed=True,
        files={n:sha(s.encode()) for n,s in sorted(files.items())})
if __name__=='__main__':print(json.dumps(run(),indent=2,sort_keys=True))
