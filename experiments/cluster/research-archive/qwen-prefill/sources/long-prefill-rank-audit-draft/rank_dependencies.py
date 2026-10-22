"""Only frozen Python/source metadata controls; never model payloads."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parent.parent
PINNED={
 'long-prefill-reference-audit-draft/qwen_long_prefill_reference_audit.py':'e316c559f2827c539bd25f0c6baed226e21bc704df3e4facf0d889605914abd1',
 'long-prefill-pair-audit-draft/pair_storage.py':'ed3b81493e2a25cf2fa111a1eeab17fd2e647a77b99b8cbea353684e152d1291',
 'long-prefill-pair-audit-draft/pair_final.py':'505f27ca65a22de52110f23c4d8f30ff48239f3406e857460adf18b688254492',
 'long-prefill-pair-audit-draft/pair_wire.py':'6ba8f7b82b131eade12a415e0e913688cfbc90362c09b666bce4ea766407a5cc',
 'long-prefill-pair-audit-draft/source-review-20260914.json':'a3689b28fbc166cc6f086f8627863a6a75457d760e88aa5bcc8c572ff2e04dee',
 'long-prefill-rank-flow-draft/manifest.json':'de1c2b567456c6413dfc050c433c5efde24d3ab40f5ea7e10d05d2c17445d2e5',
 'long-prefill-native-wire-draft/source-review-20260914.json':'3dcf7ea6deff937a04ac250d8eee7ddf5604f9419e9c43590faba19b26d69f10',
 'long-prefill-wire-draft/source-review-20260914.json':'36af6ffa2b0c21ca45968d5f7131fa73617e6ab52866a87caad95a4eda6a671d',
 'long-prefill-rank-entry-draft/QwenLongPrefillRankAdmission.swift':'185e7fc98bbb6d9401c1971c829d947fa14582cca1189c17575ee02cf4294809',
 'long-prefill-rank-entry-draft/QwenLongPrefillRankCheck.swift':'9a9cc05f44597b262e531ec43512a396a312500b0d733dd9704c9b9b8d7ba4bd',
 'long-prefill-rank-entry-draft/QwenLongPrefillRankReport.swift':'fb89962782a788471040d378ab7b74bfd01b6ebcae20fa03e86e1e182897058e',
}
BASELINE_SHA='da85eb1e79a43c16575e6a8ffd48594ccb72306c16543a1e02c24903b89c154a'
BASELINE_RECEIPT='runs/qwen-long-prefill-reference-peer24-20260914/independent-cpu-audit-receipt.json'
BASELINE_RECEIPT_SHA='bff08ef62a84c2ebd950ef692989abe6c037773cb1cc2af50bf5a31acc63c14c'
_CACHE=None


def digest(data):return hashlib.sha256(data).hexdigest()


def verify_pins():
    found={}
    for name,wanted in PINNED.items():
        path=ROOT/name
        with path.open('rb') as stream:data=stream.read(2*1024**2+1)
        if len(data)>2*1024**2 or digest(data)!=wanted:raise ValueError('Frozen rank-audit dependency changed: '+name)
        found[name]=dict(sha256=wanted,byteCount=len(data))
    for name in ['long-prefill-rank-flow-draft/manifest.json','long-prefill-native-wire-draft/source-review-20260914.json',
            'long-prefill-wire-draft/source-review-20260914.json']:
        for item in json.loads((ROOT/name).read_bytes())['files']:
            path=Path(item['path'])
            if not path.is_absolute():path=(ROOT/name).parent/path
            with path.open('rb') as stream:raw=stream.read(2*1024**2+1)
            if digest(raw)!=item['sha256'] or len(raw)!=item.get('byteCount',item.get('size_bytes')):
                raise ValueError('Frozen source member changed')
    return found


def load_module(name,path,pin):
    if digest(path.read_bytes())!=pin:raise ValueError('Import source pin differs')
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);sys.modules[name]=value;spec.loader.exec_module(value)
    return value


def context():
    global _CACHE
    if _CACHE is None:
        verify_pins()
        def load(name,file):return load_module(name,ROOT/file,PINNED[file])
        a=load('rank_pinned_reference_oracle','long-prefill-reference-audit-draft/qwen_long_prefill_reference_audit.py')
        storage=load('pair_storage','long-prefill-pair-audit-draft/pair_storage.py')
        final=load('rank_pinned_pair_final','long-prefill-pair-audit-draft/pair_final.py')
        wire=load('rank_pinned_pair_wire','long-prefill-pair-audit-draft/pair_wire.py')
        a.context()
        _CACHE=(a,storage,final,wire)
    return _CACHE
