"""Root-only exact registered tokenizer packet; no MLX, model loading or download."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import stat
import sys
BASE=Path(__file__).resolve().parent;sys.path.insert(0,str(BASE/'package'))
from binding_common import parse, require, same, sha
from binding_inputs import snapshot
from gemma_inputs import write_json, write_new

TEXT=('Explain how a careful gardener decides when to water a young tree. Describe the observations, '
      'the difference between dry surface soil and dry roots, and one simple way to check moisture. '
      'Use clear ordinary language and connect each action to its purpose. ')
MANIFEST='c1fefb1fa593fa3ca83e72a1124fb3afca10a59eed272c7ac2ac4a57f8018dfd'
ARTIFACT='2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785'


def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--model-directory',required=True,type=Path)
    p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    require(a.model_directory.resolve()==a.model_directory and a.output.is_absolute()
            and a.output.parent.resolve()==a.output.parent,'Canonical input/output parents')
    manifest=snapshot(a.model_directory/'manifest.json',2*1024**2);same(manifest['sha256'],MANIFEST,'Registered manifest')
    value=parse(manifest['raw']);same(value['aggregate_sha256'],ARTIFACT,'Registered artifact')
    rows=[r for r in value['files'] if r['path']=='tokenizer.json'];require(len(rows)==1,'Registered tokenizer declaration')
    row=rows[0];require(0<row['size_bytes']<=64*1024**2,'Tokenizer metadata size bound')
    path=a.model_directory/'tokenizer.json';named=path.lstat();require(stat.S_ISREG(named.st_mode) and named.st_nlink==1,'Tokenizer regular single-link input')
    tokenizer=snapshot(path,64*1024**2);same(tokenizer['sha256'],row['sha256'],'Actual tokenizer hash');same(tokenizer['size_bytes'],row['size_bytes'],'Tokenizer size')
    from tokenizers import Tokenizer
    ids=Tokenizer.from_str(tokenizer['raw'].decode('utf-8')).encode(TEXT,add_special_tokens=True).ids
    require(32<len(ids)<=1024 and all(type(x) is int and 0<=x<262144 for x in ids),'Tokenizer-produced prompt geometry')
    selected=ids[:32];a.output.mkdir(mode=0o700);os.umask(0o077)
    raw=(json.dumps(selected,separators=(',',':'))+'\n').encode();write_new(a.output/'prompt.ids.json',raw)
    write_json(a.output/'prompt-receipt.json',dict(schema='gemma_short_tokenizer_packet_v1',artifactSHA256=ARTIFACT,
        manifestSHA256=MANIFEST,tokenizerSHA256=tokenizer['sha256'],tokenizerBytes=tokenizer['size_bytes'],
        tokenizerLibrary='tokenizers',tokenizerVersion=importlib.metadata.version('tokenizers'),
        generatorSHA256=sha(Path(__file__).read_bytes()),authoredText=TEXT,authoredTextSHA256=sha(TEXT.encode()),
        addSpecialTokens=True,chatTemplateApplied=False,selection='first_32_tokenizer_ids',allTokenIDs=ids,tokenIDs=selected,
        promptFileSHA256=sha(raw),promptCount=32,swiftTokenizerQualification=False,modelOrGPUExecuted=False))
    print(json.dumps(dict(prompt=str(a.output/'prompt.ids.json'),sha256=sha(raw))))
if __name__=='__main__':main()
