"""Grant-only fresh local package assembly; no compiler, remote call or GPU run."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT/'package'))
from binding_common import canonical, parse, require, same
from binding_inputs import snapshot
from target_contract import ARTIFACT, CASES, JOBS, REMOTE
from target_inputs import write_json, write_new

BUILD = ROOT.parent/'collective-native-allocation-build-20260916'
BUNDLE = BUILD/'runtime-bundle-1'
KNOWN_HOSTS = ROOT.parent/'owner-ssh-preflight-20260915/known_hosts'
KNOWN_SHA = '89a73d7ca9fe16a0c1aeb0fa6cfa640ff37a02d4a2d21114e7ad5fca089443ed'
ROOT_FILES = ('run_physical.py', 'prepare_copy.py', 'install_new_tree.py', 'collect_remote.py', 'validate_returned.py')


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--source-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); os.umask(0o077)
    manifest = snapshot(ROOT/'manifest.json', 1024**2)
    same(manifest['sha256'], args.source_sha256, 'reviewed source freeze')
    source_rows = parse(manifest['raw'])['files']
    for row in source_rows:
        item = snapshot(ROOT/row['path'], max(row['bytes'], 1), keep=False, empty=True)
        require(item['sha256'] == row['sha256'] and item['size_bytes'] == row['bytes'], 'Source freeze changed')
    bundle_raw = snapshot(BUNDLE/'bundle.json', 65_536)
    same(bundle_raw['sha256'], ARTIFACT['bundleSHA256'], 'approved native bundle')
    bundle = parse(bundle_raw['raw'])
    same(bundle['buildReceiptSHA256'], ARTIFACT['buildReceiptSHA256'], 'actual build receipt')
    receipt = snapshot(BUILD/'native-1/receipt.json', 1024**2)
    same(receipt['sha256'], ARTIFACT['buildReceiptSHA256'], 'retained build evidence')
    same(parse(receipt['raw'])['status'], 'passed', 'build completed')
    same(snapshot(KNOWN_HOSTS, 1024**2)['sha256'], KNOWN_SHA, 'existing SSH trust')
    output = args.output.absolute()
    require(output.parent == ROOT.parent and output.parent.resolve() == output.parent and output != ROOT, 'Fresh research sibling required')
    output.mkdir(mode=0o700)
    package = output/'package'; package.mkdir(mode=0o700)
    for row in source_rows:
        name = row['path']
        if not name.startswith('package/') and name not in ROOT_FILES: continue
        destination = output/name; destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        item = snapshot(ROOT/name, max(row['bytes'], 1), empty=True)
        same(item['sha256'], row['sha256'], 'source before copy')
        write_new(destination, item['raw'])
    for row in bundle['files']:
        source = BUNDLE/row['path']
        before = snapshot(source, max(row['bytes'], 1), keep=False, empty=True)
        require(before['sha256'] == row['sha256'] and before['size_bytes'] == row['bytes'], 'Native bundle changed')
        target = package/'bundle'/row['path']; target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with source.open('rb') as origin, target.open('xb') as destination:
            shutil.copyfileobj(origin, destination, length=1024**2)
        target.chmod(0o700 if row['path'] == 'CollectiveAllocationCheck' else 0o600)
        same(snapshot(target, max(row['bytes'], 1), keep=False, empty=True)['sha256'], row['sha256'], 'Copied artifact')
        same(snapshot(source, max(row['bytes'], 1), keep=False, empty=True), before, 'Native source remained unchanged')
    write_new(package/'bundle/bundle.json', bundle_raw['raw'])
    identity_raw = snapshot(BUNDLE/'source-identity.json', 1024**2)
    same(identity_raw['sha256'], ARTIFACT['sourceIdentitySHA256'], 'native source identity')
    identity = parse(identity_raw['raw'])
    cases = snapshot(BUILD/'native-1/cases.stdout', 65_537)
    same(cases['sha256'], identity['catalog']['stdoutSHA256'], 'actual compiled case list')
    expected = [dict(id=x['id'], byteCounts=[g['bytes'] for g in x['geometries']],
        primingByteCounts=[g['bytes'] for g in x['priming']], rounds=x['rounds'], failure=x['failure']) for x in CASES.values()]
    same(parse(cases['raw']), expected, 'complete fixed 35-case catalog')
    (package/'native-contract').mkdir(mode=0o700)
    write_new(package/'native-contract/cases.stdout', cases['raw'])
    rows = []
    for path in sorted(package.rglob('*')):
        if path.is_file():
            item = snapshot(path, max(path.stat().st_size, 1), keep=False, empty=True)
            rows.append(dict(path=str(path.relative_to(package)), bytes=item['size_bytes'], sha256=item['sha256']))
    write_json(package/'package.json', dict(schema='collective_allocation_supervisor_package_v1', files=rows))
    package_sha = snapshot(package/'package.json', 1024**2)['sha256']
    deployment = {'check/'+row['path']: dict(bytes=row['bytes'], sha256=row['sha256'],
        mode=0o700 if row['path']=='bundle/CollectiveAllocationCheck' else 0o600) for row in rows}
    deployment['check/package.json'] = dict(bytes=(package/'package.json').stat().st_size, sha256=package_sha, mode=0o600)
    write_json(output/'deployment.json', dict(schema='collective_allocation_copy_only_tree_v1', files=deployment))
    deployment_sha = snapshot(output/'deployment.json', 1024**2)['sha256']
    ssh = ['/usr/bin/ssh','-S','none','-T','-F','/dev/null','-i','/Users/developer/.ssh/id_ed25519_darkbloom_dev',
        '-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
        '-o','UserKnownHostsFile='+str(KNOWN_HOSTS),'-o','GlobalKnownHostsFile=/dev/null',
        '-o','ConnectTimeout=5','-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2',
        'developer@192.0.2.223']
    run_arguments = {case: ['/usr/bin/env','-i','PATH=/usr/bin:/bin:/usr/sbin:/sbin','HOME=/Users/gaj','LANG=C',
        'PYTHONNOUSERSITE=1','/usr/bin/python3','-B',REMOTE+'/run_target.py','--package-sha256',package_sha,'--fixture',case] for case in JOBS}
    commands = dict(knownHosts=dict(path=str(KNOWN_HOSTS),sha256=KNOWN_SHA), sshPrefix=ssh, remoteRoot=REMOTE,
        packageSHA256=package_sha, deploymentSHA256=deployment_sha, copyTimeoutSeconds=180, runTimeoutSeconds=135,
        copyProducer=[sys.executable,'-B',str(output/'prepare_copy.py'),'--deployment-sha256',deployment_sha],
        copyRemote=ssh+[shlex.join(['/usr/bin/python3','-B','-c',(output/'install_new_tree.py').read_text()])],
        runArguments=run_arguments)
    write_json(output/'ROOT-COMMANDS.json', commands)
    write_new(output/'source-freeze.json', manifest['raw'])
    write_json(output/'binding.json', dict(sourceManifestSHA256=args.source_sha256, bundleSHA256=ARTIFACT['bundleSHA256'],
        packageSHA256=package_sha, deploymentSHA256=deployment_sha, payloadCopied=True, nativeExecuted=False, remoteExecuted=False))
    for row in source_rows:
        same(snapshot(ROOT/row['path'], max(row['bytes'], 1), keep=False, empty=True)['sha256'], row['sha256'], 'Source after binding')
    final = []
    for path in sorted(output.rglob('*')):
        if path.is_file():
            item = snapshot(path, max(path.stat().st_size, 1), keep=False, empty=True)
            final.append(dict(path=str(path.relative_to(output)), bytes=item['size_bytes'], sha256=item['sha256']))
    write_json(output/'manifest.json', dict(schema='collective_allocation_bound_supervisor_v1', files=final))
    print(json.dumps(dict(output=str(output), packageSHA256=package_sha, deploymentSHA256=deployment_sha,
        bundleSHA256=ARTIFACT['bundleSHA256'], nativeExecuted=False, remoteExecuted=False)), flush=True)


if __name__ == '__main__': main()
