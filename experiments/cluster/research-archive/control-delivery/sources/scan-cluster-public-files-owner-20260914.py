#!/usr/bin/env python3
"""CPU-only repository content hygiene; never emits private matched values."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

REPO = Path('/Users/developer/DarkbloomDev/d-inference')
ROOT = REPO.parent / 'cluster-research'


def command(*arguments):
    return subprocess.run(arguments, cwd=REPO, check=True, capture_output=True,
                          text=True, timeout=30).stdout


def main():
    names = sorted(set(command('git', 'ls-files', '--cached', '--others', '--exclude-standard',
        'experiments/cluster', 'docs/design/README.md', 'docs/design/distributed-inference-goal.md',
        'docs/developer/build.md', 'docs/developer/test.md').splitlines()))
    private_text = (REPO.parent / 'machines/CREDENTIALS.private.md').read_text()
    private_values = [value for line in private_text.splitlines() if 'password' in line.lower()
                      for value in re.findall(r'`([^`]+)`', line) if len(value) >= 8]
    assert private_values, 'No private comparison values loaded'
    patterns = [r'/Users/gaj', r'100\.109\.199\.72', r'100\.96\.148\.101',
                r'BEGIN (?:OPENSSH|RSA|EC) PRIVATE KEY', r'id_ed25519_darkbloom_dev']
    exceptions, files, links = [], [], 0
    for name in names:
        path = REPO / name
        raw = path.read_bytes()
        content = raw.decode('utf-8')
        assert '\x00' not in content, (name, 'Binary content')
        for number, line in enumerate(content.splitlines(), 1):
            assert line.rstrip() == line, (name, number, 'Trailing whitespace')
            assert not any(re.search(pattern, line) for pattern in patterns), (name, number, 'Private identifier')
            if any(value in line for value in private_values):
                assert name == 'docs/developer/build.md' and line.startswith('FROM '), (name, number, 'Private value')
                assert line in command('git', 'show', 'HEAD:' + name).splitlines(), (name, number, 'Changed public namespace')
                exceptions.append(dict(path=name, reason='Unchanged public base-image namespace'))
        if path.suffix == '.md':
            for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)', content):
                if re.match(r'[a-zA-Z][a-zA-Z0-9+.-]*:', target):
                    continue
                relative = target.split('#')[0].strip('<>')
                assert (path.parent / relative).resolve().exists(), (name, target, 'Missing relative link')
                links += 1
        files.append(dict(path=name, sizeBytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
    command('git', 'diff', '--check')
    out = ROOT / 'qwen-prefill-owner-public-source-scan-20260914.json'
    assert not out.exists(), 'Preserve earlier scan'
    result = dict(kind='cluster_public_content_scan', schemaVersion=1, passed=True,
        checkedAtUTC=datetime.now(timezone.utc).isoformat(), gitHead=command('git', 'rev-parse', 'HEAD').strip(),
        publicFiles=len(files), relativeLinksChecked=links, existingPublicExceptions=exceptions,
        files=files, nativeExecutionPerformed=False, secretsEmitted=False)
    with out.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True); stream.write('\n')
    print(json.dumps(dict(passed=True, publicFiles=len(files), relativeLinksChecked=links,
        output=str(out), sha256=hashlib.sha256(out.read_bytes()).hexdigest())))


if __name__ == '__main__':
    main()
