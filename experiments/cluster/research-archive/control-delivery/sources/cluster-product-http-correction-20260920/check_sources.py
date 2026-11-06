"""Small source-only checks; no workspace enumeration or fixture execution."""
import ast,difflib,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    manifest=json.loads((ROOT/'manifest.json').read_bytes())
    for row in manifest['members']:
        p=ROOT/row['path'];assert p.is_file() and not p.is_symlink()
        assert sha(p)==row['sha256'] and p.stat().st_size==row['bytes'],row['path']
    c=json.loads((ROOT/'Build/composition.json').read_bytes())
    for row in c['failurePins']:assert sha(Path(row['path']))==row['sha256'],row['path']
    before=json.loads(Path(c['priorInventoryPath']).read_bytes())
    after=dict(before);patch=[]
    for row in c['files']:
        p=Path(row['sourcePath']);assert sha(p)==row['sha256']
        original=ROOT/'original'/row['path']
        assert (before.get(row['path']) or {}).get('sha256')==row['beforeSHA256']
        prior=original.read_text() if row['beforeSHA256'] else ''
        if row['beforeSHA256']:assert sha(original)==row['beforeSHA256']
        after[row['path']]={'sha256':row['sha256']}
        patch.extend(difflib.unified_diff(prior.splitlines(True),p.read_text().splitlines(True),fromfile='a/'+row['path'] if row['beforeSHA256'] else '/dev/null',tofile='b/'+row['path']))
    assert after==json.loads((ROOT/'Build/candidate-after.json').read_bytes())
    assert len(before)==13875 and len(after)==13876 and len(c['files'])==5
    assert ''.join(patch)==(ROOT/'runtime-and-tests.patch').read_text()
    coverage=json.loads((ROOT/'Build/test-coverage.json').read_bytes())
    assert len(coverage['completionLabels'])==len(set(coverage['completionLabels']))==coverage['testCount']==178
    assert {'exactRequestUsesEmptyStopsAndNormalQuotaDrain()','unsupportedShapeAndStopsNeverReachOriginalReservation()'}<=set(coverage['completionLabels'])
    for p in (ROOT/'Build').glob('*.py'):ast.parse(p.read_text())
    print(json.dumps(dict(passed=True,manifestSHA256=sha(ROOT/'manifest.json'),overlays=5,runtimeFiles=4,newTestMethods=3,unchangedHTTPMethods=2,prospectiveTests=178,compilerOrFixturesExecuted=False),sort_keys=True))
if __name__=='__main__':main()
