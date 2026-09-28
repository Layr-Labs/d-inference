#!/usr/bin/env python3
"""Generate the experiment's MLX-Swift manifest overlay without editing submodules."""

import hashlib
import json
from pathlib import Path


def write_if_changed(path, content):
    if not path.exists() or path.read_text() != content:
        temporary = path.with_suffix(path.suffix + '.temporary')
        temporary.write_text(content)
        temporary.replace(path)


def prepare():
    experiment = Path(__file__).resolve().parent
    source = experiment.parents[2] / 'libs' / 'mlx-swift'
    generated = experiment / '.generated-dependencies' / 'mlx-swift'
    original = (source / 'Package.swift').read_text()
    real_backend = '        "mlx/mlx/distributed/ring/ring.cpp",'
    stub_backend = '        "mlx/mlx/distributed/ring/no_ring.cpp",'
    if original.count(real_backend) != 1 or stub_backend in original:
        raise ValueError('Pinned MLX-Swift ring exclusions changed; review the overlay before building')
    manifest = original.replace(real_backend, stub_backend)
    generated.mkdir(parents=True, exist_ok=True)
    # Sources and resources stay at their pinned checkout. Never link mutable
    # package/build state: SwiftPM must write only into this generated directory.
    omitted = {'Package.swift', 'Package.resolved', '.git', '.build', '.swiftpm'}
    for item in source.iterdir():
        if item.name in omitted or item.name.startswith('.'):
            continue
        link = generated / item.name
        if link.is_symlink():
            if link.resolve() != item.resolve():
                raise ValueError(f'Unexpected generated symlink: {link}')
        elif link.exists():
            raise ValueError(f'Refusing to replace an existing generated path: {link}')
        else:
            link.symlink_to(item, target_is_directory=item.is_dir())
    write_if_changed(generated / 'Package.swift', manifest)
    identity = {
        'source_manifest_sha256': hashlib.sha256(original.encode()).hexdigest(),
        'generated_manifest_sha256': hashlib.sha256(manifest.encode()).hexdigest(),
        'change': 'Enable the MLX TCP ring backend and exclude its no_ring stub',
    }
    write_if_changed(generated.parent / 'overlay.json', json.dumps(identity, indent=2) + '\n')
    print(generated)


if __name__ == '__main__':
    prepare()
