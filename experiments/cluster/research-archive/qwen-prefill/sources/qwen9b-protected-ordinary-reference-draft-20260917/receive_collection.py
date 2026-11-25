"""Extract only exact bounded ordinary-file evidence into a fresh local directory."""
import argparse
import hashlib
import os
from pathlib import Path
import sys
import tarfile
BASE=Path(__file__).resolve().parent;sys.path.insert(0,str(BASE/'package'))
from binding_common import parse, require, same
from reference_inputs import write_json

def member_path(name):
    path=Path(name)
    require(type(name) is str and not path.is_absolute() and str(path)==name and ".." not in path.parts and name not in ("", "."), "Relative evidence path required")



def receive(archive_path,output):
    require(output.is_absolute() and output.parent.resolve()==output.parent,'Canonical collection parent')
    output.mkdir(mode=0o700);seen=set();total=0
    with archive_path.open('rb') as stream:
        raw=stream.readline(131073);require(len(raw)<=131072 and raw.endswith(b'\n'),'Collection header bound')
        header=parse(raw);same(header['schema'],'qwen9b_protected_ordinary_reference_collection_v1','collection schema')
        require(type(header['files']) is list and 1<=len(header['files'])<=160,'Collection member count')
        rows={}
        for row in header['files']:
            name=row['path'];member_path(name);require(name not in rows and name.count('/')<=1,'Collection member path')
            require(type(row['bytes']) is int and 0<=row['bytes']<=16*1024**2,'Collection member size')
            total+=row['bytes'];require(total<=64*1024**2,'Collection total');rows[name]=row
        with tarfile.open(fileobj=stream,mode='r|') as archive:
            for member in archive:
                require(member.name in rows and member.name not in seen and member.isfile() and not member.issparse(),'Unexpected archive member')
                row=rows[member.name];same(member.size,row['bytes'],'Archived size');target=output/member.name
                target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600);digest=hashlib.sha256();left=member.size
                try:
                    source=archive.extractfile(member)
                    while left:
                        raw=source.read(min(left,65536));require(raw,'Truncated collection');left-=len(raw);digest.update(raw)
                        view=memoryview(raw)
                        while view:
                            count=os.write(fd,view);require(count>0,'Collection write stalled');view=view[count:]
                    os.fsync(fd)
                finally:os.close(fd)
                same(digest.hexdigest(),row['sha256'],'Collected hash');seen.add(member.name)
        same(seen,set(rows),'Exact collection coverage')
    # Outside the native evidence directory, so the original inventory is exact.
    write_json(output.parent/(output.name+'-collection.json'),header)
    return header


def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--archive',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    receive(a.archive,a.output)
if __name__=='__main__':main()
