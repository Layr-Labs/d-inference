"""Frozen source-only cut12 pair context and unchanged long-rank controls."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
PAIR = ROOT/'8k-stage-cut-pair-audit-draft'
PAIR_MANIFEST_SHA = '0364776383f78e5b1d17cc4969a5785d0e20355ff314e3825030e35fdc4acb9e'
OLD_DEPENDENCIES_SHA = 'c4792b73d06b21b473aecba6e022a7ac091c675e5e3aa5ec104c006d6a8fbead'
_CACHE = None
_PAIR_ORACLE = None


def digest(data): return hashlib.sha256(data).hexdigest()


def bounded(path, limit=2*1024**2):
    with Path(path).open('rb') as f: data=f.read(limit+1)
    if not 0<len(data)<=limit: raise ValueError('Frozen dependency byte bound differs')
    return data


def load_module(name,path,pin):
    if digest(bounded(path)) != pin: raise ValueError('Frozen module source pin differs')
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);sys.modules[name]=value;spec.loader.exec_module(value)
    return value


def verify_pins():
    raw=bounded(PAIR/'manifest.json')
    if digest(raw)!=PAIR_MANIFEST_SHA: raise ValueError('Frozen selected-pair oracle manifest differs')
    manifest=json.loads(raw)
    if len(manifest['files'])!=21: raise ValueError('Frozen selected-pair member count differs')
    found={str(PAIR/'manifest.json'):dict(sha256=PAIR_MANIFEST_SHA,byteCount=len(raw))}
    for item in manifest['files']:
        data=bounded(PAIR/item['path'])
        if len(data)!=item['sizeBytes'] or digest(data)!=item['sha256']:
            raise ValueError('Frozen selected-pair oracle member differs')
        found[str(PAIR/item['path'])]=dict(sha256=item['sha256'],byteCount=len(data))
    # Preserve the original runtime/wire source controls. Its old baseline path
    # constants are never read or used by this selected-pair container adapter.
    old=load_module('cut12_preserved_rank_dependency_source',
        ROOT/'long-prefill-rank-audit-draft/rank_dependencies.py',OLD_DEPENDENCIES_SHA)
    found.update(old.verify_pins())
    return found


def context():
    global _CACHE,_PAIR_ORACLE
    if _CACHE is None:
        verify_pins()
        pins=json.loads((PAIR/'core-helper-pins.json').read_bytes())
        def load(name,file):return load_module(name,PAIR/file,pins[file])
        load('cut12_reference_context','cut12_reference_context.py')
        a=load('cut12_rank_reference_oracle','qwen_long_prefill_reference_cut12_audit.py')
        storage=load('cut12_pair_storage','cut12_pair_storage.py')
        final=load('cut12_pair_final','cut12_pair_final.py')
        wire=load('cut12_pair_wire','cut12_pair_wire.py')
        _PAIR_ORACLE=load('cut12_rank_pair_oracle','qwen_long_prefill_pair_cut12_audit.py')
        a.context();_CACHE=(a,storage,final,wire)
    return _CACHE


def pair_oracle():
    context()
    return _PAIR_ORACLE
