"""CPU source-contract checks only; Swift behavioral fixtures are not executed."""
from pathlib import Path
import hashlib,re,unittest

ROOT=Path(__file__).resolve().parent
DEPS={
 '../owner-operator-phase-draft/manifest.json':'0062f80ef584aedd4acb7d6967cd1f0b874959b30632352983e820e804da17b6',
 '../owner-operator-phase-draft/CBv2OwnerPhaseObservation.swift':'074cd6d297e3b019022c6a9d921ebb1f32b64fd4d23c0a84a9b0a36e3f7ad172',
}
PHASES=['graphConstructionBegin','graphConstructionEnd','rootStagingBegin','rootStagingEnd',
 'evaluationBegin','evaluationEnd','validationCommitBegin','validationCommitEnd']


def require(ok,message):
    if not ok:raise ValueError(message)


def verify_pins():
    result={}
    for path,expected in DEPS.items():
        raw=(ROOT/path).read_bytes();actual=hashlib.sha256(raw).hexdigest()
        require(actual==expected,'Frozen owner dependency changed')
        result[path]=dict(sha256=actual,byteCount=len(raw))
    return result


def check(types=None,recorder=None,fixture=None):
    verify_pins()
    types=types if types is not None else (ROOT/'QwenPrefillOwnerTypes.swift').read_text()
    recorder=recorder if recorder is not None else (ROOT/'QwenPrefillOwnerRecorder.swift').read_text()
    fixture=fixture if fixture is not None else (ROOT/'QwenPrefillOwnerRecorderCheck.swift').read_text()
    imports=re.findall(r'^import (\w+)',types+'\n'+recorder+'\n'+fixture,re.M)
    require(set(imports)<= {'Foundation','Dispatch'},'Native or model dependency added')
    require('case solo, rank0, rank1' in types and 'profile == "long_prefill_8k_v1"' in types,'Role/profile admission changed')
    require('requestFingerprint.utf8.count == 64' in types and '(48...57).contains($0) || (97...102).contains($0)' in types,
        'Lowercase hexadecimal fingerprint check changed')
    for field,value in [('frameSequence',7),('tokenOffset',3584),('tokenCount',512),('committedFrontier',4096)]:
        require(f'let {field} = {value}' in types,'Fixed selection changed')
    for item in ['let kind = "qwen_prefill_selected_owner_trace", schemaVersion = 1','let maximumEvents = 8',
        'let diagnosticOnly = true','let includesRecorderOverhead = true','let evaluationIntervalIncludesExistingErrorCheck = true',
        'let crossProcessClockAlignmentAsserted = false','let gpuKernelTimeAsserted = false','let gpuOverlapAsserted = false',
        'let modelReleaseAsserted = false','let recorderIndependentlyVerifiesOuterSuccess = false']:
        require(item in types,'Trace scope flag/schema changed')
    phase_block=recorder.split('private static let phases: [CBv2OwnerPhase] = [',1)[1].split(']',1)[0]
    require(re.findall(r'\.(\w+)',phase_block)==PHASES,'Phase ordering differs from frozen seam')
    observe=recorder.split('func observe(',1)[1].split('func sealAfterOuterSuccess()',1)[0]
    checks=['(state == .fresh || state == .active), !readingClock','events.count < Self.phases.count',
        'observation.phase == Self.phases[events.count]','observation.tokenCount == identity.tokenCount',
        'observation.committedTokens == (events.count == 7','? identity.committedFrontier : identity.tokenOffset)']
    for item in checks:require(item in observe and observe.index(item)<observe.index('let now = try clock()'),'Metadata is not checked before clock')
    require('guard state == .active, readingClock,' in observe and 'now >= events.last!.localUptimeNanoseconds' in observe,
        'Reentry or nondecreasing timestamp check changed')
    require('} catch {\n            failLocked()\n            throw error\n        }' in observe,'Clock error no longer poisons')
    require(recorder.count('let now = try clock()')==1 and recorder.count('DispatchTime.now()')==1,'Extra clock evaluation added')
    require('clockSource: .dispatchUptimeNanoseconds,' in recorder and 'clockSource: .injectedTestClock, clock: clock' in recorder,
        'Clock provenance distinction changed')
    seal=recorder.split('func sealAfterOuterSuccess()',1)[1].split('func fail()',1)[0]
    require('guard state == .active, !readingClock, events.count == 8,' in seal and 'state = .sealed' in seal,
        'One-shot complete seal guard changed')
    require('clock()' not in seal and 'DispatchTime' not in seal,'Seal reads a clock')
    require('last.localUptimeNanoseconds - first.localUptimeNanoseconds' in seal,'Exact UInt64 span changed')
    require('guard state == .sealed, !readingClock, let result else' in recorder,'Premature retrieval allowed')
    failure=recorder.split('private func failLocked()',1)[1].split('private func reject(',1)[0]
    require('state = .failed' in failure and 'events.removeAll(keepingCapacity: false)' in failure and 'result = nil' in failure,
        'Poisoning retains publishable data')
    require('let unused = QwenPrefillOwnerRecorder(identity: try identity()); unused.fail()' in fixture,
        'Fixture invokes production clock')
    require('UInt64.max' in fixture and 'Array(repeating: 0, count: 8)' in fixture and 'for action in 0..<4' in fixture,
        'Extremal clocks/reentrant vectors missing')


class SourceContractTests(unittest.TestCase):
    def test_current_contract(self):check()
    def mutate(self,file,old,new):
        text=(ROOT/file).read_text();require(old in text,'Mutation anchor missing');text=text.replace(old,new,1)
        key='types' if file.endswith('Types.swift') else 'recorder'
        with self.assertRaises(ValueError):check(**{key:text})
    def test_wrong_selection(self):self.mutate('QwenPrefillOwnerTypes.swift','let tokenOffset = 3584','let tokenOffset = 0')
    def test_unknown_profile(self):self.mutate('QwenPrefillOwnerTypes.swift','profile == "long_prefill_8k_v1"','!profile.isEmpty')
    def test_false_gpu_claim(self):self.mutate('QwenPrefillOwnerTypes.swift','let gpuKernelTimeAsserted = false','let gpuKernelTimeAsserted = true')
    def test_native_import(self):self.mutate('QwenPrefillOwnerRecorder.swift','import Foundation','import MLX')
    def test_wrong_capacity(self):self.mutate('QwenPrefillOwnerRecorder.swift','events.count < Self.phases.count','events.count <= Self.phases.count')
    def test_wrong_frontier(self):self.mutate('QwenPrefillOwnerRecorder.swift','events.count == 7','events.count == 6')
    def test_phase_order(self):self.mutate('QwenPrefillOwnerRecorder.swift','.rootStagingBegin, .rootStagingEnd,','.rootStagingEnd, .rootStagingBegin,')
    def test_clock_ties_rejected(self):self.mutate('QwenPrefillOwnerRecorder.swift','now >= events.last!','now > events.last!')
    def test_test_clock_mislabeled(self):self.mutate('QwenPrefillOwnerRecorder.swift','clockSource: .injectedTestClock, clock: clock','clockSource: .dispatchUptimeNanoseconds, clock: clock')
    def test_incomplete_seal(self):self.mutate('QwenPrefillOwnerRecorder.swift','events.count == 8,','events.count > 0,')
    def test_failed_result_retained(self):self.mutate('QwenPrefillOwnerRecorder.swift','        result = nil','        // result retained')
    def test_extra_seal_clock(self):self.mutate('QwenPrefillOwnerRecorder.swift','    func sealAfterOuterSuccess() throws {','    func sealAfterOuterSuccess() throws {\n        _ = DispatchTime.now()')
    def test_retrieval_before_seal(self):self.mutate('QwenPrefillOwnerRecorder.swift','guard state == .sealed, !readingClock, let result else','guard let result else')

if __name__=='__main__':unittest.main(verbosity=2)
