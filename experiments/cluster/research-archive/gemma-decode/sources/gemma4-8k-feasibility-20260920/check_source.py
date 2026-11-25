"""Small source/metadata consistency checks only; no native subprocess."""
from pathlib import Path
import ast, difflib, hashlib, json

ROOT = Path(__file__).resolve().parent
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

context = json.loads((ROOT / 'window-bound-context.json').read_bytes())
for row in context['inputs']:
    path = Path(row['path'])
    assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
before = Path(context['preimage']['path'])
after = Path(context['postimage']['path'])
assert sha(before) == context['preimage']['sha256']
assert sha(after) == context['postimage']['sha256']
key = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Gemma4BenchmarkResourceBudget.swift'
expected = ''.join(difflib.unified_diff(before.read_text().splitlines(True), after.read_text().splitlines(True), fromfile='a/'+key, tofile='b/'+key))
assert (ROOT / 'window-bound.patch').read_text() == expected
commands = json.loads((ROOT / 'metadata-commands.json').read_bytes())
assert len(commands['commands']) == 6
for row in commands['commands']:
    assert row['argv'][1] in ['--describe', '--check-arguments'] and row['timeoutSeconds'] == 15
    path = Path(row['argv'][2]); assert sha(path) == row['jobSHA256']
    job = json.loads(path.read_bytes())
    assert job['buildIdentitySHA256'] == commands['nativeSHA256']
    assert job['captureEvidence'] and job['promptCount'] == 8192 and job['outputCount'] == 16
    assert sha(Path(job['promptFile'])) == job['promptFileSHA256']
    assert len(json.loads(Path(job['promptFile']).read_bytes())) == 8192
    assert not Path(job['outputDirectory']).exists()
for path in ROOT.glob('*.py'): ast.parse(path.read_bytes(), filename=str(path))
print(json.dumps(dict(sourceOnly=True, nativeExecuted=False, compilerExecuted=False, contextPins=len(context['inputs']), metadataCommands=6, exactPatch=True)))
