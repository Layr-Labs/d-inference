"""CPU source checks only. Does not compile or execute the Swift fixtures."""
from pathlib import Path
import difflib
import hashlib
import json
import re

HERE=Path(__file__).resolve().parent


def sha(data):return hashlib.sha256(data).hexdigest()


def ordered(text,*needles):
    indexes=[text.index(needle) for needle in needles]
    assert indexes==sorted(indexes) and len(indexes)==len(set(indexes)),needles


def check_owner(name,original,proposed):
    # Existing native calls, checks and all original DispatchTime reads keep
    # their source order. The additions are CPU observer calls and result binds.
    markers=r'(?:DispatchTime\.now|Stream\.|synchronize\(|\.prefillChunk\(|\.capture\(|\.snapshot\(|\.close\(|\.cancel\(|transport\.|runQwenLongPrefillRankSender\(|runQwenLongPrefillRankReceiver\()'
    keep=lambda s:[line.strip() for line in s.splitlines() if re.search(markers,line)]
    assert keep(original)==keep(proposed),(name,'native or primary-clock source line changed')
    assert original.count('DispatchTime.now().uptimeNanoseconds')==proposed.count('DispatchTime.now().uptimeNanoseconds')
    if name.endswith('Trace.swift'):
        assert 'phaseRecorder: QwenPrefillPhaseRecorder? = nil' in proposed
        assert proposed.count('phaseRecorder?.observe(')==1
        ordered(proposed,'actions.append(', 'try phaseRecorder?.observe(')
    else:
        assert 'phaseRecorder: QwenPrefillPhaseRecorder? = nil' in proposed
        retired=proposed.index('retiredCleanly = true')
        ordered(proposed[retired:],'retiredCleanly = true','try checked()','let result = QwenLongPrefill','try phaseRecorder?.seal()','return result')
        ordered(proposed[proposed.index('    } catch {\n        phaseRecorder?.fail()'):],
            'phaseRecorder?.fail()','let primary = error','throw primary')
        assert 'if let phaseRecorder {' in proposed and 'try phaseRecorder.begin(expectedIdentity:' in proposed
        prefix='local' if name.endswith('RankRequest.swift') else 'admission'
        assert f'requestFingerprint: {prefix}.request.fingerprint' in proposed
        assert f'requestFingerprint: {prefix}.request.request.fingerprint' not in proposed
        assert 'successfulTrace(' not in proposed
    if name.endswith('SoloRequest.swift'):
        assert 'let start = DispatchTime.now().uptimeNanoseconds\n            let fresh = try CBv2RequestSession' in proposed
        assert '            let stop = DispatchTime.now().uptimeNanoseconds\n            guard stop > start' in proposed
        ordered(proposed,'phase: "prefill.begin"','let output = try fresh.prefillChunk','commits.append(commit)','phase: "prefill.committed"')
        ordered(proposed,'phase: "selection.begin"','QwenLongPrefillSoloObservation.select(', 'let stop = DispatchTime',
            'phase: "selection.completed"','phase: "diagnostics.begin"','QwenLongPrefillSoloObservation.capture(',
            'phase: "diagnostics.completed"','phase: "retirement.begin"','try fresh.close()',
            'let closed = DispatchTime','phase: "request.closed"')
        names=re.findall(r'phase: "([A-Za-z0-9_.]+)"',proposed)
        assert len(names)==11 and names.count('prefill.begin')==names.count('prefill.committed')==1
        assert len(names)+15*2==41


def check():
    core={p.name:p.read_text() for p in (HERE/'Tracing').glob('*.swift')}
    assert set(core)=={'QwenPrefillPhaseTypes.swift','QwenPrefillPhaseRecorder.swift'}
    for name,text in core.items():
        assert set(re.findall(r'^import (\w+)',text,re.M))<={'Foundation','Dispatch'}
        assert not re.search(r'\b(?:MLXArray|LoadedModel|FileHandle|FileManager|Process|URLSession)\b',text)
        assert '.synchronize(' not in text and '.asData(' not in text
    rec=core['QwenPrefillPhaseRecorder.swift']
    assert rec.count('DispatchTime.now().uptimeNanoseconds')==1
    assert rec.count('try clock()')==1
    ordered(rec,'func observe(','let now = try clock()','func seal()')
    assert 'state == .active, !readingClock, events.count < maximumEvents' in rec
    assert 'now >= events.last!.localUptimeNanoseconds' in rec
    assert 'guard state == .sealed, !readingClock, let result' in rec
    assert 'case injectedTestClock = "injected_test_clock"' in core['QwenPrefillPhaseTypes.swift']
    pins=json.loads((HERE/'owner-source-pins.json').read_bytes());patch=[];owner_records=[]
    for item in pins:
        old=Path(item['originalPath']).read_bytes();new=Path(item['proposedPath']).read_bytes()
        assert sha(old)==item['originalSHA256'] and sha(new)==item['proposedSHA256']
        check_owner(item['name'],old.decode(),new.decode())
        path='experiments/cluster/inference/Sources/ClusterInference/'+item['name']
        patch.extend(difflib.unified_diff(old.decode().splitlines(True),new.decode().splitlines(True),fromfile='a/'+path,tofile='b/'+path))
        owner_records.append(item)
    assert ''.join(patch)==(HERE/'owner-hooks.patch').read_text()
    negative=0
    for item in pins:
        if item['name'].endswith('Trace.swift'):continue
        old=Path(item['originalPath']).read_text();new=Path(item['proposedPath']).read_text()
        for mutated in [new.replace('phaseRecorder?.seal()','phaseRecorder?.successfulTrace()'),
                        new.replace('phaseRecorder?.fail()','phaseRecorder?.seal()'),
                        new.replace('DispatchTime.now().uptimeNanoseconds','UInt64(0)',1)]:
            try:check_owner(item['name'],old,mutated)
            except (AssertionError,ValueError):negative+=1
            else:raise AssertionError('Source mutation escaped owner check')
    fixture=(HERE/'QwenPrefillPhaseRecorderCheck.swift').read_text()
    assert re.findall(r'^import (\w+)',fixture,re.M)==['Foundation']
    assert 'DispatchTime.now(' not in fixture
    return dict(kind='qwen_prefill_phase_source_checks',schemaVersion=1,status='passed',
        coreSwiftFiles=2,ownerPatches=3,sourceMutationChecksRejected=negative,soloMarkersPerRequest=41,
        rankMarkersPerRequest=[204,235],swiftFixtureExpectedAccepted=6,swiftFixtureExpectedRejected=47,
        swiftFixturesExecuted=False,swiftCompiled=False,nativeExecuted=False,modelPayloadRead=False,
        testsAreSourceChecksNotRuntimeProof=True,owners=owner_records,
        limitations=['No Swift compile/runtime or native hook qualification was performed.',
            'Nil path adds no recorder/event collection or clock reads; stored optional reference and branches preclude an allocation/layout/timing invariance claim.',
            'Request-only seal; outer caller must fail on later model-owner failure and retrieve only after outer success.'])


if __name__=='__main__':print(json.dumps(check(),indent=2,sort_keys=True))
