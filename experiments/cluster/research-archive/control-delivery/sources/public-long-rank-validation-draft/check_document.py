"""Read-only document/evidence binding. Does not rerun a numerical/native oracle."""
from pathlib import Path
import hashlib
import json
import re

ROOT=Path(__file__).resolve().parent.parent
HERE=Path(__file__).resolve().parent
DOC=HERE/'QWEN_LONG_PREFILL_RANK_VALIDATION.md'
REPO=ROOT.parent/'d-inference'
PINS={
 'serial':{
  'receipt.json':'4e5b015b619a35e7e261f0bd45c6954406f42eaabd8f9a11da592a44e3e470d9',
  'independent-cpu-audit-receipt.json':'791c0a35ca5231efbc8263b3c267177c75627f30cb6e63bdf57ab9015cd64503',
  'independent-cpu-audit.json':'ec76a99817f56c2d0d91dccfdf6c494918a808d5ae0cfafe7e072bcd1bd22e90',
  'provenance-audit.json':'a8ab1796cdf8be2bbe8e9f3f217ee0fcad6ecf1cb0c322c39f596e8888dfea95',
  'postflight':'7c8d0b79bda572d2bd94d10d9eb793eb43e82611fa690ca17795c6a315273d9c'},
 'lookahead':{
  'receipt.json':'17de7244b91234a0752c1b673fe61fc8f6584b4cd201933925bc2af6b5772711',
  'independent-cpu-audit-receipt.json':'3f7eebc6cef8f7c7691de9a0d1498a8370735ab1c84feb659837d03469c0092c',
  'independent-cpu-audit.json':'75f8a390144deac3f15584a055c5202be0e8a489cc85a5f689ecb38d16ce9699',
  'provenance-audit.json':'0af364fd2df497403baa43a479aeb4e9f2cd70e2f961ec30d6f1f8a787173efd',
  'postflight':'e42ad9c7b5e2ee9f0c050d91a04fd748d763ea90b4c61ac0902c85062457e31d'}}


def sha(data):return hashlib.sha256(data).hexdigest()


def check():
    raw=DOC.read_bytes();text=raw.decode();files=[];pool=set();cohorts=[]
    assert text.splitlines()[2]=='> Last updated: 2026-09-14 · commit `e4df336bc`'
    assert not re.search(r'/Users/|100\.\d+\.\d+\.\d+|developer@|ssh |password|cluster-runs/',text)
    for policy,pins in PINS.items():
        run=ROOT/f'runs/qwen-long-prefill-ranks-{policy}-peer24-20260914';items={}
        for name,pin in pins.items():
            path=ROOT/f'qwen-long-prefill-ranks-{policy}-peer24-postflight-20260914.json' if name=='postflight' else run/name
            data=path.read_bytes();assert sha(data)==pin;items[name]=json.loads(data)
            files.append(dict(path=str(path),sha256=pin,byteCount=len(data)));pool.add(pin)
            pool.update(re.findall(r'[a-f0-9]{64}',data.decode()))
        a=items['independent-cpu-audit.json'];p=items['provenance-audit.json'];l=items['receipt.json'];post=items['postflight']
        assert a['status']==p['status']=='passed' and l['passed'] and post['passed']
        assert l['cohort']['exit_codes']==[0,0] and a['actionCounts']==[204,235] and a['nativeCommitAssertions']==32
        assert a['selectedTokenID']==271 and a['completeFinalStateComponents']==72 and a['releasedOriginalBoundaryHandles']==[16,16]
        assert not a['candidateNativeBytesIndependentlyReconstructed'] and not a['throughputQualified']
        assert not post['remoteReapingIndependentlyProven'] and post['observation']['ownedLiveProcesses']==[]
        assert all(post['localSSHClientsReaped'])
        timing=a['timing'];assert f"{timing['elapsedNanoseconds']:,}" in text
        assert f"{timing['elapsedNanoseconds']/1e9:.9f}" in text
        assert f"{timing['promptTokensPerFirstTokenSecond']:.6f}" in text
        assert f"{timing['postStopThroughRequestCloseNanoseconds']:,}" in text
        for rank,row in enumerate(a['stdouts']):
            path=run/f'rank-{rank}/stdout.jsonl';data=path.read_bytes()
            assert sha(data)==row['sha256'] and len(data)==row['byteCount']
            records=[json.loads(line) for line in data.splitlines()];assert len(records)==2
            x=records[1]['execution'];assert x['releasedOriginalBoundaryHandles']==16
            assert len(x['frames'])==16 and len(x['actions'])==[204,235][rank]
            assert x['selectedTokenID']==271 and x['allRequestStateRetired']
            files.append(dict(path=str(path),sha256=sha(data),byteCount=len(data)))
        for row in p['resources']['perRank']:
            v=row['validation'];assert v['pressureLevels']==[1] and v['maximumReportedSwapIncreaseBytes']=='0'
            for key in ['initialActualFreeBytes','posthashActualFreeBytes','posthashReclaimableBytes','maximumSampledNativeRSSBytes']:
                assert f'{v[key]:,}' in text
        assert f"{p['resources']['maximumSimultaneouslyObservedNativeRSSBytes']:,}" in text
        for memory in a['memoryByRank']:
            assert f"{memory[-1]['peakMLXBytesSinceProcessStart']:,}" in text
            assert f"{memory[-1]['activeMLXBytes']:,}" in text and memory[-1]['cachedMLXBytes']==0
        cohorts.append(dict(policy=policy,nativeExitCodes=[0,0],timing=timing,resourceSamples=p['resources']['samples'],
            sampledNativeRSSIsNotPeak=True,nativeStateAndReleaseAssertionsRemainSourceBound=True))
    test=ROOT/'long-prefill-rank-audit-draft/test-receipt-20260914.json';test_raw=test.read_bytes();pool.add(sha(test_raw))
    assert json.loads(test_raw)['testsPassed']==82
    files.append(dict(path=str(test),sha256=sha(test_raw),byteCount=len(test_raw)))
    used=set(re.findall(r'(?<![a-f0-9])[a-f0-9]{64}(?![a-f0-9])',text));assert used<=pool,used-pool
    links=re.findall(r'\]\(([^)]+)\)',text)
    for link in links:assert (REPO/'experiments/cluster/inference'/link).is_file(),link
    assert DOC.read_bytes()==raw
    return dict(kind='public_long_rank_validation_document_check',schemaVersion=1,status='passed',documentSHA256=sha(raw),
        documentByteCount=len(raw),allPublishedSHA256ValuesBoundToEvidence=True,relativeLinksChecked=links,
        privateHostPathPatternsAbsent=True,cohorts=cohorts,inputs=files,numericalOracleRerun=False,nativeExecuted=False,
        modelPayloadRead=False,soloCandidateAccessed=False,
        limitations=['Binds prose/numbers/hash references to existing qualified receipts; does not repeat runtime qualification.',
            'Archived native records are read for record counts and claimed ownership only; provenance and numerical audits remain separately identified.'])


if __name__=='__main__':print(json.dumps(check(),indent=2,sort_keys=True))
