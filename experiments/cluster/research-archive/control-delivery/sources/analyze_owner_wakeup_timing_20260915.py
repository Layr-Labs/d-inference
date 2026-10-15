"""Descriptive internal-clock comparison; never updates provider capacity or external SLA claims."""
from pathlib import Path
from decimal import Decimal
import base64,hashlib,json,re,statistics
R=Path('/Users/developer/DarkbloomDev/cluster-research')
OUT=R/'owner-timing-wakeup-comparison-20260915';OUT.mkdir(exist_ok=False)
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
summary={'schema':'internal_owner_timing_comparison_v1','externalTTFTMeasured':False,'openRouterSLAQualified':False,'representativeBenchmark':False,'mtpEnabled':False,'nativeBinarySHA256':'009a671d4e355131b6f38166536d00eee0fb5798000407808d716bc3ea31a08b','cohorts':{}}
configs=[]
for mode in ['serial','lookahead']:
 B=R/f'owner-timing-{mode}-wakeup-20260915';O=B/'physical-1';config=json.loads((B/'configuration/controller.json').read_text());configs.append(config)
 assert config['chunkSize']==512 and config['outputCount']==128 and config['warmupCount']==1 and config['measuredCount']==3
 assert config['stopTokenIDs']==[] and config['lifetimeSeconds']==300 and config['requestSeconds']==120
 template=json.loads(base64.b64decode(config['readyTemplateBase64'],validate=True))['ready']
 assert template['executionPlanSHA256']=='67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f'
 assert template['profile']=={'id':'registered_qwen35_9b_greedy_generation_v1','vocabularySize':248320,'maximumPromptTokens':8192,'maximumChunkTokens':512,'maximumOutputTokens':128,'maximumContextTokens':8320}
 for rank in range(2):
  ownerPath=B/f'configuration/owner-rank{rank}.json';owner=json.loads(ownerPath.read_text())
  assert owner['stageCut']==4 and owner['clusterID']==config['clusterID'] and owner['maximumLifetimeSeconds']==300
  env=owner['workerEnvironment'];assert env['DARKBLOOM_BENCHMARK_PREFILL_POLICY']==('serial_v1' if mode=='serial' else 'one_chunk_lookahead_v1') and env['JACCL_RANK']==str(rank)
  assert owner['workerExecutable']=='/Users/developer/DarkbloomDev/resident-lookahead128-runtime-20260915/darkbloom-cluster-worker'
  ot=json.loads(base64.b64decode(owner['readyTemplateBase64'],validate=True))['ready'];assert ot['rank']==rank and ot['identity']==template['identity'] and ot['profile']==template['profile'] and ot['executionPlanSHA256']==template['executionPlanSHA256']
  deployment=json.loads((B/f'deployment-{rank}.json').read_text());assert deployment['exitCode']==0
  verified=json.loads(deployment['stdout'])['verified'];record=next(v for v in verified if v['path'].endswith('/'+B.name+'/owner.json'));assert record['sha256']==h(ownerPath)
 run=json.loads((O/'execution.json').read_text());assert run['runCompletedAndAliasRestored']
 result=[json.loads(l) for l in (O/'controller.stdout.jsonl').read_text().splitlines()][-1]
 assert result['completed'] and result['nativeCleanupObserved']==[True,True] and result['ownerDeviceLeaseReleasedObserved']==[True,True]
 assert result['configurationSHA256']==h(B/'configuration/controller.json')
 requests=result['requests'];assert len(requests)==4 and len({v['requestID'] for v in requests})==4
 resources=[]
 for rank in range(2):
  post=json.loads((O/f'postflight-{rank}.json').read_text());assert not post['processes'] and all(v['bytes']==0 for v in post['leaseFiles'])
  values=[json.loads(l) for l in (O/f'resources-{rank}.jsonl').read_text().splitlines()]
  for v in values:
   page=int(re.search(r'page size of (\d+) bytes',v['rawVMStat'])[1]);free=int(re.search(r'Pages free:\s+(\d+)\.',v['rawVMStat'])[1])
   assert page*free==v['actualFreeBytes'] and v['actualFreeBytes']>=6*1024**3 and v['admissible'] and v['acPower'] and Decimal(v['reportedSwapBytes'])==0 and v['pressureLevel']<=2
  resources.append({'rank':rank,'sampleCount':len(values),'minimumActualFreeBytes':min(v['actualFreeBytes'] for v in values),'allAdmissible':True})
 rows=[]
 for request in requests:
  assert request['completed'] and request['sequenceGuardMatched'] and request['tokenIDs']==config['expectedTokenIDs']
  assert request['bytesInUseAfterRelease']==0 and request['retirementObserved']<=request['resourcesReleased']
  interval=request['firstToken']-request['startCalled'];assert interval==request['internalOwnerControlFirstTokenNanoseconds']>0
  assert request['firstTokenCount']==1 and request['finalTokenCount']==128
  continuation=request['finalToken']-request['firstToken'];assert continuation>0
  schedules=[]
  for rank in range(2):
   path=O/f'evidence-rank{rank}'/(request['requestID']+'.json');e=json.loads(path.read_text());a=e['agreement'];x=e['execution']
   assert a['requestID']==request['requestID'] and a['membershipEpoch']==config['membershipEpoch'] and a['rankBuildSHA256']==[summary['nativeBinarySHA256']]*2 and a['mtpEnabled'] is False
   assert x['selectedTokenIDs']==request['tokenIDs'] and x['bothRequestStatesRetired'] and x['completedFrames']==143 and x['committedTokens']==8319 and e['rank']==rank
   assert not e['independentNumericalComparisonPerformed'] and not e['throughputMeasurementValid']
   if mode=='lookahead':
    assert a['prefillSchedulingPolicy']=='oneChunkLookahead'
    wanted={'decodePrefetchCount':0,'maximumPreparedBoundaries':1 if rank==0 else 0,'pendingConsumedAtCompletion':0,'policy':'oneChunkLookahead','preparedAheadFrames':15 if rank==0 else 0,'rank':rank}
    assert x['prefillSchedule']==wanted;schedules.append(wanted)
   else:
    assert 'prefillSchedulingPolicy' not in a and 'prefillSchedule' not in x
    schedules.append({'policy':'serial','basis':'exact pinned worker serial env plus omission of opt-in schedule in actual result'})
  rows.append({'requestID':request['requestID'],'phase':request['phase'],'iteration':request['iteration'],'internalFirstTokenSeconds':interval/1e9,'effectivePromptTokensPerSecond':8192e9/interval,'continuationSeconds':continuation/1e9,'continuationTokensPerSecond':127e9/continuation,'all128IDsMatch':True,'actualScheduling':schedules})
 measured=[v for v in rows if v['phase']=='measured'];assert len(measured)==3
 summary['cohorts'][mode]={'configurationSHA256':h(B/'configuration/controller.json'),'controllerStdoutSHA256':h(O/'controller.stdout.jsonl'),'executionSHA256':h(O/'execution.json'),'warmupExcluded':True,'requests':rows,'medianInternalFirstTokenSeconds':statistics.median(v['internalFirstTokenSeconds'] for v in measured),'medianEffectivePromptTokensPerSecond':statistics.median(v['effectivePromptTokensPerSecond'] for v in measured),'medianContinuationTokensPerSecond':statistics.median(v['continuationTokensPerSecond'] for v in measured),'resources':resources,'bothNativeCleanupAndLeaseACK':True,'postflightJournalsZero':True,'fullNumericalComparisonPerformedForTheseRequests':False}
assert configs[0]['promptTokenIDs']==configs[1]['promptTokenIDs'] and len(configs[0]['promptTokenIDs'])==8192
assert configs[0]['expectedTokenIDs']==configs[1]['expectedTokenIDs'] and configs[0]['stopTokenIDs']==configs[1]['stopTokenIDs']==[]
a=summary['cohorts']['serial']['medianInternalFirstTokenSeconds'];b=summary['cohorts']['lookahead']['medianInternalFirstTokenSeconds']
summary['comparison']={'internalFirstTokenReductionPercent':100*(1-b/a),'internalEffectiveThroughputRatio':a/b,'samePromptGeometryAndWorkerBuild':True,'cohortOrder':'serial then lookahead; not randomized','measurement':'controller start call to first committed-token callback; load and reserve excluded; owner transport/control included','limitations':['One diagnostic repeated-prose prompt, three measured requests per mode.','Recording-enabled worker; sampled resource gates; private control harness.','External HTTP/coordinator routing, queueing and tokenization absent.','Outgoing child-pump wakeup is present in both cohorts; the50ms watchdog interval remains.','No new intermediate-logit/state-frontier or full-reference comparison for these fresh request UUIDs.']}
(OUT/'comparison.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({'comparison':summary['comparison'],'medians':{m:{k:v for k,v in c.items() if k.startswith('median')} for m,c in summary['cohorts'].items()},'sha256':h(OUT/'comparison.json')},indent=2))
