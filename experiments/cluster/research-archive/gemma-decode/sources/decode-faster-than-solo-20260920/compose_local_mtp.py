"""Compose the reviewed local assistant path; keep every changed preimage."""
from pathlib import Path
import hashlib
import json

ROOT=Path(__file__).resolve().parent
WORK=ROOT.parent/'gemma4-execution-20260920/build/workspace'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def record(path):return dict(path=str(path.relative_to(WORK)),bytes=path.stat().st_size,sha256=sha(path))

def main():
    base_path=ROOT/'build/applied-mtp.json';base=json.loads(base_path.read_bytes())
    assert sha(base_path)=='df0b23a1b537b077bf7ce37a01f6381436ed8126f39477013dbe2bf1313e7789'
    for row in base['files']:assert record(WORK/row['path'])==row
    aux_path=ROOT/'mtp-auxiliary-draft/source-inputs.json'
    assert sha(aux_path)=='72d931f22d33bb980a92e51a9e1768bd058aea7f3cbab3d739ae86458bba6809'
    aux=json.loads(aux_path.read_bytes())
    for row in aux['members']:
        p=aux_path.parent/row['path'];assert sha(p)==row['sha256'] and p.stat().st_size==row['bytes']
    for row in aux['dependencies']:
        p=Path(row['path']);assert sha(p)==row['sha256'] and p.stat().st_size==row['bytes']
    adapter_path=ROOT/'local-mtp-cohort-draft/integration.json';adapter=json.loads(adapter_path.read_bytes())
    for row in adapter['context']:
        p=Path(row['path']);assert sha(p)==row['sha256'] and p.stat().st_size==row['bytes']
    changes=[]
    for spec,root in [(aux,aux_path.parent),(adapter,adapter_path.parent)]:
        for row in spec['overlays']:
            changes.append(dict(path=row['destination'],source=str(root/row['source']),before=row['preimageSHA256'],after=row['sha256']))
    for row in adapter['prerequisiteOverlays']:
        changes.append(dict(path=row['destination'],source=row['source'],before=None,after=row['sha256']))
    assert len(changes)==12 and len({x['path'] for x in changes})==12
    saved=ROOT/'build/before-local-mtp';saved.mkdir(mode=0o700)
    for row in changes:
        p=WORK/row['path'];assert sha(Path(row['source']))==row['after']
        if row['before'] is None:assert not p.exists(),str(p)
        else:
            assert sha(p)==row['before'],str(p)
            out=saved/row['path'];out.parent.mkdir(parents=True,exist_ok=True)
            with out.open('xb') as stream:stream.write(p.read_bytes())
    for row in changes:(WORK/row['path']).write_bytes(Path(row['source']).read_bytes())
    names={x['path'] for x in base['files']}|{x['path'] for x in changes}
    output=ROOT/'build/applied-local-mtp.json'
    with output.open('x') as stream:
        json.dump(dict(schema='gemma4_local_mtp_composition_v1',baseSHA256=sha(base_path),
            auxiliarySourcesSHA256=sha(aux_path),adapterIntegrationSHA256=sha(adapter_path),changes=changes,
            files=[record(WORK/name) for name in sorted(names)]),stream,indent=2)
    print(json.dumps(dict(status='composed',sourcesSHA256=sha(output),files=len(names),overlays=len(changes))))

if __name__=='__main__':main()
