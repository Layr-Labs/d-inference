"""Independent raw resource/cleanup replay plus the frozen Gemma report contract."""
from pathlib import Path
import sys
BASE=Path(__file__).resolve().parent;sys.path[:0]=[str(BASE/'package'),str(BASE/'comparison')]
from binding_common import parse, require, same
from binding_inputs import snapshot
from reference_resources import sample_local, validate_local
from mtp_journal import require_empty
from contract import expected_description
from report import report


def validate(bound,directory,mode):
    collection=parse((directory.parent/(directory.name+'-collection.json')).read_bytes())
    same(collection['mode'],mode,'Collected role')
    declared={r['path']:r for r in collection['files']};actual={p.relative_to(directory).as_posix() for p in directory.rglob('*') if p.is_file()}
    same(actual,set(declared),'Exact returned file inventory')
    for name,row in declared.items():
        value=snapshot(directory/name,max(1,row['bytes']),keep=False,empty=True)
        same(value['sha256'],row['sha256'],'Returned file pin');same(value['size_bytes'],row['bytes'],'Returned size')
    terminal=parse((directory/'terminal.json').read_bytes());same(terminal['status'],'completed','Actual terminal completion')
    same(terminal['mode'],mode,'Terminal mode');same(terminal['nativeExitCodes'],[0],'Native exit')
    for key in ('nativeLeaderReaped','ownedGroupsAbsent','outputComplete','sourceInputsUnchanged','journalEmptyAfterExit','processInventoryClear'):
        same(terminal[key],True,key)
    for key in ('postflightErrors','cleanupErrors'):same(terminal[key],[],key)
    same(terminal['watchdogExpired'],False,'Watchdog');require(0<terminal['elapsedSeconds']<315,'Parent lifetime')
    before=parse((directory/'preflight.json').read_bytes());after=parse((directory/'journal-postflight.json').read_bytes())
    require_empty(before['journal']);require_empty(after,before['journal'])
    require_empty(collection['observation']['journal'],before['journal'])
    require(not collection['observation']['active'] and collection['observation']['journalLockObserved'],'Collection process/lock')
    same(before['physicalMemoryBytes'],(24 if mode=='stage0' else 48)*1024**3,'Host capacity')
    same(parse((directory/'processes-postflight.json').read_bytes())['prohibited'],[],'Process inventory')
    owner=parse((directory/'owner.json').read_bytes());gate=parse((directory/'gate.json').read_bytes())
    same(owner['nativePIDs'],terminal['nativePIDs'],'Owner PID');same(owner['nativePIDs'],[gate['ownerPID']],'Same-PID inherited gate')
    for key in ('path','directoryDevice','directoryInode','fileDevice','fileInode'):same(gate[key],before['journal'][key],'Gate inode')
    for key in ('exclusiveLockHeld','inheritedAcrossExec'):same(gate[key],True,key)
    same(gate['journalMutationPerformed'],False,'Journal unchanged');same(gate['processObservation']['prohibited'],[],'Gate contention observation')
    same(owner['nativeAlarmEndsBeforeFinalStdout'],True,'Native alarm scope');same(owner['absoluteFenceCoversFinalStdout'],True,'Parent scope')
    resource_rows=[]
    for line in (directory/'resources.jsonl').read_bytes().splitlines():
        require(len(line)<=65536 and len(resource_rows)<2000,'Resource log bound');row=parse(line);validate_local(row)
        def read(argv):
            return row['rawVMStat'] if argv[0]=='/usr/bin/vm_stat' else row['rawPower'] if argv[0]=='/usr/bin/pmset' else row['rawMemory']
        replay=sample_local(read)
        for key in ('actualFreeBytes','pressureLevel','reportedSwapBytes','acPower'):same(replay[key],row[key],'Raw resource replay')
        resource_rows.append(row)
    require(resource_rows and resource_rows[0]['phase']=='prelaunch' and resource_rows[-1]['phase']=='postflight','Resource lifecycle coverage')
    binding=parse((bound/'binding.json').read_bytes());inputs=parse((directory/'input-binding.json').read_bytes())
    receipt=parse((bound/'binding-receipt.json').read_bytes());same(inputs['packageSHA256'],receipt['packageSHA256'],'Package binding')
    same(inputs['binding'],binding,'Deployment binding')
    sources=parse((bound/'sources.json').read_bytes())
    expected_raw=Path(sources['expected.json']['path']).read_bytes();prompt_raw=Path(sources['prompt.ids.json']['path']).read_bytes()
    same(snapshot(Path(sources['expected.json']['path']),65536)['sha256'],binding['expectedSHA256'],'Expected pin')
    same(snapshot(Path(sources['prompt.ids.json']['path']),4096)['sha256'],binding['promptSHA256'],'Prompt pin')
    expected=parse(expected_raw);tokens=expected_description(expected,prompt_raw)
    report_path=directory/'native/worker-0.stdout';report_ref=dict(path=str(report_path),sha256=declared['native/worker-0.stdout']['sha256'])
    value=report(dict(report=report_ref,sidecarsDirectory=str(directory/'sidecars')),expected,tokens,('full','stage0','stage1').index(mode))
    for stream in terminal['streams']:
        name='native/worker-0.'+stream['stream'];same(stream['sha256'],declared[name]['sha256'],'Stream retained SHA');same(stream['bytes'],declared[name]['bytes'],'Stream size')
    same(inputs['attempt'],collection['attempt'],'Input/collection attempt')
    return dict(mode=mode,attempt=collection['attempt'],passed=True,report=report_ref,sidecarsDirectory=str(directory/'sidecars'),
        resourceSamples=len(resource_rows),minimumActualFreeBytes=min(r['actualFreeBytes'] for r in resource_rows),
        numericalCrossRankComparisonPerformed=False,protocolOwnerLeaseReleaseObserved=False,
        physicalExclusionAndRetirementObserved=True,modelWholePayloadRehashedByHarness=False)
