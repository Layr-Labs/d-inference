"""Small, byte-verified executable/resource/source installation closure."""
import hashlib
import json
import os
from pathlib import Path
import stat
from binding_common import require
from gemma_inputs import PRODUCTS, REMOTE

def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''): value.update(block)
    return value.hexdigest()

def verify(wanted):
    require(Path(__file__).resolve().parent == REMOTE, 'Unexpected installation root')
    require(digest(REMOTE/'package.json') == wanted, 'Package identity changed')
    package=json.loads((REMOTE/'package.json').read_bytes())
    require(package['schema']=='lab_record_install_v1','Package schema')
    seen=set(); total=0
    for row in package['files']:
        relative=Path(row['path'])
        require(not relative.is_absolute() and '..' not in relative.parts and row['path'] not in seen,
                'Invalid package member')
        seen.add(row['path']); path=REMOTE/relative
        s=path.lstat()
        require(path.parent.resolve()==path.parent and stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid()
                and s.st_nlink==1 and s.st_size==row['bytes'], 'Package file changed')
        total+=s.st_size
        require(total < 400_000_000 and digest(path)==row['sha256'], 'Package bytes changed')
    require({'bundle/'+x for x in PRODUCTS} | {'bundle/mlx.metallib','bundle/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal','run_benchmark.py','native_gate.py'} <= seen,
            'Missing executable closure')
    return package
