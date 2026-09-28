"""Bounded copy stream after explicit root grant; rehash every supplied member."""
import argparse
from pathlib import Path
import sys
import tarfile
BASE=Path(__file__).resolve().parent
REFERENCE=BASE.parent/'qwen9b-protected-ordinary-reference-draft-20260917'
sys.path.insert(0,str(REFERENCE/'package'))
from binding_common import parse, require, same
from binding_inputs import snapshot


def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--bound',type=Path,required=True)
    p.add_argument('--deployment-sha256',required=True);a=p.parse_args()
    item=snapshot(a.bound/'deployment.json',1048576);same(item['sha256'],a.deployment_sha256,'deployment')
    manifest=parse(item['raw']);sources=parse((a.bound/'sources.json').read_bytes())
    same(set(manifest['files']),{'check/'+x for x in sources},'Source coverage')
    for name,row in manifest['files'].items():
        source=sources[name.removeprefix('check/')];same({k:source[k] for k in ('bytes','sha256','mode')},row,'source binding')
        value=snapshot(Path(source['path']),max(row['bytes'],1),keep=False,empty=True)
        same(value['sha256'],row['sha256'],'Copy source pin');same(value['size_bytes'],row['bytes'],'Copy source size')
    sys.stdout.buffer.write(item['raw'])
    with tarfile.open(fileobj=sys.stdout.buffer,mode='w|') as archive:
        for name,row in sorted(manifest['files'].items()):
            path=Path(sources[name.removeprefix('check/')]['path']);info=tarfile.TarInfo(name)
            info.size,info.mode,info.mtime=row['bytes'],row['mode'],0
            with path.open('rb') as stream:archive.addfile(info,stream)


if __name__=='__main__':main()
