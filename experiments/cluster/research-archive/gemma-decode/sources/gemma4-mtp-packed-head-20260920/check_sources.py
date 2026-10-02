from pathlib import Path
import difflib,hashlib,json
ROOT=Path(__file__).resolve().parent

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    for row in json.loads((ROOT/'manifest.json').read_text())['members']:
        p=ROOT/row['path'];assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
    value=json.loads((ROOT/'composition.json').read_text());assert len(value['overlays'])==5
    patch=''
    for row in value['overlays']:
        old=ROOT/row['preimage'];new=ROOT/row['source']
        assert sha(old)==row['beforeSHA256'] and sha(new)==row['sha256']
        patch+=''.join(difflib.unified_diff(old.read_text().splitlines(True),new.read_text().splitlines(True),fromfile='a/'+row['target'],tofile='b/'+row['target']))
    assert patch==(ROOT/'runtime.patch').read_text()
    lineage=json.loads((ROOT/'lineage.json').read_text())
    for row in lineage['pins']:assert sha(Path(row['path']))==row['sha256'],row['path']
    old=(ROOT/'preimages/GemmaSmallDenseQMV.swift').read_text();new=(ROOT/'Runtime/GemmaSmallDenseQMV.swift').read_text()
    a=new.index('    /// Separate registered-head experiment.')
    b=new.index('    static func ordinary(',a)
    assert new[:a]+new[b:]==old,'Existing primitive body/geometry/fixture changed'
    k,n,m,vpt=2816,262144,3,8
    assert k%(vpt*32)==0 and k//(vpt*32)==11 and n%8==0
    assert (k-256)+31*vpt+vpt-1==k-1
    assert (n-1)*(k//8)+(k-1)//8==92_274_687
    assert (n-1)*(k//64)+(k-1)//64==11_534_335
    assert (m-1)*n+n-1==786_431
    assert max(n*k//8,n*k//64,m*n)<2**32
    print(json.dumps(dict(status='source-checked',overlays=5,exactPatchReplays=5,existingDenseKernelUnchanged=True,headIndexBoundsVerified=True,compilerExecuted=False,nativeExecuted=False)))
if __name__=='__main__':main()
