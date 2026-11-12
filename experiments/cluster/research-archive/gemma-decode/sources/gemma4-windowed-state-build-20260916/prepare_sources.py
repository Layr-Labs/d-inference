"""Run only after root lifts the physical/bulk hold; never builds."""
import json,os,stat,time
from build_inputs import BASE,WORKSPACE,inputs,checked,relative,sha

def main():
    start=time.monotonic();v,old,draft,source,overlay=inputs()
    for row in source:checked(old/'workspace'/relative(row['path']),row)
    for row in overlay:
        path=relative(row['path']);current=old/'workspace'/path
        if sha(draft/'proposed'/path)!=row['afterSHA256']:raise ValueError('Overlay changed')
        if row['beforeSHA256'] is None:
            if current.exists():raise ValueError('New overlay destination already exists')
        elif sha(current)!=row['beforeSHA256']:raise ValueError('Overlay preimage changed')
    WORKSPACE.mkdir(mode=0o700)  # Never reuse prior/partial output.
    for row in source:
        path=relative(row['path']);src=old/'workspace'/path;dest=WORKSPACE/path
        dest.parent.mkdir(parents=True,exist_ok=True)
        with dest.open('xb') as stream:stream.write(checked(src,row))
        dest.chmod(stat.S_IMODE(src.stat().st_mode))
    for row in overlay:
        path=relative(row['path']);dest=WORKSPACE/path;dest.parent.mkdir(parents=True,exist_ok=True)
        dest.write_bytes((draft/'proposed'/path).read_bytes())
        if sha(dest)!=row['afterSHA256']:raise ValueError('Materialized overlay changed')
    replaced={row['path'] for row in overlay}
    for row in source:
        checked(old/'workspace'/row['path'],row)
        if row['path'] not in replaced:checked(WORKSPACE/row['path'],row)
    receipt=dict(baseSourcesCopied=len(source),overlayFiles=len(overlay),expectedSourceFiles=v['expectedSourceCount'],
        elapsedSeconds=time.monotonic()-start,compilerExecuted=False,cacheCloned=False,mainModified=False)
    with (BASE/'source-preparation.json').open('x') as f:json.dump(receipt,f,indent=2);f.write('\n')
    print(json.dumps(receipt,sort_keys=True))
if __name__=='__main__':os.umask(0o077);main()
