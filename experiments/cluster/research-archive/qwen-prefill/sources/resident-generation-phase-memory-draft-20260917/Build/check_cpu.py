"""Root-granted Foundation/temporary-file checks only; never launch a model worker."""
import json, os, sys
from build_inputs import BASE, DRAFT, authority, sha
from owned_process import invoke_controller

def main():
    attempt, = sys.argv[1:]
    if not attempt.isdecimal() or not 1 <= int(attempt) <= 99:
        raise ValueError('Expected fresh numeric CPU attempt')
    authority()
    out = BASE / ('cpu-' + attempt); out.mkdir(mode=0o700)
    rt = DRAFT / 'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    tests = DRAFT / 'Tests'; fixed = tests / 'unchanged'
    common = [fixed / ('QwenGenerationPhase' + n + '.swift') for n in ['Observation', 'Recorder', 'Hook']]
    common += [rt / ('QwenGenerationPhase' + n + '.swift') for n in ['Budget', 'HostAllocation']]
    common += [rt / 'QwenResidentMemoryObservation.swift', fixed / 'ClusterRuntimeError.swift']
    common += [tests / n for n in ['FixtureSupport.swift', 'ExactFrame.swift']]
    enc = common + [fixed / 'QwenGenerationPhaseJSON.swift', rt / 'QwenGenerationPhaseEncoding.swift',
        rt / 'QwenResidentMemoryEncoding.swift', fixed / 'ResidentEvidenceSink.swift']
    enc += [tests / n for n in ['ExactSessionIdentity.swift','ExactFinishReason.swift',
        'ExactGenerationResult.swift','ExactPrefillSummary.swift','MemoryFixture.swift','EncodingCheck.swift']]
    commands = []
    for name, sources, groups in [('phases', common+[tests/'PhaseCheck.swift'],11),
        ('memory',common+[tests/'MemoryFixture.swift',tests/'MemoryCheck.swift'],8),('encoding',enc,5)]:
        binary = out/name
        commands += [(name+'-compile',['/usr/bin/xcrun','swiftc','-swift-version','6','-j','2',
            '-parse-as-library','-D','QWEN_GENERATION_PHASE_FIXTURE',*map(str,sources),'-o',str(binary)],90,None),
            (name+'-run',[str(binary)],30,groups)]
    # Host metadata is actual malloc_good_size/MemoryLayout, never supplied by a caller.
    budget_sources = [fixed/'QwenGenerationPhaseObservation.swift',rt/'QwenGenerationPhaseBudget.swift',
        rt/'QwenGenerationPhaseHostAllocation.swift',rt/'QwenResidentMemoryObservation.swift',
        fixed/'ClusterRuntimeError.swift',BASE/'PhaseBudgetMetadata.swift']
    commands += [('budget-compile',['/usr/bin/xcrun','swiftc','-swift-version','6','-j','2','-parse-as-library',
        *map(str,budget_sources),'-o',str(out/'budget')],90,None),('budget-run',[str(out/'budget')],10,None),
        ('memory-schema',['/usr/bin/python3','-B',str(tests/'test_memory_schema.py')],30,None),
        ('experiment-schema',['/usr/bin/python3','-B',str(tests/'test_experiment.py')],30,None)]
    result = dict(steps=[],compilerJobsMaximum=2,modelOrRemoteExecuted=False,passed=False,
        frozenSourceManifestSHA256=sha(DRAFT/'manifest.json'))
    try:
        for name,argv,timeout,groups in commands:
            step=dict(name=name,argv=argv);result['steps'].append(step)
            with (out/(name+'.stdout')).open('xb') as stdout,(out/(name+'.stderr')).open('xb') as stderr:
                invoke_controller(argv,stdout,stderr,step,timeout=timeout)
            if step.get('exitCode')!=0 or not step.get('reaped') or not step.get('groupAbsent'):
                raise RuntimeError('CPU check failed or owned child remains: '+name)
            if groups is not None and json.loads((out/(name+'.stdout')).read_bytes())['count']!=groups:
                raise RuntimeError('Incomplete CPU groups')
            step.update(stdoutSHA256=sha(out/(name+'.stdout')),stderrSHA256=sha(out/(name+'.stderr')))
        budget=json.loads((out/'budget-run.stdout').read_bytes())
        if budget['maximumEvents']!=544 or budget['memoryLogicalBytes']<=0:
            raise RuntimeError('Actual host budget differs')
        authority()
        if sha(DRAFT/'manifest.json')!=result['frozenSourceManifestSHA256']:
            raise RuntimeError('Frozen source changed')
        result.update(passed=True,hostBudgetSHA256=sha(out/'budget-run.stdout'))
    except BaseException as error:
        result['failure']=type(error).__name__+': '+str(error);raise
    finally:(out/'receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(passed=True,foundationGroups=24,pythonMethods=12,hostBudgetSHA256=result['hostBudgetSHA256'])))
if __name__=='__main__':os.umask(0o077);main()
