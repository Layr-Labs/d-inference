"""Root-only one-file correction over the exact failed 116-source candidate."""
import argparse, hashlib, json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def raw(row):
    p=Path(row['path']);b=p.read_bytes()
    assert p.is_file() and not p.is_symlink() and len(b)==row['bytes'] and hashlib.sha256(b).hexdigest()==row['sha256'],p
    return b
def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',type=Path);p.add_argument('--apply',action='store_true');a=p.parse_args();assert not a.apply or a.output
    own=ROOT/'source-inputs.json'
    for row in json.loads(own.read_bytes())['members']:raw(dict(row,path=str(ROOT/row['path'])))
    spec=json.loads((ROOT/'integration.json').read_bytes());base_raw=raw(spec['baseSources']);base=json.loads(base_raw);failed=json.loads(raw(spec['failedBuild']))
    assert failed['exitCode']==1 and failed['compilerReaped'] is True and failed['groupAbsent'] is True and failed['gpuExecuted'] is False
    assert failed['sourcesSHA256']==spec['baseSources']['sha256'] and len(base['files'])==116
    before=raw(spec['original']);after=raw(spec['source']);expected=before
    for value in range(2,6):
        old=f'values:{value},dtype:.bfloat16'.encode();assert expected.count(old)==1
        expected=expected.replace(old,f'values:MLXArray({value}),dtype:.bfloat16'.encode())
    assert expected==after
    work=Path(spec['workspace'])
    def check():
        for row in base['files']:raw(dict(row,path=str(work/row['path'])))
        assert raw(spec['baseSources'])==base_raw
    check()
    if a.output:
        out=a.output;assert out.is_absolute() and out.parent.resolve()==out.parent;out.mkdir(mode=0o700)
        (out/'before.swift.txt').write_bytes(before);(out/'after.swift.txt').write_bytes(after);check()
        if a.apply:
            assert (work/spec['destination']).read_bytes()==before
            (work/spec['destination']).write_bytes(after)
        rows=[]
        for row in base['files']:
            rows.append(dict(row,bytes=len(after),sha256=hashlib.sha256(after).hexdigest()) if row['path']==spec['destination'] else row)
        result=dict(base,files=rows,workspaceMutated=a.apply,
                    qualifierCompileCorrectionPredecessor=spec['baseSources'],
                    qualifierCompileCorrectionManifestSHA256=hashlib.sha256(own.read_bytes()).hexdigest(),
                    qualifierFailedBuild=spec['failedBuild'])
        if a.apply:
            for row in rows:raw(dict(row,path=str(work/row['path'])))
        with (out/'sources.json').open('x') as f:json.dump(result,f,indent=2);f.write('\n')
    print(json.dumps(dict(status='applied' if a.apply else 'checked',sources=116,changedFiles=1,workspaceMutated=a.apply)))
if __name__=='__main__':main()
