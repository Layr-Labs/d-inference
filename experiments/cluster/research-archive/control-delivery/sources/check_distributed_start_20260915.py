#!/usr/bin/env python3
"""Run the combined real Provider check without changing dependency pins."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import time

REPO = Path('/Users/developer/DarkbloomDev/d-inference')
BASE = Path('/Users/developer/DarkbloomDev/cluster-research/distributed-start-main-integration-20260915')
OUT = BASE / ('provider-tests-' + sys.argv[1])
OUT.mkdir()
pin = REPO / 'provider-swift/Package.resolved'
pin_before = hashlib.sha256(pin.read_bytes()).hexdigest()
command = ['swift', 'test', '--jobs', '2', '--disable-automatic-resolution',
           '--disable-build-manifest-caching', '--filter',
           'Cluster|Distributed|StartCommandTests|ProcessLifecycleTests']
started = time.monotonic()
with (OUT / 'stdout').open('wb') as stdout, (OUT / 'stderr').open('wb') as stderr:
    try:
        result = subprocess.run(command, cwd=REPO / 'provider-swift', stdout=stdout,
                                stderr=stderr, timeout=600)
        code = result.returncode
    except subprocess.TimeoutExpired:
        code = 124
pin_after = hashlib.sha256(pin.read_bytes()).hexdigest()
receipt = {'command': command, 'elapsedSeconds': time.monotonic() - started,
           'exitCode': code, 'pinBefore': pin_before, 'pinAfter': pin_after}
(OUT / 'execution.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))
assert pin_before == pin_after, 'Dependency resolution changed'
sys.exit(code)
