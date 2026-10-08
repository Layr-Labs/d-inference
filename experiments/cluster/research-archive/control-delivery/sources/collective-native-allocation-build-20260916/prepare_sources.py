"""Granted-slot source preparation only; all exclusions are explicit ancestry edits."""
import json,os,stat,time
from pathlib import Path
from build_inputs import BASE,WORKSPACE,inputs,checked,relative,sha

def main():
    start=time.monotonic();v,old,source,overlay,exclude=inputs();excluded={r['path'] for r in exclude}
    for row in source:checked(old/'workspace'/relative(row['path']),row)
    WORKSPACE.mkdir(mode=0o700)
    for row in source:
        if row['path'] in excluded:continue
        path=relative(row['path']);src=old/'workspace'/path;dest=WORKSPACE/path;dest.parent.mkdir(parents=True,exist_ok=True)
        if 'symlink' in row:
            checked(src,row);dest.symlink_to(row['symlink'])
        else:
            with dest.open('xb') as stream:stream.write(checked(src,row))
            dest.chmod(stat.S_IMODE(src.stat().st_mode))
    for row in overlay:
        dest=WORKSPACE/relative(row['path']);dest.parent.mkdir(parents=True,exist_ok=True)
        dest.write_bytes(Path(row['source']).read_bytes())
        if sha(dest)!=row['afterSHA256']:raise ValueError('Materialized overlay changed')
    replaced={r['path'] for r in overlay}
    for row in source:
        checked(old/'workspace'/row['path'],row)
        if row['path'] not in replaced and row['path'] not in excluded:checked(WORKSPACE/row['path'],row)
    receipt=dict(baseSources=len(source),overlayFiles=len(overlay),excludedSources=len(exclude),expectedSourceFiles=v['expectedSourceCount'],
        elapsedSeconds=time.monotonic()-start,compilerExecuted=False,cacheCloned=False,mainModified=False,priorWorkspaceModified=False)
    with (BASE/'source-preparation.json').open('x') as f:json.dump(receipt,f,indent=2);f.write('\n')
    print(json.dumps(receipt,sort_keys=True))
if __name__=='__main__':os.umask(0o077);main()
