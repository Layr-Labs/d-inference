"""Root-only create-only composition; default check never mutates the workspace."""
import argparse
import json
import os
from pathlib import Path
from composition import BASE,BASE_SHA,ROOT,WORK,pin,prospective,read_pinned,sha

def main():
    p=argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--base-sources',type=Path,default=BASE)
    p.add_argument('--with-target-width',action='store_true')
    p.add_argument('--with-small-qmv',action='store_true')
    p.add_argument('--output',type=Path)
    p.add_argument('--apply',action='store_true')
    a=p.parse_args()
    assert a.output is not None or not a.apply
    options=[n for n,v in [('targetWidth',a.with_target_width),('smallQMV',a.with_small_qmv)] if v]
    prepared,initial,chain,controls,files=prospective(a.base_sources,options)
    record=dict(schema='gemma4_remote_mtp_composition_v1',base=pin(a.base_sources),baseSHA256=BASE_SHA,
        compositionSourceManifestSHA256=sha((ROOT/'build-v2-source-inputs.json').read_bytes()),workspace=str(WORK),
        options=options,chain=chain,controls=controls,files=files,workspaceMutated=False,compilerExecuted=False)
    if a.output is not None:
        out=a.output;assert out.is_absolute() and out.parent.resolve()==out.parent and not out.exists()
        out.mkdir(mode=0o700)
        for path,raw in prepared.items():
            dest=out/'sources'/path;dest.parent.mkdir(parents=True,exist_ok=True)
            with dest.open('xb') as f:f.write(raw)
            old=initial[path]
            if old is not None:
                saved=out/'before'/path;saved.parent.mkdir(parents=True,exist_ok=True)
                with saved.open('xb') as f:f.write(read_pinned(dict(old,path=str(WORK/path))))
        # Recheck every original and frozen input immediately before any writes.
        again=prospective(a.base_sources,options)
        assert again[0]==prepared and again[-1]==files
        if a.apply:
            for path,raw in prepared.items():
                dest=WORK/path
                if initial[path] is None:
                    with dest.open('xb') as f:f.write(raw)
                elif raw!=dest.read_bytes():
                    with dest.open('wb') as f:f.write(raw)
            for row in files:read_pinned(dict(row,path=str(WORK/row['path'])))
            record['workspaceMutated']=True
        with (out/'sources.json').open('x') as f:json.dump(record,f,indent=2);f.write('\n')
    print(json.dumps(dict(status='composed' if a.apply else 'checked',files=len(files),overlays=len(prepared),
        options=options,workspaceMutated=a.apply,output=str(a.output) if a.output else None)))
if __name__=='__main__':main()
