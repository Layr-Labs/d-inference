"""Small actual-receipt join; binary bytes are verified by the existing deployer."""
import hashlib
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'package'))
from binding_common import parse, pin, require, same

def read(path, wanted=None):
    path=Path(path)
    require(path.is_absolute() and path.resolve()==path and not path.is_symlink()
            and path.is_file() and 0<path.stat().st_size<=2_000_000,'Bounded canonical receipt')
    raw=path.read_bytes();sha=hashlib.sha256(raw).hexdigest()
    if wanted is not None:require(sha==pin(wanted),'Receipt SHA256 changed')
    return parse(raw),dict(path=str(path),bytes=len(raw),sha256=sha)

def source_package(packages,name,reference):
    require(type(packages) is list and len(packages)<=100,'Bounded source package list')
    require(all(type(row) is dict and type(row.get('name')) is str for row in packages),'Source package records')
    names=[row['name'] for row in packages]
    require(len(names)==len(set(names)),'Duplicate source package name')
    matched=[row for row in packages if row['name']==name]
    require(len(matched)==1,'Required expert package identity')
    row=matched[0]
    require(set(row) in ({'name','integrationSHA256'},{'name','integrationSHA256','manifestSHA256'}),
            'Unexpected source package metadata')
    require(row['integrationSHA256']==reference['sha256'],'Expert integration identity')
    if 'manifestSHA256' in row:
        require(row['manifestSHA256']==reference.get('manifestSHA256'),'Expected expert manifest identity')
        manifest,_=read(Path(reference['path']).parent/'manifest.json',row['manifestSHA256'])
        require(type(manifest.get('files')) is list,'Expert source manifest members')
        member=[item for item in manifest['files'] if item.get('path')==Path(reference['path']).name]
        require(len(member)==1 and member[0]['sha256']==reference['sha256']
                and member[0]['bytes']==Path(reference['path']).stat().st_size,'Manifest must bind exact integration')

def compose(axis,rdma,sources):
    inputs,_=read(ROOT/'binding-inputs.json')
    require(inputs['schema']=='gemma4_expert_future_build_inputs_v1','Binding input schema')
    overlays=[]
    for key,name in [('projectionSource','gemma4-expert-projection-policy-20260920'),
                     ('prefillSource','gemma4-expert-prefill-bound-20260920'),
                     ('descriptionSource','gemma4-expert-prefill-description-20260920')]:
        contract,_=read(inputs[key]['path'],inputs[key]['sha256'])
        overlays.append((key,name,contract))
    lineage,_=read(inputs['resourceLineage']['path'],inputs['resourceLineage']['sha256'])
    same(inputs['resources'],lineage['resources'],'Unchanged resource lineage')
    source,source_pin=read(sources['path'],sources['sha256'])
    rows=source['files'];require(type(rows) is list and len(rows)<=100,'Bounded applied source list')
    by_path={row['path']:row for row in rows}
    require(len(by_path)==len(rows),'Repeated applied source path')
    # Later bounded successors replace only their named predecessor paths.
    # Retain every untouched projection file, including native projection math.
    expected={}
    for _,_,contract in overlays:
        for overlay in contract['entries']:
            expected[overlay['destination']]=dict(path=overlay['destination'],**overlay['after'])
    for path,row in expected.items():
        same(by_path.get(path),row,'Actual composed expert source binding')
    packages=source['sourcePackages']
    for key,name,_ in overlays:
        source_package(packages,name,inputs[key])
    products=[]
    for name,reference in zip(inputs['products'],[axis,rdma]):
        receipt,receipt_pin=read(reference['path'],reference['sha256'])
        require(receipt['product']==name and type(receipt['exitCode']) is int and receipt['exitCode']==0
                and receipt['compilerReaped'] is True and receipt['gpuExecuted'] is False,'Actual build did not pass')
        require(receipt['sourcesSHA256']==source_pin['sha256'],'Products must share the exact source receipt')
        require(type(receipt['nativeBytes']) is int and 0<receipt['nativeBytes']<200_000_000,'Native byte bound')
        native=pin(receipt['nativeSHA256'])
        require(receipt['target'].startswith(inputs['binaryDirectory']+'/'+name+':\n')
                and 'minos 26.2\n' in receipt['target'],'Actual native target')
        products.append(dict(product=name,sha256=native,bytes=receipt['nativeBytes'],receipt=receipt_pin))
    return dict(schema='gemma4_expert_observed_build_bindings_v1',
                binaryDirectory=inputs['binaryDirectory'],products=products,appliedSources=source_pin,
                resources=inputs['resources'],resourceLineage=inputs['resourceLineage'],
                projectionSource=inputs['projectionSource'],prefillSource=inputs['prefillSource'],
                descriptionSource=inputs['descriptionSource'])

def verify():
    bindings,_=read(ROOT/'artifact-bindings.json')
    require(len(bindings['products'])==2,'Exactly two native products')
    expected=compose(*(x['receipt'] for x in bindings['products']),bindings['appliedSources'])
    same(bindings,expected,'Actual coherent build binding')
    return bindings
