"""Replay the exact frozen layers in memory before any workspace write."""
from pathlib import Path
import hashlib
import json

ROOT=Path(__file__).resolve().parent.parent
RESEARCH=ROOT.parent
DECODE=RESEARCH/'decode-faster-than-solo-20260920'
WORK=RESEARCH/'gemma4-execution-20260920/build/workspace'
RUNTIME='libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/'
ENTRY=RUNTIME+'Gemma4BenchmarkEntry.swift'
PHASE=RUNTIME+'Gemma4LocalMTPDriver.swift'
BASE=DECODE/'build/applied-local-mtp.json'
BASE_SHA='6d48fef4e0b855f0954467969e9080312ad8c461cd283eee8653fcdb298c6154'
PHASE_SHA='533f1640a808ea1e8f9b3777a35329e812903f618679cc1072d7badef7e0be4b'
LAYERS=[
 ('gemma4-mtp-remote-pull-draft-20260920','38cee7c080922dadcaf73a6c1e742da35d39b1d2d763a0ff2a5eb2a504f23ee8'),
 ('gemma4-mtp-remote-pull-lifetime-20260920','98f585a1d3a7a73b3d904b41280a839cfceae96ca185288448b7122f0f947032'),
 ('gemma4-mtp-remote-pull-lifetime-v2-20260920','a4a3c1fbb041e3012335737c950ae6de7a7f9c08a7dedb081687ec2ae2f3dde5'),
 ('gemma4-mtp-remote-pull-receive-lifetime-20260920','dd30a773c75ea7cc20b0f498f31b2e8b36b3562c7a8b6b1c03b8d32763efb2a4'),
 ('gemma4-mtp-remote-cohort-draft-20260920','a57201bc72ef53d8073abdf53ed77861113c1b8fe0f9a3026b0ce254979fc25a')]

def sha(raw):return hashlib.sha256(raw).hexdigest()
def pin(path):
    p=Path(path);assert p.is_file() and not p.is_symlink(),str(p)
    b=p.read_bytes();return dict(path=str(p),sha256=sha(b),bytes=len(b))
def read_pinned(row):
    p=Path(row['path']);b=p.read_bytes()
    assert not p.is_symlink() and sha(b)==row['sha256'] and len(b)==row['bytes'],str(p)
    return b
def rows_map(rows):
    value={r['path']:r for r in rows};assert len(value)==len(rows)
    for name in value:assert not Path(name).is_absolute() and '..' not in Path(name).parts
    return value

def base_rows(path):
    assert sha(BASE.read_bytes())==BASE_SHA
    base=json.loads(BASE.read_bytes());expected=rows_map(base['files'])
    path=Path(path);actual=json.loads(path.read_bytes());rows=rows_map(actual['files'])
    if path==BASE:assert rows==expected
    else:
        assert path==DECODE/'build/applied-local-mtp-profile.json','Unknown source ancestor'
        newer=pin(DECODE/'local-mtp-phase-profile/Gemma4LocalMTPDriver.swift')
        assert newer['sha256']==PHASE_SHA and expected[PHASE]['sha256']=='07576a587189e40a87f7df4a1e0a9a1c7501909851a8ca6495d4570a5c066e31'
        expected[PHASE]=dict(path=PHASE,sha256=newer['sha256'],bytes=newer['bytes'])
        assert rows==expected,'Profile successor changed more than the exact timer file'
    return rows

def layers():
    prepared={};initial={};chain=[];controls={}
    def install(path,before,after):
        raw=read_pinned(after)
        if path in prepared:
            assert before is not None and sha(prepared[path])==before['sha256'] and len(prepared[path])==before['bytes'],path
        else:initial[path]=None if before is None else dict(path=path,sha256=before['sha256'],bytes=before['bytes'])
        prepared[path]=raw
        chain.append(dict(path=path,beforeSHA256=before['sha256'] if before else None,source=after['path'],sha256=sha(raw),bytes=len(raw)))
    for directory,expected in LAYERS:
        root=RESEARCH/directory;manifest=root/'manifest.json'
        assert sha(manifest.read_bytes())==expected,str(manifest)
        for row in json.loads(manifest.read_bytes())['members']:
            read_pinned(dict(row,path=str(root/row['path'])))
        spec=json.loads((root/'integration.json').read_bytes())
        for row in spec.get('controls',[]):
            read_pinned(row);controls[row['path']]=row
        if 'overlays' in spec:
            for row in spec['overlays']:
                after=dict(path=str(root/row['source']),sha256=row['sha256'],bytes=row['bytes'])
                install(row['path'],row['before'],after)
        elif 'changes' in spec:
            for row in spec['changes']:install(row['runtimePath'],row['before'],row['after'])
        else:install(spec['runtimePath'],spec['before'],spec['after'])
    return prepared,initial,chain,list(controls.values())

def optional(name,prepared,initial,chain):
    """Only separately frozen, pin-bound entry transforms; no textual merge guess."""
    config=json.loads((ROOT/'optional-inputs.json').read_bytes())[name]
    for row in config['pins']:read_pinned(row)
    spec=json.loads(read_pinned(config['entryOverlay']))
    text=prepared[ENTRY].decode()
    for edit in spec['transforms']:
        before,after=edit['before'],edit['after']
        assert text.count(before)==1 and text.count(after)==0,'Entry transform is not unique'
        changed=text.replace(before,after,1)
        assert changed.count(after)==1 and changed.replace(after,before,1)==text,'Entry inverse differs'
        text=changed
    prepared[ENTRY]=text.encode()
    chain.append(dict(path=ENTRY,source=config['entryOverlay']['path'],sha256=sha(prepared[ENTRY]),bytes=len(prepared[ENTRY])))
    for row in config['overlays']:
        path=row['destination'];assert path not in prepared
        prepared[path]=read_pinned(row['source']);initial[path]=None
        chain.append(dict(path=path,source=row['source']['path'],sha256=sha(prepared[path]),bytes=len(prepared[path])))

def prospective(base,options):
    expected=base_rows(base)
    prepared,initial,chain,controls=layers()
    for option in options:optional(option,prepared,initial,chain)
    for path,old in initial.items():
        assert expected.get(path)==old,'Workspace ancestor differs: '+path
    for path,row in expected.items():
        read_pinned(dict(row,path=str(WORK/path)))
    for path,old in initial.items():
        if old is None:assert not (WORK/path).exists(),'New source already exists: '+path
    final=dict(expected)
    for path,raw in prepared.items():final[path]=dict(path=path,sha256=sha(raw),bytes=len(raw))
    return prepared,initial,chain,controls,[final[p] for p in sorted(final)]
