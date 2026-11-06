from pathlib import Path
import datetime
import hashlib
import json
import shutil
import subprocess
import time

root=Path(__file__).resolve().parent
source=root/'resident-physical-cut8-20260915'
target=root/'resident-physical-cut4-20260915'
assert not target.exists()
pin='ef8dbd342776c0f3975ff5e037a5e2262f9ff02aeb367a268a477bf69d8ec5e0'
assert hashlib.sha256((source/'manifest.json').read_bytes()).hexdigest()==pin
manifest=json.loads((source/'manifest.json').read_bytes())
target.mkdir()
for row in manifest['files']:
    relative=Path(row['path']);assert not relative.is_absolute() and '..' not in relative.parts
    src=source/relative;raw=src.read_bytes()
    assert src.is_file() and not src.is_symlink()
    assert len(raw)==row['size_bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
    dst=target/relative;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
shutil.copy2(source/'manifest.json',target/'prior-cut8-manifest.json')
for name,replacements in {
    'selected_source.py': [('SELECTED_CUT = 8','SELECTED_CUT = 4'),('cut in (8,12)','cut in (4,8,12)')],
    'test_selected_cut.py': [
        ('cut=8','cut=4'),('cut8','cut4'),('[[0,8],[8,32]]','[[0,4],[4,32]]'),
        ('[233,694]','[117,810]'),('[1545572992,3492468608]','[1058851136,3979190464]'),
        ('[6,18]','[3,21]'),("c['cut']==8","c['cut']==4"),('(True,8.0,7,16)','(True,4.0,7,16)'),
        ("job['cut'],8","job['cut'],4"),("+1],'8'","+1],'4'"),('(12,True,8.0)','(12,True,4.0)'),
        ('final18_54','final9_63'),('[18,54]','[9,63]'),('[79986696,239960088]','[39993348,279953436]'),
        ('globalLayerIndex=8','globalLayerIndex=4'),('globalLayerIndex=7','globalLayerIndex=3')],
}.items():
    p=target/name;text=p.read_text()
    for old,new in replacements:
        assert old in text,(name,old)
        text=text.replace(old,new)
    p.write_text(text)
(target/'README.md').write_text('''# Resident physical cut4/28 derivative

This diagnostic shifts four more layers from the24GB rank to the48GB rank after
the cut8 attempt crossed the unchanged6GiB actual-free guard during its first
request. It retains the same8192 input,512 chunk,serial policy,one output,
one warmup and three measured requests; it is not a selected performance plan.

The only runtime delta from the pinned cut8 launcher is SELECTED_CUT=4 plus
admission of4 in the existing independently checked metadata recipe. Native
Plan selection already accepts4. All transport, resources, full reference,
numerical comparison, ownership and cleanup bodies remain byte-identical.
Metadata requires117/810 tensors,1058851136/3979190464 logical active bytes,
and9/63 state components totaling the same927 tensors and72 components.
Loaded tensor bytes do not predict peak free memory or establish execution.

The existing31 CPU tests run with the exact cut4 metadata and complete-state
expectations; the historical cut12 recipe regression remains unchanged.
The retained cut8 manifest identifies the source. Source/review/test records
are separate from physical results, which are not yet available at preparation.

Run: python3 -B run_physical.py --config ABSOLUTE_PLAN --output NEW_OUTPUT
The root supplies exact existing d904 native/package identities in the plan.
''')
start=time.monotonic()
p=subprocess.run(['python3','-B','-m','unittest','-v','test_physical','test_retry_stderr',
    'test_selected_read_accounting','test_allocator_policy','test_selected_cut'],cwd=target,capture_output=True,timeout=40)
(target/'cpu-cut4.stdout').write_bytes(p.stdout);(target/'cpu-cut4.stderr').write_bytes(p.stderr)
receipt={'atUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'exitCode':p.returncode,
         'elapsedSeconds':time.monotonic()-start,'priorManifestSHA256':pin,
         'stdoutSHA256':hashlib.sha256(p.stdout).hexdigest(),'stderrSHA256':hashlib.sha256(p.stderr).hexdigest()}
(target/'cpu-cut4.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
if p.returncode: print(p.stderr.decode(errors='replace'));raise SystemExit(p.returncode)
changes=[]
for row in manifest['files']:
    actual=hashlib.sha256((target/row['path']).read_bytes()).hexdigest()
    if actual!=row['sha256']:changes.append(row['path'])
assert changes==['README.md','selected_source.py','test_selected_cut.py'],changes
(target/'cut4-source-delta.json').write_text(json.dumps({'priorManifestSHA256':pin,'changedInheritedMembers':changes,
    'unchangedInheritedMembers':len(manifest['files'])-len(changes),'physicalExecutionQualified':False},indent=2)+'\n')
