"""Portable package integrity helpers; no model or native execution."""
import hashlib
import json
from pathlib import Path, PurePosixPath


def require(condition, message):
    if not condition: raise ValueError(message)


def sha(path):
    digest=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda:stream.read(1024*1024),b''):digest.update(data)
    return digest.hexdigest()


def read(path):
    def closed(items):
        result={}
        for key,value in items:
            require(key not in result,'Duplicate JSON key: '+key);result[key]=value
        return result
    return json.loads(Path(path).read_text(),object_pairs_hook=closed,
        parse_constant=lambda value:require(False,'Nonfinite JSON constant: '+value))


def write(path,value):
    path=Path(path);temp=path.with_name(path.name+'.tmp')
    temp.write_text(json.dumps(value,indent=2,allow_nan=False)+'\n');temp.replace(path)


def contained(root,name):
    relative=PurePosixPath(name)
    require(isinstance(name,str) and str(relative)==name and not relative.is_absolute()
            and '..' not in relative.parts and '\\' not in name and relative.parts,'Invalid package path')
    path=root/name
    require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root.resolve()),'Package file escapes root')
    return path


def verify_package(root,expected):
    root=Path(root).resolve(strict=True);manifest_path=root/'package-manifest.json'
    require(sha(manifest_path)==expected,'Staged package manifest SHA256 differs')
    manifest=read(manifest_path)
    require(manifest['schema_version']==1 and manifest['kind']=='qwen9-local-loopback-correctness','Unexpected package kind')
    entries=manifest['files'];seen=set()
    require(isinstance(entries,list) and entries,'Empty package')
    for entry in entries:
        name=entry['path'];require(name not in seen,'Duplicate package file');seen.add(name)
        path=contained(root,name)
        require(path.stat().st_size==entry['size_bytes'] and sha(path)==entry['sha256'],'Changed package file: '+name)
    actual={p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}
    require(actual==seen|{'package-manifest.json'},'Unexpected/missing package file')
    require(all(not p.is_symlink() for p in root.rglob('*')),'Package must not contain symlinks')
    return manifest
