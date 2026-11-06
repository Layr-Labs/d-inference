"""Reproduce the registered loader's identity using small pinned metadata only."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def verify():
    identity=json.loads((ROOT/'embedding-identity.json').read_bytes())
    values={}
    for row in identity['metadata']+identity['algorithm']:
        path=Path(row['path']);assert path.is_file() and not path.is_symlink() and row['bytes']<=1048576
        raw=path.read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
        if path.name.endswith('.json'):values[path.name]=(raw,json.loads(raw))
    manifest=values['manifest.json'][1];configuration=hashlib.sha256(values['config.json'][0]).hexdigest()
    header=values['model-00001-of-00003.safetensors.header.json'][1]
    lines=['gemma4-target-scaled-embedding-v1',manifest['aggregate_sha256'],configuration,
           'affine:4:64','scale=sqrt(Float(hiddenSize))']
    for suffix,dtype,shape,count in [('biases','BF16',[262144,44],23068672),('scales','BF16',[262144,44],23068672),('weight','U32',[262144,352],369098752)]:
        name='language_model.model.embed_tokens.'+suffix;row=header[name]
        assert row['dtype']==dtype and row['shape']==shape and row['data_offsets'][1]-row['data_offsets'][0]==count
        lines.append(f'{name}:{dict(BF16="bfloat16",U32="uint32")[dtype]}:{shape}:{count}')
    result=hashlib.sha256('\n'.join(lines).encode()).hexdigest()
    assert result==identity['embeddingIdentitySHA256']
    return result
