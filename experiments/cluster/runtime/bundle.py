"""Create one immutable snapshot shared by every rank in a run."""

import json
import shutil
from pathlib import Path

from .artifacts import file_sha256


def snapshot(source, destination):
    destination.mkdir(mode=0o700)
    for name in ('cluster-inference', 'mlx.metallib', 'mlx-swift-lm_MLXLMCommon.bundle'):
        item = source / name
        if not item.exists():
            raise ValueError(f'Missing inference bundle resource: {item}')
        if item.is_dir():
            shutil.copytree(item, destination / name)
        else:
            shutil.copyfile(item, destination / name)
    # The worker is copied with the binary so the remote host needs only Python.
    for name in ('rank_worker.py', 'artifacts.py'):
        shutil.copyfile(Path(__file__).parent / name, destination / name)
    entries = []
    for path in sorted(destination.rglob('*')):
        if path.is_file():
            path.chmod(0o500 if path.name == 'cluster-inference' else 0o400)
            entries.append(dict(path=path.relative_to(destination).as_posix(),
                                size_bytes=path.stat().st_size,
                                sha256=file_sha256(path)))
    manifest = destination / 'bundle.json'
    manifest.write_text(json.dumps(dict(schema_version=1, files=entries), indent=2) + '\n')
    manifest.chmod(0o400)
    return file_sha256(manifest)
