"""Explicit grant only: 13 small source writes, no cache clone or compiler."""
import os
from pathlib import Path
from inputs import BASE,ANCESTOR,WORKSPACE
from guards import check_inputs,check_preimage,check_file,load,save,sha,verify_workspace

def main():
    old=check_inputs();verify_workspace(old)
    rows=load('integration.json')['files']
    for row in rows:check_preimage(row)
    output=BASE/'preparation';output.mkdir(mode=0o700)
    receipt={'passed':False,'workspace':str(WORKSPACE),'compilerExecuted':False,'cacheCloned':False,'writes':[],'preservedBinaries':[],
             'originalSourceSHA256':sha(ANCESTOR/'source-before.json'),'projectedSourceSHA256':sha(BASE/'projected-source.json')}
    try:
        # Original inventory and original two replaced sources survive every failure.
        with (output/'source-before.json').open('xb') as f:f.write((ANCESTOR/'source-before.json').read_bytes())
        for row in rows:
            if row['beforeSHA256'] is None:continue
            path=output/'original'/row['path'];path.parent.mkdir(parents=True,exist_ok=True)
            with path.open('xb') as f:f.write((WORKSPACE/row['path']).read_bytes())
            check_file(path,row['beforeSHA256'])
        for index,path in enumerate([ANCESTOR/'coordinator',ANCESTOR/'coordinator-bin',WORKSPACE/'bin/coordinator',WORKSPACE/'coordinator-bin']):
            if not path.exists() and not path.is_symlink():continue
            if path.is_symlink() or not path.is_file() or path.stat().st_size>256*1024*1024:raise ValueError('prior binary shape')
            pin=sha(path);size=path.stat().st_size;backup='prior-binary-'+str(index)
            with path.open('rb') as src,(output/backup).open('xb') as dst:
                while data:=src.read(1024*1024):dst.write(data)
            check_file(path,pin,size);check_file(output/backup,pin,size)
            receipt['preservedBinaries'].append({'path':str(path),'sha256':pin,'bytes':size,'backup':backup})
        for row in rows:
            check_preimage(row);raw=Path(row['sourcePath']).read_bytes();path=WORKSPACE/row['path']
            path.parent.mkdir(parents=True,exist_ok=True)
            temporary=path.with_name(path.name+'.hardware-source-new')
            with temporary.open('xb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
            check_file(temporary,row['sha256'],row['sizeBytes']);check_preimage(row)
            os.replace(temporary,path)
            check_file(path,row['sha256'],row['sizeBytes']);receipt['writes'].append(row['path'])
        check_inputs();verify_workspace(load('projected-source.json'));receipt['passed']=True
    finally:save(output/'receipt.json',receipt)
    print('PASS same-workspace source preparation: 8 driver files (one mode successor) + 1 mode test + 4 unchanged command dependencies; no cache clone or compiler',flush=True)

if __name__=='__main__':main()
