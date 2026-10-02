"""Read-only source identity check; does not import or run the staged codecs."""
import difflib,hashlib,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    for r in json.loads((ROOT/'manifest.json').read_bytes())['members']:
        p=ROOT/r['path'];assert p.is_file() and not p.is_symlink()
        assert sha(p)==r['sha256'] and p.stat().st_size==r['bytes'],r['path']
    parents=json.loads((ROOT/'lineage.json').read_bytes())['parents']
    for r in parents:assert sha(Path(r['path']))==r['sha256']
    originals={r['path']:r for r in json.loads((ROOT/'preimages.json').read_bytes())}
    overlay=json.loads((ROOT/'overlay.json').read_bytes());patch=[]
    assert len(overlay)==22 and len(originals)==14
    for r in overlay:
        p=ROOT/'proposed'/r['path'];assert sha(p)==r['sha256']
        old=ROOT/'original'/r['path'];before=old.read_text() if old.exists() else ''
        if r['path'] in originals:assert sha(old)==originals[r['path']]['sha256']==r['beforeSHA256']
        else:assert not old.exists() and r['beforeSHA256'] is None
        patch.extend(difflib.unified_diff(before.splitlines(True),p.read_text().splitlines(True),fromfile='a/'+r['path'] if before else '/dev/null',tofile='b/'+r['path']))
    assert ''.join(patch)==(ROOT/'runtime-and-tests.patch').read_text()
    vector=json.loads((ROOT/'canonical-vector.json').read_bytes());assert len(bytes.fromhex(vector['payloadHex']))==170
    for name in ['proposed/coordinator/protocol/native_pair_intent_test.go','proposed/provider-swift/Tests/ProviderCoreTests/Coordinator/NativePairMember/NativePairIntentTests.swift']:
        assert vector['payloadHex'] in (ROOT/name).read_text()
    tests=json.loads((ROOT/'staged-tests.json').read_bytes())
    assert sum(t['language']=='Go' for t in tests)==8 and sum(t['language']=='Swift' for t in tests)==5
    for t in tests:assert re.search(r'func '+t['name']+r'\(', (ROOT/'proposed'/t['path']).read_text())
    print(json.dumps(dict(passed=True,manifestSHA256=sha(ROOT/'manifest.json'),overlayFiles=22,stagedGoMethods=8,stagedSwiftMethods=5,compilerOrFixturesExecuted=False,incomingMasterComposed=False),sort_keys=True))
if __name__=='__main__':main()
