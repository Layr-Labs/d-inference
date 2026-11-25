"""Local-only immutable deployment stream; caller separately owns authenticated SSH."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile

ROOT = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, '/Users/developer/DarkbloomDev/cluster-research/gemma4-windowed-state-supervisor-20260916/package')
from binding_common import require
from binding_inputs import snapshot


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--deployment-sha256', required=True)
    args = parser.parse_args()
    raw = snapshot(ROOT/'deployment.json', 1024**2)['raw']
    require(hashlib.sha256(raw).hexdigest() == args.deployment_sha256, 'Deployment manifest pin differs')
    manifest = json.loads(raw)
    files = manifest['files']
    # Validate every member before publishing any deployment bytes.
    for name, entry in files.items():
        require(name.startswith('check/') and '..' not in Path(name).parts, 'Deployment path differs')
        path = ROOT/'package'/name.removeprefix('check/')
        item = snapshot(path, max(entry['bytes'], 1), keep=False, empty=True)
        require(item['sha256'] == entry['sha256'] and item['size_bytes'] == entry['bytes'], 'Deployment member differs')
    sys.stdout.buffer.write(raw)
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as archive:
        for name, entry in sorted(files.items()):
            path = ROOT/'package'/name.removeprefix('check/')
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = entry['bytes'], entry['mode'], 0
            with path.open('rb') as source: archive.addfile(info, source)


if __name__ == '__main__': main()
