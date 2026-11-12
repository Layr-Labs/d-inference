"""Root-run create-only small retry preparation. No child/model/network operations."""
import difflib
import hashlib
import json
import os
from pathlib import Path
from retry_inputs import (BASE, OLD, EXPERIMENT, PREPARED, INPUTS, REFERENCE, OLD_LAUNCH,
    NEW_LAUNCH, OLD_RUN, NEW_RUN, read, canonical, pin, require, verify_source, expected_packet)


def save(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open('xb') as stream:
        stream.write(value if isinstance(value, bytes) else canonical(value))


def replace(text, before, after, count):
    require(text.count(before) == count, 'Unexpected source substitution count: '+before)
    return text.replace(before, after)


def main():
    verify_source()
    job, request = expected_packet()
    require(not PREPARED.exists() and not PREPARED.is_symlink(), 'Refuse existing retry preparation')
    PREPARED.mkdir(mode=0o700)
    plan = json.loads(read(EXPERIMENT/'inputs-1/case-plan.json'))
    plan['referenceJobSHA256'] = hashlib.sha256(canonical(job)).hexdigest()
    for name, value in [('reference-job.json',job), ('request.json',request), ('case-plan.json',plan),
                        ('prompt.ids.json',read(EXPERIMENT/'inputs-1/prompt.ids.json'))]:
        save(INPUTS/name, value)
    prior_package = json.loads(read(OLD/'package/manifest.json'))
    require(len(prior_package['files']) == 64 and sum(x['bytes'] for x in prior_package['files']) <= 4*1024**2,
            'Expected bounded original launcher closure')
    members = []
    for row in prior_package['files']:
        name = row['path']
        require(not Path(name).is_absolute() and '..' not in Path(name).parts, 'Unsafe inherited package path')
        raw = read(OLD/'package'/name)
        require(dict(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()) == {k: row[k] for k in ('bytes','sha256')},
                'Inherited package member changed')
        save(REFERENCE/'package'/name, canonical(job) if name == 'example-job.json' else raw)
        members.append(dict(path=name,**pin(REFERENCE/'package'/name)))
    save(REFERENCE/'package/manifest.json',dict(prior_package,files=members))
    old_package_sha, new_package_sha = pin(OLD/'package/manifest.json')['sha256'], pin(REFERENCE/'package/manifest.json')['sha256']
    old_job_sha, new_job_sha = pin(OLD/'package/example-job.json')['sha256'], pin(REFERENCE/'package/example-job.json')['sha256']
    original_runner = read(OLD/'run_physical.py').decode()
    runner = replace(original_runner, OLD_LAUNCH, NEW_LAUNCH, 1)
    runner = replace(runner, OLD_RUN, NEW_RUN, 1)
    runner = replace(runner, old_package_sha, new_package_sha, 2)
    runner = replace(runner, old_job_sha, new_job_sha, 1)
    original_installer = read(OLD/'install_new_tree.py').decode()
    installer = replace(original_installer, OLD_LAUNCH, NEW_LAUNCH, 1)
    save(REFERENCE/'run_physical.py',runner.encode())
    save(REFERENCE/'install_new_tree.py',installer.encode())
    save(REFERENCE/'owned_process.py',read(OLD/'owned_process.py'))
    deployment = dict(schema='cut16_reference_copy_only_tree_v1', files={})
    for path in sorted((REFERENCE/'package').rglob('*')):
        if path.is_file():
            deployment['files']['owner/'+str(path.relative_to(REFERENCE/'package'))] = dict(source=str(path),**pin(path),mode=0o600)
    require(len(deployment['files']) == 65, 'Expected 65 copy-only files')
    save(REFERENCE/'deployment.json',deployment)
    patch = ''.join(difflib.unified_diff(original_runner.splitlines(True),runner.splitlines(True),fromfile='prior/run_physical.py',tofile='retry/run_physical.py'))
    patch += ''.join(difflib.unified_diff(original_installer.splitlines(True),installer.splitlines(True),fromfile='prior/install_new_tree.py',tofile='retry/install_new_tree.py'))
    save(REFERENCE/'binding.patch',patch.encode())
    save(REFERENCE/'lineage.json',dict(schema='c256_reference_retry_paths_v1',priorSource=pin(OLD/'manifest.json'),
        retrySource=pin(BASE/'manifest.json'),job=pin(INPUTS/'reference-job.json'),package=pin(REFERENCE/'package/manifest.json'),
        sameRequestPromptModelNativePlanResources=True,onlyJobFieldsChanged=['prompt_file','run_dir'],
        nativeOrRemoteExecuted=False,priorFailureRetained=True,successNotPresumed=True))
    files = {str(p.relative_to(REFERENCE)):pin(p) for p in sorted(REFERENCE.rglob('*')) if p.is_file()}
    save(REFERENCE/'manifest.json',dict(schema='private_c256_reference_retry_preparation_v1',files=files))
    files = {str(p.relative_to(PREPARED)):pin(p) for p in sorted(PREPARED.rglob('*')) if p.is_file()}
    save(PREPARED/'manifest.json',dict(schema='c256_reference_retry_inputs_v1',files=files))
    verify_source()
    print(json.dumps(dict(prepared=str(PREPARED),manifest=pin(PREPARED/'manifest.json'),
        referenceManifest=pin(REFERENCE/'manifest.json'),job=pin(INPUTS/'reference-job.json'),nativeOrRemoteExecuted=False),sort_keys=True))


if __name__ == '__main__':
    os.umask(0o077)
    main()
