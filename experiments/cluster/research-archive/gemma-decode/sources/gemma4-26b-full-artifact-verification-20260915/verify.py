"""Read-only bounded streaming verification of the retained registered Gemma artifact."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import sys
import time

BASE = Path(__file__).resolve().parent
ARTIFACT = BASE.parent / 'gemma4-26b-distributed-artifact-20260915/manifest.json'
MANIFEST_SHA = 'c1fefb1fa593fa3ca83e72a1124fb3afca10a59eed272c7ac2ac4a57f8018dfd'
MODEL = Path('/Users/developer/.cache/huggingface/hub/models--gemma-4-26b-qat-4bit/snapshots/local')
SOURCE = Path('/Users/developer/DarkbloomDev/d-inference/provider-swift/Sources/ProviderCoreFoundation')
BLOCK = 4 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key')
        result[key] = value
    return result


def identity(info):
    return dict(device=info.st_dev, inode=info.st_ino, bytes=info.st_size,
                mtimeNs=info.st_mtime_ns, ctimeNs=info.st_ctime_ns,
                uid=info.st_uid, mode=info.st_mode, links=info.st_nlink)


def deadline(signum, frame):
    raise TimeoutError('Streaming verification exceeded 120 seconds')


def main():
    require(sys.platform == 'darwin', 'F_NOCACHE recipe is Darwin-only')
    raw = ARTIFACT.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == MANIFEST_SHA, 'Registered manifest changed')
    value = json.loads(raw, object_pairs_hook=unique_object)
    require(value['schema_version'] == 1 and value['model_id'] == 'gemma-4-26b-qat-4bit', 'Wrong artifact')
    entries = sorted(value['files'], key=lambda row: row['path'])
    require(len(entries) == value['file_count'] == 10, 'Wrong file count')
    require(len({row['path'] for row in entries}) == 10, 'Repeated path')
    for row in entries:
        name = row['path']
        require(type(name) is str and name not in ('', '.', '..') and '/' not in name and '\\' not in name,
                'Expected a flat relative artifact path')
        require(type(row['size_bytes']) is int and 0 < row['size_bytes'] <= 6_000_000_000, 'Invalid size')
        require(type(row['sha256']) is str and len(row['sha256']) == 64
                and bytes.fromhex(row['sha256']).hex() == row['sha256'], 'Invalid digest')
    require(sum(row['size_bytes'] for row in entries) == value['total_size_bytes'] == 15_641_239_295,
            'Aggregate size differs')
    require(MODEL.resolve() == MODEL, 'Snapshot path traverses a symbolic link')
    output = BASE / 'run-1'
    output.mkdir(mode=0o700)
    record = dict(schema='gemma4_full_artifact_verification_v1', passed=False, manifestSHA256=MANIFEST_SHA,
                  modelDirectory=str(MODEL), startedUnix=time.time(), blockBytes=BLOCK,
                  deadlineSeconds=120, nativeOrModelExecuted=False, artifactMutationRequested=False,
                  aggregateRule='SHA256(concatenated raw file SHA256 digests sorted by relative POSIX path)',
                  verifierSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), files=[])
    record['aggregateImplementationSources'] = [
        dict(path=str(SOURCE / name), sha256=hashlib.sha256((SOURCE / name).read_bytes()).hexdigest())
        for name in ['ManifestBuilder.swift', 'WeightHasher.swift']]
    started = time.monotonic()
    directory = None
    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(120)
    try:
        directory = os.open(MODEL, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        folder = os.fstat(directory)
        require(stat.S_ISDIR(folder.st_mode) and folder.st_uid == os.geteuid(), 'Unsafe snapshot directory')
        record['directoryIdentity'] = identity(folder)
        aggregator = hashlib.sha256()
        with (output / 'files.jsonl').open('x') as log:
            for row in entries:
                file_started = time.monotonic()
                descriptor = os.open(row['path'], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                try:
                    before = os.fstat(descriptor)
                    require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                            and before.st_size == row['size_bytes'], 'Wrong file type/owner/size: ' + row['path'])
                    require(identity(before) == identity(os.stat(row['path'], dir_fd=directory, follow_symlinks=False)),
                            'Named file differs from opened file')
                    # Darwin F_NOCACHE=48. Requires success; never silently falls back to cached reads.
                    result = fcntl.fcntl(descriptor, 48, 1)
                    require(result == 0, 'F_NOCACHE refused')
                    digest = hashlib.sha256()
                    remaining = before.st_size
                    while remaining:
                        block = os.read(descriptor, min(BLOCK, remaining))
                        require(bool(block), 'Truncated artifact')
                        remaining -= len(block)
                        digest.update(block)
                    require(os.read(descriptor, 1) == b'', 'Artifact grew during read')
                    require(identity(before) == identity(os.fstat(descriptor))
                            == identity(os.stat(row['path'], dir_fd=directory, follow_symlinks=False)),
                            'Artifact identity changed during hashing')
                    require(digest.hexdigest() == row['sha256'], 'Payload digest mismatch: ' + row['path'])
                    aggregator.update(digest.digest())
                    observed = dict(path=row['path'], sha256=digest.hexdigest(), identity=identity(before),
                                    noCacheRequested=True, elapsedSeconds=time.monotonic() - file_started)
                    record['files'].append(observed)
                    log.write(json.dumps(observed, sort_keys=True) + '\n')
                    log.flush()
                    print(json.dumps(dict(verified=row['path'], bytes=before.st_size)), flush=True)
                finally:
                    os.close(descriptor)
        for row in record['files']:
            require(identity(os.stat(row['path'], dir_fd=directory, follow_symlinks=False)) == row['identity'],
                    'Artifact changed after earlier file verification')
        named = os.lstat(MODEL)
        require((folder.st_dev, folder.st_ino) == (named.st_dev, named.st_ino), 'Snapshot replaced')
        require(hashlib.sha256(ARTIFACT.read_bytes()).hexdigest() == MANIFEST_SHA, 'Manifest changed during read')
        record['aggregateSHA256'] = aggregator.hexdigest()
        require(record['aggregateSHA256'] == value['aggregate_sha256'], 'Aggregate digest mismatch')
        record.update(passed=True, verifiedFiles=10, verifiedBytes=value['total_size_bytes'],
                      identityChecksPassed=True)
    except BaseException as error:
        record['error'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        signal.alarm(0)
        if directory is not None:
            os.close(directory)
        record['elapsedSeconds'] = time.monotonic() - started
        (output / 'verification.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print(json.dumps(dict(passed=True, verifiedFiles=10, verifiedBytes=record['verifiedBytes'],
                         aggregateSHA256=record['aggregateSHA256'], elapsedSeconds=record['elapsedSeconds'])))


if __name__ == '__main__':
    main()
