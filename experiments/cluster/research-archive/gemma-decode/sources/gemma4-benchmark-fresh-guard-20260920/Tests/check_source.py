"""Bounded source-schema checks; no compiler, fixtures, OS probe or native run."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def raw(path):
    assert not path.is_symlink() and path.is_file() and path.stat().st_size<=200_000
    return path.read_bytes()
def text(name):return raw(ROOT/'Runtime'/name).decode()
def original(name):return raw(ROOT/'originals'/name).decode()
def main():
    inputs=json.loads(raw(ROOT/'source-inputs.json'))
    base=Path(inputs['base']['path'])
    assert hashlib.sha256(raw(base)).hexdigest()==inputs['base']['sha256']
    base_inputs=json.loads(raw(base));base_entries={x['source']:x for x in base_inputs['entries']}
    for entry in inputs['entries']:
        value=raw(ROOT/entry['source'])
        assert len(value)==entry['after']['bytes'] and hashlib.sha256(value).hexdigest()==entry['after']['sha256']
        if entry['before'] is not None:
            value=raw(ROOT/'originals'/Path(entry['source']).name)
            assert entry['before']==base_entries[entry['source']]['after']
            assert len(value)==entry['before']['bytes'] and hashlib.sha256(value).hexdigest()==entry['before']['sha256']
    for entry in inputs['files']+inputs['dependencies']:
        path=Path(entry['path']);path=path if path.is_absolute() else ROOT/path
        value=raw(path)
        assert len(value)==entry['bytes'] and hashlib.sha256(value).hexdigest()==entry['sha256']
    owner=text('Gemma4BenchmarkResourceOwner.swift');old=original('Gemma4BenchmarkResourceOwner.swift')
    start='            let sum = QwenLongPrefillCheckedBytes.sum'
    end='            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProbeError("Gemma deadline expired during observation") }'
    assert owner[owner.index(start):owner.index(end)+len(end)]==old[old.index(start):old.index(end)+len(end)]
    marker='    func construction('
    assert owner[owner.index(marker):]==old[old.index(marker):]
    for name in ['Gemma4BenchmarkEntry.swift','Gemma4BenchmarkRuntime.swift','Gemma4BenchmarkResourceOwner.swift']:
        a=original(name);b=text(name)
        for token in ['try native.check()', '.synchronize()', 'Memory.clearCache()', 'eval(']:
            assert a.count(token)==b.count(token),(name,token)
    runtime=text('Gemma4BenchmarkRuntime.swift')
    assert runtime.count('Gemma4BenchmarkGuardObservation(mode: .combined, deadline: deadline)')==1
    scoped=runtime.split('func checked() throws {',1)[1].split('var releaseWire:',1)[0]
    ordered=['defer { observation.close() }','try scopedOuterCheck(observation)',
             'try owner.check(observation: observation)','try scopedOuterCheck(observation)',
             'try observation.finish(deadline: deadline)']
    cursor=0
    for piece in ordered:cursor=scoped.index(piece,cursor)+len(piece)
    assert not any(word in scoped for word in ['session.', 'group.', 'await ', 'eval(', 'sendCompleted', 'receiveCompleted'])
    holder=text('Gemma4BenchmarkGuardObservation.swift')
    assert holder.count('QwenResidentResourceEnvironment.observe(')==1
    assert 'catch { close(); throw error }' in holder
    assert 'observation = nil' in holder and 'deinit { close() }' in holder
    assert 'reader:' not in holder and '() throws -> QwenDenseStageLoadOSObservation' not in holder
    environment=text('QwenResidentRequestResources.swift')
    old_environment=original('QwenResidentRequestResources.swift')
    begin='        guard let unmanaged = IOPSCopyPowerSourcesInfo()'
    end='    static func allocationBound('
    actual=environment[environment.index(begin):environment.index(end)].replace('return try QwenDenseStageLoadResources.requireInitial','_ = try QwenDenseStageLoadResources.requireInitial')
    assert actual==old_environment[old_environment.index(begin):old_environment.index(end)]
    print(json.dumps(dict(status='source-check-passed',overlays=len(inputs['entries']),
                          budgetAndPhaseBodiesExact=True,nativeFaultEvalSyncCountsExact=True,
                          scopeContainsNoModelOrTransport=True,executedNativeOrFixtures=False)))

if __name__=='__main__':main()
