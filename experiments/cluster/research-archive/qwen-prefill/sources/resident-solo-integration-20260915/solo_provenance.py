"""Exact aa7d source/bundle and model-metadata checks; never executes archives."""
import json
import os
from pathlib import Path
import stat
from binding_inputs import snapshot
from stage_checks.common import parse, require

PACKAGE_SHA = '282a2bfe07cdacfebbeb2c5c7ba0b785370c731f9ceb394cc4444c1a6a481885'
BUNDLE_SHA = '112c6ca9ca3250b1345b7f2f19b561e81d7d08cf55beac2a54080e9ed18ec63c'
NATIVE_SHA = 'aa7d205de4d2b5b7ac26842e0fd0fa42c96774b5ed1b229f418d726636da279a'
CONFIG_SHA = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
MODEL_MANIFEST_SHA = '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4'


class PinnedFiles:
    def __init__(self): self.files = []

    def read(self, path, cap, wanted=None, keep=True):
        path = Path(path); value = snapshot(path, cap, keep=keep)
        require(wanted is None or value['sha256'] == wanted, 'File pin differs: '+str(path))
        self.files.append((path,cap,{k:v for k,v in value.items() if k!='raw'}))
        return value

    def recheck(self):
        for path,cap,before in self.files:
            after = snapshot(path,cap,keep=False)
            require({k:v for k,v in after.items() if k!='raw'} == before, 'File changed: '+str(path))

    def records(self):
        return [dict(path=str(p),sha256=v['sha256'],size_bytes=v['size_bytes']) for p,_,v in self.files]


def deployment(root, pins):
    root = Path(root)
    require(root.is_absolute() and root.is_dir() and not root.is_symlink(), 'Explicit real deployment directory required')
    manifest = pins.read(root/'manifest.json', 1024**2, PACKAGE_SHA)
    entries = parse(manifest['raw'])['files']; require(len(entries)==431, 'Wrong deployment member count')
    seen = set()
    for entry in entries:
        name = entry['path']; path = root/name
        require(name not in seen and not Path(name).is_absolute() and '..' not in Path(name).parts,
                'Invalid deployment member')
        require(all(not p.is_symlink() for p in path.parents), 'Symlink in deployment ancestry')
        row = pins.read(path, 256*1024**2, entry['sha256'], keep=False)
        require(row['size_bytes']==entry['size_bytes'], 'Deployment member size differs')
        seen.add(name)
    bundle = root/'bundle'
    bm = parse(pins.read(bundle/'bundle.json',1024**2,BUNDLE_SHA)['raw'])
    require(len(bm['files'])==5, 'Bundle member count differs')
    actual = set()
    for directory, dirs, files in os.walk(bundle,followlinks=False):
        for path in [Path(directory)]+[Path(directory)/n for n in dirs+files]:
            st = path.lstat(); require(st.st_uid==os.geteuid() and not stat.S_ISLNK(st.st_mode), 'Bundle is not owned/non-symlink')
            if stat.S_ISDIR(st.st_mode): require(st.st_mode & 0o022 == 0,'Bundle directory is externally writable')
            else:
                require(stat.S_ISREG(st.st_mode) and st.st_mode & 0o222 == 0,'Bundle file must be read-only')
                actual.add(path.relative_to(bundle).as_posix())
    require(actual == {'bundle.json'} | {x['path'] for x in bm['files']}, 'Bundle tree differs')
    require((bundle/'cluster-inference').stat().st_mode & stat.S_IXUSR, 'Native executable bit missing')
    return bundle, manifest['raw']


def model_metadata(directory, pins):
    directory = Path(directory)
    require(directory.is_absolute() and directory.is_dir() and not directory.is_symlink(), 'Explicit real model directory required')
    config = pins.read(directory/'config.json',1024**2,CONFIG_SHA)['raw']
    manifest = pins.read(directory/'manifest.json',4*1024**2,MODEL_MANIFEST_SHA)['raw']
    require(parse(manifest)['aggregate_sha256']=='127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b',
            'Model artifact differs')
    return config,manifest


def inherited(pins):
    here=Path(__file__).parent
    saved = pins.read(here/'inherited-pins.json', 65536)
    for name,row in parse(saved['raw']).items():
        require(not Path(name).is_absolute() and '..' not in Path(name).parts, 'Invalid inherited member')
        pins.read(here/name,1024**2,row['sha256'],keep=False)
