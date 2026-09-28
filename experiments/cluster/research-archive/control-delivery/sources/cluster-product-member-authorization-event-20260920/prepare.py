"""Apply only the two pinned successors to the existing disposable candidate."""
import os
import sys
from pathlib import Path
from common import BASE, RUN, inputs, require, save, sha
from inventory import inventory

def main():
    require(len(sys.argv) == 2 and Path(sys.argv[1]) == RUN / 'prepare', 'Exact fresh output required')
    out = Path(sys.argv[1]); c, w, before, after = inputs()
    require(inventory(w) == before, 'Full preserved candidate preimage differs')
    for row in __import__('json').loads((BASE / 'overlay.json').read_bytes()):
        target = w / row['path']; original = out / 'originals' / row['path']
        require(sha(target) == row['beforeSHA256'] and not target.is_symlink(), 'Source preimage differs')
        original.parent.mkdir(parents=True, exist_ok=True)
        with original.open('xb') as stream: stream.write(target.read_bytes())
    for row in __import__('json').loads((BASE / 'overlay.json').read_bytes()):
        target = w / row['path']; temp = target.with_name(target.name + '.authorization-event-new')
        with temp.open('xb') as stream:
            stream.write((BASE / 'proposed' / row['path']).read_bytes()); stream.flush(); os.fsync(stream.fileno())
        require(sha(target) == row['beforeSHA256'] and sha(temp) == row['sha256'], 'Source changed before replacement')
        os.replace(temp, target)
    require(inventory(w) == after, 'Corrected compilation inventory differs')
    save(out / 'prepared.json', dict(passed=True, manifestSHA256=sha(BASE / 'manifest.json'), candidateSHA256=c['candidateSHA256'], helperRebuilt=False, compilerExecuted=False))
if __name__ == '__main__': os.umask(0o077); main()
