"""Root-only narrow qualifier composition; default read-only check."""
import argparse,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def raw(row):
    p=Path(row['path']);b=p.read_bytes();assert p.is_file() and not p.is_symlink() and len(b)==row['bytes'] and hashlib.sha256(b).hexdigest()==row['sha256'],str(p);return b

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',type=Path);p.add_argument('--apply',action='store_true');a=p.parse_args()
    assert not a.apply or a.output
    for row in json.loads((ROOT/'source-inputs.json').read_bytes())['members']:raw(dict(row,path=str(ROOT/row['path'])))
    spec=json.loads((ROOT/'integration.json').read_bytes());base=json.loads(raw(spec['baseSources']));work=Path(spec['workspace'])
    files={x['path']:x for x in base['files']};assert len(files)==len(base['files'])==108
    def check():
        for row in base['files']:raw(dict(row,path=str(work/row['path'])))
        for item in spec['changes']:
            raw(item['source']);assert files.get(item['destination'])==item['before']
            if item['before'] is None:assert not (work/item['destination']).exists()
    check()
    if a.output:
        out=a.output;assert out.is_absolute() and out.parent.resolve()==out.parent;out.mkdir(mode=0o700)
        for item in spec['changes']:
            dest=out/'sources'/item['destination'];dest.parent.mkdir(parents=True,exist_ok=True)
            with dest.open('xb') as f:f.write(raw(item['source']))
            if item['before']:
                saved=out/'before'/item['destination'];saved.parent.mkdir(parents=True,exist_ok=True)
                with saved.open('xb') as f:f.write(raw(dict(item['before'],path=str(work/item['destination']))))
        check()
        for item in spec['changes']:
            data=raw(item['source']);dest=work/item['destination']
            if a.apply:
                with dest.open('wb' if item['before'] else 'xb') as f:f.write(data)
            files[item['destination']]=dict(path=item['destination'],bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
        result=dict(base,schema='gemma4_remote_mtp_composition_v1',files=[files[k] for k in sorted(files)],
            workspaceMutated=a.apply,qualifierPredecessor=spec['baseSources'],qualifierSourceManifestSHA256=hashlib.sha256((ROOT/'source-inputs.json').read_bytes()).hexdigest())
        if a.apply:
            for row in result['files']:raw(dict(row,path=str(work/row['path'])))
        with (out/'sources.json').open('x') as f:json.dump(result,f,indent=2);f.write('\n')
    print(json.dumps(dict(status='composed' if a.apply else 'checked',changedFiles=5,finalSourceCount=112,workspaceMutated=a.apply)))
if __name__=='__main__':main()
