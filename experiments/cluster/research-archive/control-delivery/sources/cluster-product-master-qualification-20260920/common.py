"""Frozen inputs and create-only evidence for the default master composition."""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
BASE = Path(__file__).resolve().parent
RUN = BASE / 'qualification-1'
WORKSPACE = RUN / 'workspace'
PACKAGES = ('provider-swift', 'libs/darkbloom-cluster', 'libs/mlx-swift', 'libs/mlx-swift-lm')


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def read(path):
    return json.loads(Path(path).read_bytes())


def save(path, value):
    with Path(path).open('x') as stream:
        stream.write(json.dumps(value, indent=2, sort_keys=True) + '\n')


def pin(row):
    path = Path(row['path'])
    require(path.is_file() and not path.is_symlink(), 'Missing or indirect input: ' + str(path))
    require(path.stat().st_size == row['bytes'] and sha(path) == row['sha256'], 'Input changed: ' + str(path))


def inputs():
    for row in read(BASE / 'manifest.json')['members']:
        pin(dict(row, path=str(BASE / row['path'])))
    contract = read(BASE / 'context.json')
    for row in contract['pins']:
        pin(row)
    return contract


def source_contract(root, *, git_heads=False):
    contract = inputs()
    for row in read(BASE / 'expected-files.json'):
        path = root / row['path']
        require(path.is_file() and not path.is_symlink() and sha(path) == row['sha256'], 'Composition differs: ' + row['path'])
    for rel in contract['excludedPrivateFiles']:
        require(not (root / rel).exists(), 'Private experiment source entered default product: ' + rel)
    require(sha(root / 'provider-swift/Package.resolved') == contract['packageResolvedSHA256'], 'Locked dependency set changed')
    package = (root / 'provider-swift/Package.swift').read_text()
    require(all(x not in package for x in ('NATIVE_PAIR_HARDWARE_EXPERIMENT', 'PrivateClusterTLS', 'DARKBLOOM_PRIVATE')), 'Private build configuration present')
    if git_heads:
        for rel, head in contract['gitHeads'].items():
            actual = subprocess.check_output(['/usr/bin/git', '-C', str(root / rel), 'rev-parse', 'HEAD'], text=True, timeout=10).strip()
            require(actual == head, 'Git source identity differs: ' + rel)
    return contract


def clean_environment():
    keep = ('PATH', 'HOME', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'SDKROOT')
    env = {key: os.environ[key] for key in keep if key in os.environ}
    os.environ.clear()
    os.environ.update(env)
    os.environ['TMPDIR'] = '/private/tmp'
    os.environ['PYTHONDONTWRITEBYTECODE'] = '1'


def prepared():
    contract = inputs()
    receipt = read(RUN / 'prepare/receipt.json')
    value = read(RUN / 'prepare/prepared.json')
    require(receipt['passed'] and value['passed'] and value['manifestSHA256'] == sha(BASE / 'manifest.json'), 'Matching completed preparation required')
    require(value['candidateSHA256'] == sha(RUN / 'prepare/candidate.json'), 'Candidate inventory identity changed')
    require(receipt['executionSHA256'] == sha(RUN / 'prepare/execution.json'), 'Preparation execution changed')
    source_contract(WORKSPACE)
    return contract, value, read(RUN / 'prepare/candidate.json')
