"""Small explicit source closure; never scans or hashes payload trees."""
import hashlib
import json
import os
from pathlib import Path
import stat

BASE=Path(__file__).resolve().parent
def check_sources():
    raw=(BASE/'source-pins.json').read_bytes()
    if len(raw)>65536:raise ValueError('Source pin bound')
    rows=json.loads(raw)
    if not isinstance(rows,dict) or not rows:raise ValueError('Source pin schema')
    for name,row in rows.items():
        if Path(name).name!=name:raise ValueError('Flat source names')
        path=BASE/name;s=path.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.geteuid() or s.st_nlink!=1 or s.st_size>1048576:raise ValueError('Unsafe source file')
        data=path.read_bytes()
        if len(data)!=row['bytes'] or hashlib.sha256(data).hexdigest()!=row['sha256']:raise ValueError('Changed source: '+name)
    return hashlib.sha256(raw).hexdigest()
