"""Activation requires actual new build/source/host receipts; no guessed binary."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent

def sha(path):
    value=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):value.update(block)
    return value.hexdigest()

def reference(row):
    assert set(row)=={'path','sha256'}
    p=Path(row['path']);assert p.is_absolute() and p.is_file() and not p.is_symlink() and p.stat().st_size<=4*1024**2
    assert sha(p)==row['sha256'],'Actual receipt identity differs'
    return json.loads(p.read_bytes())

def verify(binding=None):
    binding=json.loads((ROOT/'artifact-bindings.json').read_bytes()) if binding is None else binding
    assert set(binding)=={'schema','binaryDirectory','products','resources','buildReceipt','sourceReceipt',
        'dependencyReceipt','sourceSnapshotSHA256','mlxArtifactSHA256','hosts','nativeMetadataReceipt'}
    assert binding['schema']=='lab_record_artifacts_v1'
    context=json.loads((ROOT/'context.json').read_bytes())
    build=reference(binding['buildReceipt']);source=reference(binding['sourceReceipt'])
    dependencies=reference(binding['dependencyReceipt']);metadata=reference(binding['nativeMetadataReceipt'])
    assert source['members']==json.loads((ROOT/'expected-source.json').read_bytes())['members'],'Full composed source differs'
    predecessor=context['predecessor'][1]
    assert sha(predecessor['path'])==predecessor['sha256']
    assert dependencies['members']==json.loads(Path(predecessor['path']).read_bytes())['members'],'9832 exact dependencies differ'
    assert len(binding['products'])==1
    product=binding['products'][0]
    assert set(product)=={'product','sha256','bytes'} and product['product']=='LabAuthenticatedRDMABenchmark'
    assert build['product']==product['product'] and build['exitCode']==0 and build['compilerReaped'] is True and build['gpuExecuted'] is False
    assert build['nativeSHA256']==product['sha256'] and build['nativeBytes']==product['bytes']
    assert build['sourcesSHA256']==binding['sourceReceipt']['sha256']==binding['sourceSnapshotSHA256']
    assert metadata['nativeSHA256']==product['sha256'] and metadata['passed'] is True and metadata['metadataOnly'] is True
    assert metadata['groups']==['local-contract','describe','check-arguments','wrong-identity','wrong-size','wrong-rank']
    directory=Path(binding['binaryDirectory']);assert directory.is_absolute() and directory.resolve()==directory
    binary=directory/product['product'];assert binary.is_file() and not binary.is_symlink() and binary.stat().st_size==product['bytes'] and sha(binary)==product['sha256']
    assert type(binding['resources']) is list and len(binding['resources'])==3
    resources={x['path']:x for x in binding['resources']}
    assert len(resources)==3 and set(resources)=={'matrix.json','bundle/mlx.metallib','bundle/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal'}
    for name,row in resources.items():
        assert set(row)=={'path','source','sha256','bytes'}
        p=Path(row['source']);assert p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
        if name.startswith('bundle/'):
            q=directory/name.removeprefix('bundle/');assert sha(q)==row['sha256']
    assert binding['mlxArtifactSHA256']==resources['bundle/mlx.metallib']['sha256']
    operations=json.loads((ROOT/'operations-inputs.json').read_bytes())
    assert resources['matrix.json']['sha256']==operations['matrix']['sha256'] and resources['matrix.json']['bytes']==operations['matrix']['bytes']
    known=Path(context['knownHosts']['path']);assert sha(known)==context['knownHosts']['sha256']
    keys={x['host']:x['hostKeySHA256'] for x in context['hostKeys']}
    assert [x['host'] for x in binding['hosts']]==['darkbloom-24','darkbloom-48']
    for host in binding['hosts']:
        assert set(host)=={'host','hostKeySHA256','hardware','osBuild','observationReceipt'}
        actual=reference(host['observationReceipt'])
        assert actual['host']==host['host'] and actual['hardware']==host['hardware'] and actual['osBuild']==host['osBuild']
        assert actual['sshExitCode']==0 and actual['strictHostKeyChecking'] is True
        assert actual['hostKeyAlgorithm']=='ssh-ed25519' and actual['hostKeySHA256']==keys[host['host']]
        assert actual['knownHostsSHA256']==context['knownHosts']['sha256'] and host['hostKeySHA256']==keys[host['host']]
    return binding

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--actual',type=Path,required=True);a=p.parse_args()
    value=json.loads(a.actual.read_bytes());verify(value)
    with (ROOT/'artifact-bindings.json').open('x') as stream:json.dump(value,stream,sort_keys=True,indent=2);stream.write('\n')
