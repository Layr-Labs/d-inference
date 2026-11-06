"""Read-only small source checks. No fixture, child, model, or remote launch."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent


def digest(raw):return hashlib.sha256(raw).hexdigest()


def main():
    value=json.loads((ROOT/'source-inputs.json').read_bytes())
    for row in value['members']:
        p=ROOT/row['path'];raw=p.read_bytes()
        assert p.is_file() and not p.is_symlink() and len(raw)==row['bytes'] and digest(raw)==row['sha256']
        if p.suffix=='.py':ast.parse(raw,filename=str(p))
    provenance=json.loads((ROOT/'copy-provenance.json').read_bytes())
    patch=[];unchanged=[]
    for row in provenance['members']:
        raw=Path(row['sourcePath']).read_bytes()
        assert digest(raw)==row['beforeSHA256'] and raw==(ROOT/'originals'/row['path']).read_bytes()
        old=raw.decode();new=(ROOT/row['path']).read_text()
        patch.extend(difflib.unified_diff(old.splitlines(True),new.splitlines(True),
            fromfile='a/'+row['path'],tofile='b/'+row['path']))
        if old==new:unchanged.append(row['path'])
    assert ''.join(patch)==(ROOT/'supervisor.patch').read_text()
    must_remain=['package/worker_processes.py','package/worker_contract.py','package/reference_resources.py',
        'package/mtp_journal.py','package/target_processes.py','owned_process.py','parent_settings.py']
    assert all(x in unchanged for x in must_remain)
    gate=(ROOT/'originals/package/native_gate.py').read_text().replace(provenance['oldNamespace'],provenance['newNamespace']).replace("'--execute'","'--qualify-mtp-state'")
    assert gate==(ROOT/'package/native_gate.py').read_text()
    required=json.loads((ROOT/'required-native-sources.json').read_bytes())
    for key in ('actualBuildReceipt','actualSources','metadataSources'):
        assert digest(Path(required[key]['path']).read_bytes())==required[key]['sha256']
    source=json.loads(Path(required['actualSources']['path']).read_bytes())
    rows={x['path']:x for x in source['files']}
    for row in required['requiredFiles']:assert rows[row['path']]==row
    print(json.dumps(dict(passed=True,sourceMembers=len(value['members']),originalHelpers=len(provenance['members']),
        requiredNativeSourceRows=len(required['requiredFiles']),nativeCompiledByAuthor=False,
        fixturesExecuted=False,remoteExecuted=False)))


if __name__=='__main__':main()
