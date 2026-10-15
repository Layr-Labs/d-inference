"""Root-scheduled only: guard and preserve the existing private workspace/cache."""
import ctypes,os,sys
from pathlib import Path
from common import BASE,ROOT,inputs,require,save,sha
from source_inventory import inventory

def main():
    out=Path(sys.argv[1]);require(out.resolve()==BASE/'qualification-1/prepare','Exact fresh output required')
    c,w,before,after=inputs();require(inventory(w)==before,'Full qualified source/dependency inventory differs')
    save(out/'inventory-before.json',before)
    binary=w/'provider-swift/.build/debug/darkbloom'
    require(binary.is_file() and not binary.is_symlink() and sha(binary)==c['priorCLI_SHA256'],'Prior qualified CLI differs')
    clone=ctypes.CDLL(None,use_errno=True).clonefile
    clone.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int];clone.restype=ctypes.c_int
    require(clone(os.fsencode(binary),os.fsencode(out/'prior-darkbloom'),0)==0,'APFS clone of original CLI refused; no fallback')
    require(sha(out/'prior-darkbloom')==c['priorCLI_SHA256'],'Preserved CLI differs')
    originals=out/'originals';originals.mkdir(mode=0o700)
    for row in c['files']:
        p=w/row['path'];require(not p.is_symlink() and (sha(p) if p.exists() else None)==row['beforeSHA256'],'Preimage differs: '+row['path'])
        require(sha(row['sourcePath'])==row['sha256'],'Candidate differs')
        if p.exists():
            o=originals/row['path'];o.parent.mkdir(parents=True,exist_ok=True)
            with o.open('xb') as f:f.write(p.read_bytes())
    for row in c['files']:
        p=w/row['path'];raw=Path(row['sourcePath']).read_bytes();p.parent.mkdir(parents=True,exist_ok=True)
        require((sha(p) if p.exists() else None)==row['beforeSHA256'],'Changed before replacement')
        if row['beforeSHA256'] is None:
            with p.open('xb') as f:f.write(raw)
        else:
            temp=p.with_name(p.name+'.protected-http-correction-new')
            with temp.open('xb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
            require(sha(temp)==row['sha256'] and sha(p)==row['beforeSHA256'],'Replacement identity differs')
            os.replace(temp,p)
    actual=inventory(w);save(out/'inventory-after.json',actual);require(actual==after,'Composed inventory differs')
    save(out/'prepared.json',dict(passed=True,manifestSHA256=sha(ROOT/'manifest.json'),candidateSHA256=sha(BASE/'candidate-after.json'),priorCLI_SHA256=c['priorCLI_SHA256'],helperRebuilt=False,compilerExecuted=False))
if __name__=='__main__':os.umask(0o077);main()
