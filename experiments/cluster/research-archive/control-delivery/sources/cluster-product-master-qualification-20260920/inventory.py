"""Four local packages and the real locked checkout bytes, excluding build output."""
import os
import re
from pathlib import Path
from common import PACKAGES, require, sha


def inventory(root, *, checkouts=True):
    result = {}
    roots = [root / rel for rel in PACKAGES]
    if checkouts:
        roots.append(root / 'provider-swift/.build/checkouts')
    for base in roots:
        require(base.is_dir(), 'Missing source root: ' + str(base))
        for parent, dirs, files in os.walk(base, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in ('.git', '.build', '__pycache__'))
            for name in sorted(files):
                if name == '.git':
                    continue
                path = Path(parent) / name
                row = {'sha256': sha(path)}
                if path.is_symlink():
                    path.resolve(strict=True).relative_to(root)
                    row['symlink'] = os.readlink(path)
                result[str(path.relative_to(root))] = row
    return result


def closure(root):
    seen, pending = set(), ['provider-swift']
    while pending:
        rel = pending.pop()
        if rel in seen:
            continue
        seen.add(rel)
        for value in re.findall(r'\.package\(\s*path:\s*"([^"]+)"', (root / rel / 'Package.swift').read_text()):
            pending.append(str((root / rel / value).resolve(strict=True).relative_to(root)))
    require(seen == set(PACKAGES), 'Local package closure changed: ' + str(sorted(seen)))


def checkout_inventory(root):
    # Keep the same path keys as the full compilation inventory.
    result = {}
    base = root / 'provider-swift/.build/checkouts'
    require(base.is_dir(), 'Locked cache checkouts missing')
    for parent, dirs, files in os.walk(base, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in ('.git', '.build', '__pycache__'))
        for name in sorted(files):
            if name == '.git':
                continue
            path = Path(parent) / name
            row = {'sha256': sha(path)}
            if path.is_symlink():
                path.resolve(strict=True).relative_to(root)
                row['symlink'] = os.readlink(path)
            result[str(path.relative_to(root))] = row
    return result
