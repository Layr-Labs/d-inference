"""Small source/receipt checks. No preparation, compiler or fixture execution."""
import difflib, hashlib, json, re
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    manifest=json.loads((ROOT/'manifest.json').read_bytes())
    for row in manifest['members']:
        p=ROOT/row['path']; assert p.is_file() and not p.is_symlink()
        assert sha(p)==row['sha256'] and p.stat().st_size==row['bytes']
    c=json.loads((ROOT/'Build/composition.json').read_bytes())
    for row in c['qualifiedPins']+json.loads((ROOT/'context-pins.json').read_bytes()):
        p=Path(row['path']); assert sha(p)==row['sha256'] and p.stat().st_size==row['bytes']
    before=json.loads(Path(c['priorInventoryPath']).read_bytes());after=dict(before);patch=[]
    for row in c['files']:
        p=Path(row['sourcePath']);assert sha(p)==row['sha256']
        original=ROOT/'original'/row['path']; prior=original.read_text() if row['beforeSHA256'] else ''
        assert (before.get(row['path']) or {}).get('sha256')==row['beforeSHA256']
        if row['beforeSHA256']: assert sha(original)==row['beforeSHA256']
        after[row['path']]={'sha256':row['sha256']}
        patch.extend(difflib.unified_diff(prior.splitlines(True),p.read_text().splitlines(True),fromfile='a/'+row['path'] if row['beforeSHA256'] else '/dev/null',tofile='b/'+row['path']))
    assert after==json.loads((ROOT/'Build/candidate-after.json').read_bytes())
    assert len(before)==13876 and len(after)==13877 and len(c['files'])==2
    assert ''.join(patch)==(ROOT/'runtime-and-tests.patch').read_text()
    runtime=(ROOT/'proposed/provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Submission.swift').read_text()
    prior=(ROOT/'original/provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Submission.swift').read_text()
    anchor='        } catch let cancellation as CBv2FirstTokenAdmissionCancellation {'
    assert runtime.split(anchor)[1]==prior.split(anchor)[1]
    assert runtime.count('return try rejectBeforeAdmission(')==4
    tests=(ROOT/'proposed/provider-swift/Tests/ProviderCoreTests/Server/DistributedHTTPPreAdmissionTests.swift').read_text()
    names=[x+'()' for x in re.findall(r'@Test func (\w+)\(',tests)]
    coverage=json.loads((ROOT/'Build/test-coverage.json').read_bytes())
    assert len(names)==7 and set(names)<=set(coverage['completionLabels'])
    assert len(coverage['completionLabels'])==len(set(coverage['completionLabels']))==coverage['testCount']==185
    print(json.dumps(dict(passed=True,manifestSHA256=sha(ROOT/'manifest.json'),overlays=2,runtimeFiles=1,stagedMethods=7,prospectiveTests=185,compiledOrExecutedFixtures=False),sort_keys=True))
if __name__=='__main__':main()
