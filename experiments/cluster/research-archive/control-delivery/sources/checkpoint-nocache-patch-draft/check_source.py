"""Bounded source check; does not compile Swift or perform checkpoint IO."""
from pathlib import Path
import difflib, hashlib, json

p = Path(__file__).resolve().parent
old = (p/'original.swift').read_text()
new = (p/'VerifiedCheckpoint.swift').read_text()
base = json.loads((p/'base-pin.json').read_text())
assert hashlib.sha256(old.encode()).hexdigest() == base['sha256']
start = '        func digest() throws -> SHA256.Digest {'
end = '\n    }\n\n    let aggregate: String'
ob, oa = old.split(start,1); om, ot = oa.split(end,1)
nb, na = new.split(start,1); nm, nt = na.split(end,1)
assert ob == nb and ot == nt
assert ''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),
    fromfile='a/'+base['repositoryRelativePath'],tofile='b/'+base['repositoryRelativePath'])) == (p/'digest-only.patch').read_text()
order = ['guard fcntl(descriptor, F_NOCACHE, 1) == 0', 'do {',
    'var buffer = Data(count: min(blockSize, size))', 'while offset < size',
    'try read(into: block, offset: offset)', 'hash.update(bufferPointer: UnsafeRawBufferPointer(block))',
    'offset += count', 'try checkUnchanged()', 'let digest = hash.finalize()',
    'guard fcntl(descriptor, F_NOCACHE, 0) == 0', 'return digest', '} catch {',
    '_ = fcntl(descriptor, F_NOCACHE, 0)', 'throw error']
indices = [nm.index(s) for s in order]
assert indices == sorted(indices)
assert nm.count('Data(count:') == 1 and nm.count('hash.update(') == 1
assert 'let count = min(blockSize, size - offset)' in nm and 'bytes[..<count]' in nm
assert all(s not in nm for s in ['F_GLOBAL_NOCACHE','F_RDAHEAD','try?','mmap','fsync','purge'])
assert 'if count < 0 && errno == EINTR { continue }' in new
assert 'let digest = try file.digest()' in new and 'aggregateHasher.update(bufferPointer: $0)' in new
result={'scope':'source checks only','checksPassed':True,'checks':9,
    'changedScope':'VerifiedCheckpoint.File.digest only','swiftCompiled':False,
    'checkpointIOExecuted':False,'currentCoreSourceSHA256':hashlib.sha256(new.encode()).hexdigest()}
with (p/'source-checks.json').open('x') as f: json.dump(result,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(result))
