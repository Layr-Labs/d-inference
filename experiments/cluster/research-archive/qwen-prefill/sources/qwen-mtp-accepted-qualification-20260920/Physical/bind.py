"""Late-bind actual built files and actual tokenizer output; never launches anything."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import uuid

from common import BASE, OWNER, REFERENCE, REMOTE, canonical, replace, sha, verify_sources, write, write_json
import reference_template
import owner_template
sys.path.insert(0, str(BASE.parent / 'Compare'))
from accepted_rounds import POLICY, accepted_agreement
from audit_common import agreement, profile, request_context, exact
from audit_scope import AuditScope
from snapshot import snapshot


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    for name in ['build-receipt', 'bundle-directory', 'prompt-directory', 'output']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--build-receipt-sha256', required=True)
    parser.add_argument('--bundle-sha256', required=True)
    args = parser.parse_args(); verify_sources()
    if not args.output.is_absolute() or args.output != args.output.resolve() or args.output.exists():
        raise ValueError('Fresh canonical bound output required')
    if sha(args.build_receipt) != args.build_receipt_sha256 or sha(args.bundle_directory / 'bundle.json') != args.bundle_sha256:
        raise ValueError('Actual build/bundle pins differ')
    build = json.loads(args.build_receipt.read_bytes()); bundle = json.loads((args.bundle_directory / 'bundle.json').read_bytes())
    if build['schema'] != 'qwen_mtp_same_source_build_v1' or build['status'] != 'passed' or bundle['schema'] != 'qwen_mtp_accepted_native_bundle_v1' or bundle['buildReceiptSHA256'] != args.build_receipt_sha256:
        raise ValueError('Actual same-source build/package has not passed')
    products = {x['product']: x for x in build['products']}
    exact(set(products), {'darkbloom-cluster-worker', 'cluster-inference'}, 'Both built products')
    if len(bundle['files']) != 4 or {x['path'] for x in bundle['files']} != {'darkbloom-cluster-worker','cluster-inference','mlx.metallib','mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal'}:
        raise ValueError('Closed actual bundle membership')
    for row in bundle['files']:
        path = args.bundle_directory / row['path']
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Packaged native/resource bytes differ')
        if row['path'] in products:
            exact(row['sha256'], products[row['path']]['sha256'], 'Packaged actual build product')
    for key in ['sourceSnapshotSHA256', 'dependencySnapshotSHA256', 'acceptedManifestSHA256']:
        exact(bundle[key], build[key], 'Actual source composition')
    exact(build['acceptedManifestSHA256'], 'aa3b66fce361d1086bfaa979679ce25f844f6630630336805e3e1ea17460bbd4', 'Closed source')
    prompt = snapshot(args.prompt_directory / 'prompt.ids.json', 65536)
    pr = snapshot(args.prompt_directory / 'prompt-receipt.json', 65536)
    receipt = json.loads(pr['raw']); tokens = json.loads(prompt['raw'])
    if len(tokens) != 32 or any(type(x) is not int or not 0 <= x < 248320 for x in tokens) or prompt['raw'] != canonical(tokens):
        raise ValueError('Actual canonical P32 packet required')
    scope = AuditScope('registered_qwen35_9b', 32, 16, 8, 4)
    for key, wanted in dict(schema='qwen9b_protected_reference_tokenizer_packet_v1', manifestSHA256=scope.model['manifest'],
        artifactSHA256=scope.model['artifact'], tokenizerSHA256='87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4',
        tokenizerBytes=19989343, generatorSHA256=sha(REFERENCE / 'prepare_prompt.py'), tokenIDs=tokens,
        promptFileSHA256=prompt['sha256'], promptCount=32, modelOrGPUExecuted=False).items():
        exact(receipt.get(key), wanted, 'Actual tokenizer receipt ' + key)
    exact(receipt['allTokenIDs'][:32], tokens, 'Tokenizer prefix')
    control_pins = json.loads((BASE / 'control-pins.json').read_bytes())
    for row in control_pins['files']:
        path = Path(row['path'])
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Qualified owner/controller or trust bytes differ')
    request = str(uuid.uuid4()); context = request_context(prompt['raw'], request, scope)
    prior = json.loads((BASE / 'templates/owner/configuration/expected-agreement.json').read_bytes())
    expected = dict(schema='qwen_stage_generation_agreement_v1', rankCount=2,
        requestID=request, requestFingerprint=context['fingerprint'], profileFingerprint=profile(scope)['fingerprint'],
        sourceConfigurationSHA256=scope.model['configuration'], artifactAggregateSHA256=scope.model['artifact'],
        storageCommitmentSHA256=prior['storageCommitmentSHA256'], planFingerprint=scope.plan['fingerprint'],
        stageFingerprints=scope.plan['stages'], rankBuildSHA256=[products['darkbloom-cluster-worker']['sha256']]*2,
        numericalPolicySHA256=prior['numericalPolicySHA256'], mtpEnabled=False)
    off = dict(expected, membershipEpoch=str(uuid.uuid4())); agreement(off, context)
    on = dict(expected, membershipEpoch=str(uuid.uuid4()), mtpEnabled=True, mtpPolicySHA256=POLICY); accepted_agreement(on, context)
    binding = dict(schema='qwen_mtp_short_expected_v1', requestID=request, promptSHA256=prompt['sha256'],
        sourceSnapshotSHA256=build['sourceSnapshotSHA256'], dependencySnapshotSHA256=build['dependencySnapshotSHA256'],
        workerSHA256=products['darkbloom-cluster-worker']['sha256'], referenceSHA256=products['cluster-inference']['sha256'],
        bundleSHA256=args.bundle_sha256, buildReceiptSHA256=args.build_receipt_sha256,
        acceptedManifestSHA256=build['acceptedManifestSHA256'], offAgreement=off, depth1Agreement=on)
    args.output.mkdir(mode=0o700)
    write_json(args.output / 'expected.json', binding)
    write(args.output / 'prompt.ids.json', prompt['raw']); write(args.output / 'prompt-receipt.json', pr['raw'])
    reference_template.stage(args.output, binding, bundle, prompt['raw'])
    for mode in ['off', 'depth1']:
        owner_template.stage(args.output, binding, mode, tokens)
    installer = (BASE / 'templates/owner/install_new_tree.py').read_text()
    installer = replace(installer, "ROOTS = {'owner': Path('/Users/developer/DarkbloomDev/owner-native-mtp-probe-clean-20260915')}", 'ROOTS = {\'experiment\': Path(' + repr(REMOTE) + ')}')
    installer = replace(installer, 'import tarfile', 'import tarfile\nimport signal\nsignal.alarm(180)')
    installer = replace(installer, "(ROOTS['owner'] / 'evidence').mkdir(mode=0o700)", "for mode in ('off', 'depth1'): (ROOTS['experiment'] / mode / 'evidence').mkdir(mode=0o700)")
    # Installation observes the canonical journal only. It does not acquire or
    # clear it, and the actual owner retains all admission/lease authority.
    write(args.output / 'install_new_tree.py', installer.encode())
    deployments = []
    controls = json.loads((BASE / 'templates/owner/owner-bundle.json').read_bytes())['files']
    for rank in [0, 1]:
        files = {}
        def add(name, source, mode=0o600):
            if 'experiment/' + name in files:
                raise ValueError('Duplicate deployment path')
            files['experiment/' + name] = dict(source=str(source), bytes=source.stat().st_size, sha256=sha(source), mode=mode)
        for row in bundle['files']:
            add('native/' + row['path'], args.bundle_directory / row['path'], 0o700 if row['path'] in products else 0o600)
        add('native/bundle.json', args.bundle_directory / 'bundle.json')
        for path in sorted((args.output / 'reference/package').rglob('*')):
            if path.is_file(): add('reference/package/' + str(path.relative_to(args.output / 'reference/package')), path)
        for name in ['prompt.ids.json', 'job.json']:
            add('reference/inputs/' + name, args.output / 'reference/inputs' / name)
        for mode in ['off', 'depth1']:
            directory = args.output / mode
            for control in controls:
                add(mode + '/' + control['path'], OWNER / 'controls' / control['path'], 0o700)
            for name in ['monitor.py','reference_resources.py','stage_checks/__init__.py','stage_checks/common.py','collect_owner.py']:
                add(mode + '/' + name, directory / name)
            add(mode + '/matrix.json', directory / 'configuration/matrix.json')
            add(mode + '/owner.json', directory / ('configuration/owner-rank' + str(rank) + '.json'))
        if len(files) > 100 or sum(x['bytes'] for x in files.values()) >= 300_000_000:
            raise ValueError('Qualified create-only deployment envelope exceeded')
        write_json(args.output / ('deployment-rank' + str(rank) + '.json'), dict(schema='mtp_probe_copy_only_tree_v1', files=files))
        deployments.append(dict(rank=rank, files=len(files), bytes=sum(x['bytes'] for x in files.values())))
    write_json(args.output / 'binding-receipt.json', dict(schema='qwen_mtp_short_binding_receipt_v1',
        expectedSHA256=sha(args.output / 'expected.json'), promptReceiptSHA256=pr['sha256'],
        physicalSourceManifestSHA256=sha(BASE / 'manifest.json'), buildReceiptSHA256=args.build_receipt_sha256,
        nativeBundleSHA256=args.bundle_sha256, deployments=deployments, remoteRoot=REMOTE,
        nativeExecuted=False, copiedToRemote=False, outputIDsInvented=False,
        files=[dict(path=str(p.relative_to(args.output)), bytes=p.stat().st_size, sha256=sha(p))
               for p in sorted(args.output.rglob('*')) if p.is_file()]))
    verify_sources()
    print(json.dumps(dict(output=str(args.output), bindingReceiptSHA256=sha(args.output / 'binding-receipt.json')), sort_keys=True))


if __name__ == '__main__':
    main()
