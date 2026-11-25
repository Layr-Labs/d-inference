"""Root-owned create-only small-tree copy and a separate read-only preflight."""
import argparse
import json
from pathlib import Path
import shlex
from installation_inputs import BASE, REFERENCE, verify, bound_inputs, prepare_tree
from binding_common import parse, require, same
from binding_inputs import snapshot
from reference_inputs import write_json
from local_process import execute
from parent_settings import SSH


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=['install', 'preflight'])
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--binding-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    verify()
    binding = bound_inputs(args.inputs, args.binding_sha256)
    trust = parse((REFERENCE / 'trust.json').read_bytes())
    same(snapshot(Path(trust['path']), 65536)['sha256'], trust['sha256'], 'Strict known-hosts pin')
    require(args.output.is_absolute() and args.output.parent.resolve() == args.output.parent, 'Canonical fresh output')
    args.output.mkdir(mode=0o700)
    if args.action == 'install':
        deployment_sha, manifest = prepare_tree(args.inputs, binding, args.output)
        code = execute(['python3', '-B', str(BASE / 'prepare_copy.py'), '--bound', str(args.output),
                        '--deployment-sha256', deployment_sha], args.output, 'archive', 30, cap=3*1024**2)
        require(code == 0 and (args.output / 'archive.stderr').stat().st_size == 0, 'Small archive preparation failed')
        command = shlex.join(['/usr/bin/python3', '-B', '-c', (BASE / 'install_new_tree.py').read_text()])
        with (args.output / 'archive.stdout').open('rb') as stream:
            code = execute(SSH + ['darkbloom-48', command], args.output, 'install', 60, stdin=stream, cap=1024**2)
        require(code == 0 and (args.output / 'install.stderr').stat().st_size == 0, 'Create-only installation failed')
        result = parse(snapshot(args.output / 'install.stdout', 65536)['raw'])
        same(result['schema'], 'qwen9b_reference_copy_only_verification_v1', 'Installer receipt schema')
        same(result['manifestSHA256'], deployment_sha, 'Exact transferred manifest')
        expected = {name: {k: row[k] for k in ('bytes', 'sha256')} for name, row in manifest['files'].items()}
        same(result['verified'], expected, 'All24 transferred bytes rehashed')
        require(result['modelOrOwnerLaunched'] is False and result['existingInputsModified'] is False, 'Copy-only receipt')
    else:
        command = shlex.join(['/usr/bin/python3', '-B', '-c', (BASE / 'preflight_reference.py').read_text(),
            '--job-sha256', binding['jobSHA256'], '--launcher-sha256', binding['launcherSHA256']])
        code = execute(SSH + ['darkbloom-48', command], args.output, 'preflight', 60, cap=1024**2)
        require(code == 0 and (args.output / 'preflight.stderr').stat().st_size == 0, 'Read-only preflight failed')
        result = parse(snapshot(args.output / 'preflight.stdout', 65536)['raw'])
        same(result['schema'], 'qwen9b_reference_installed_preflight_v1', 'Preflight receipt schema')
        for key in ('jobSHA256', 'launcherSHA256', 'promptSHA256', 'nativeSHA256'):
            same(result[key], binding[key], 'Actual preflight binding ' + key)
        require(result['nativeLaunched'] is False and result['journalMutated'] is False, 'Read-only preflight receipt')
    same(bound_inputs(args.inputs, args.binding_sha256), binding, 'Input packet changed during operation')
    verify()
    write_json(args.output / 'receipt.json', dict(action=args.action, status='passed',
        wrapperManifestSHA256=snapshot(BASE / 'manifest.json', 1024**2)['sha256'],
        bindingSHA256=args.binding_sha256, result=result, nativeLaunched=False, modelCopied=False))
    print(json.dumps(dict(receipt=str(args.output / 'receipt.json'), sha256=snapshot(args.output / 'receipt.json', 1024**2)['sha256'])))


if __name__ == '__main__':
    main()
