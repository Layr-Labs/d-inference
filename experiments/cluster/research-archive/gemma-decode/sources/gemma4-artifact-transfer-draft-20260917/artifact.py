"""Exact eleven-file tree and bounded full-file hashes with stable identities."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import time
from binding_common import require,same

BASE=Path(__file__).resolve().parent
SOURCE=Path('/Users/developer/.cache/huggingface/hub/models--gemma-4-26b-qat-4bit/snapshots/local')
PREPARATION=Path('/Users/developer/DarkbloomDev/gemma4-model-preparation-20260917')
STAGE=PREPARATION/'model'
FINAL=Path('/Users/developer/DarkbloomDev/models/Gemma4-26B')
MANIFEST='c1fefb1fa593fa3ca83e72a1124fb3afca10a59eed272c7ac2ac4a57f8018dfd'
AGGREGATE='2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785'
PAYLOAD=15_641_239_295

def digest(raw):return hashlib.sha256(raw).hexdigest()
def encoded(value):return (json.dumps(value,indent=2,sort_keys=True,allow_nan=False)+'\n').encode()
def write(path,raw):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:stream.write(raw);stream.flush();os.fsync(stream.fileno())
def record(path,value):write(path,encoded(value))
def stamp(s):return [s.st_dev,s.st_ino,s.st_mode,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns]
def manifest():
    raw=(BASE/'artifact-manifest.json').read_bytes();same(digest(raw),MANIFEST,'Exact registered manifest')
    value=json.loads(raw);same(value['aggregate_sha256'],AGGREGATE,'Manifest artifact identity')
    same(value['file_count'],10,'Manifest count');same(value['total_size_bytes'],PAYLOAD,'Payload bytes')
    require(len(value['files'])==10 and sum(r['size_bytes'] for r in value['files'])==PAYLOAD,'Complete payload rows')
    require(len({r['path'] for r in value['files']})==10 and all(Path(r['path']).name==r['path'] for r in value['files']),'Flat unique registered files')
    return raw,value['files']
def inspect(path):
    require(path.is_absolute() and path.parent.resolve()==path.parent,'Canonical file parent')
    s=path.lstat();require(stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and s.st_nlink==1 and s.st_mode&0o022==0,'Unsafe regular file')
    return stamp(s)
def hash_file(path,size,wanted,deadline):
    before=inspect(path);same(before[4],size,'Declared file size');fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC|os.O_NONBLOCK)
    h=hashlib.sha256();count=0
    try:
        same(stamp(os.fstat(fd)),before,'Open file identity');fcntl.fcntl(fd,48,1) # Darwin F_NOCACHE.
        while count<size:
            require(time.monotonic()<deadline,'Full-file verification deadline')
            block=os.read(fd,min(8*1024**2,size-count));require(block,'Short file');h.update(block);count+=len(block)
        require(os.read(fd,1)==b'','File grew during verification')
        same(stamp(os.fstat(fd)),before,'Open file changed');same(inspect(path),before,'Named file changed')
    finally:os.close(fd)
    same(h.hexdigest(),wanted,'Whole-file digest: '+path.name)
    return dict(path=path.name,bytes=count,sha256=h.hexdigest(),identity=before,fNoCache=True)
def verify_tree(root,deadline):
    raw,rows=manifest();require(root.resolve()==root and root.is_dir(),'Canonical model tree')
    same({p.name for p in root.iterdir()},{r['path'] for r in rows}|{'manifest.json'},'Exact eleven-file tree')
    values=[hash_file(root/r['path'],r['size_bytes'],r['sha256'],deadline) for r in rows]
    manifest_row=hash_file(root/'manifest.json',len(raw),MANIFEST,deadline)
    return dict(files=values,manifest=manifest_row,manifestSHA256=MANIFEST,manifestAggregateSHA256=AGGREGATE,
                payloadBytes=PAYLOAD,wholePayloadVerified=True)
def disk(directory):
    s=os.statvfs(directory);available=s.f_bavail*s.f_frsize
    require(available>=PAYLOAD+16*1024**3,'Require payload plus16GiB actual available disk space')
    return dict(path=str(directory),availableBytes=available,requiredBytes=PAYLOAD+16*1024**3)
def recheck(root,verification):
    for row in verification['files']+[verification['manifest']]:same(inspect(root/row['path']),row['identity'],'Verified file changed')
