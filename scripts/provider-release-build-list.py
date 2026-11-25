#!/usr/bin/env python3
"""Prepare, sign, check and publish the signed provider-build list
(provider_release_build_list.py).

  prepare  compute the next list for a change (release, republish, revoke or
           floor) from the newest published list, and write the unsigned
           document, its SHA-256 and the exact diff for the signer to check
  sign     check a prepared document again from independent inputs, then sign
           exactly the document with that SHA-256
  publish  check a signed list against the pinned keys, the prepared SHA-256
           and the newest published list, then upload the numbered list
           without replacing one, and only then the fixed name
  check    the published list's state for the daily check: current, due to be
           re-signed (4 days old) or escalated (2 days or less left)
  verify   check a list against pinned keys
  dry-run-seed  a current list for a dry run, signed with the test key, and a
           key file that pins the test key

A dry run (--dry-run) takes the current list from the prepared directory
instead of the published release, accepts the RFC 8032 test key beside the
pinned keys, and publishes nothing. Until a signing key is configured the only
signer is that test key, whose lists no pinned key verifies, so nothing this
script signs can be published.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

import provider_release_artifact as artifact
import provider_release_build_list as lists

PREPARED_DOCUMENT = lists.DOCUMENT_NAME
PREPARED_CURRENT = 'current.jws'
PREPARED_CHANGE = 'change.json'


def annotate(level, message):
    print(f'::{level}::{message}')


def write_summary(lines):
    print('\n'.join(lines))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as stream:
            stream.write('\n'.join(lines) + '\n\n')


def write_output(name, value):
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with open(output, 'a') as stream:
            stream.write(f'{name}={value}\n')


def utc(seconds):
    return time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime(seconds))


def describe(title, current, document):
    return [f'### {title}', '',
            f'- Sequence {document["seq"]}, issued {utc(document["issued_at"])}, expires '
            f'{utc(document["expires_at"])}, min_version {document["min_version"]}',
            f'- Document SHA-256: `{lists.document_sha256(document)}`', '', '```',
            *lists.diff_lines(current, document), '```']


# Inputs.

def payload_build(publication):
    """The build of this run's digest-checked publication artifact (a production release)."""
    env = os.environ
    payload = artifact.checked_payload(Path(publication), env['RELEASE_PAYLOAD_SHA256'],
                                       env['RELEASE_PROVENANCE_SHA256'], env['RELEASE_SOURCE_SHA'],
                                       env['RELEASE_SIGNING_RUN_ID'])
    if payload.get('require_app_attest_qualification') is not True:
        raise ValueError('Only a production release adds a build to the provider-build list')
    if payload['version'] != env['VERSION']:
        raise ValueError('The release payload names another version')
    return lists.build_entry(payload)


def change_of(args, document=None):
    """The change, from this command's own inputs. A release's build comes from
    the digest-checked publication artifact; without one (a signer off CI) the
    prepared document's added build is used, and `sign` recomputes its
    CodeDirectory hash from the published bundle."""
    operation = args.operation
    for name, owner in (('versions', 'revoke'), ('min_version', 'floor'), ('version', 'release')):
        if getattr(args, name, None) and operation != owner:
            raise ValueError(f'--{name.replace("_", "-")} belongs to {owner}, not {operation}')
    if operation == 'release':
        if getattr(args, 'publication', None) is not None:
            return {'operation': 'release', 'build': payload_build(args.publication)}
        if document is None:
            raise ValueError('A release change needs the publication artifact (--publication)')
        build = next((entry for entry in document['builds'] if entry['version'] == args.version), None)
        if build is None:
            raise ValueError(f'The prepared list does not list version {args.version}')
        return {'operation': 'release', 'build': build}
    if operation == 'revoke':
        return {'operation': 'revoke', 'versions': [version.strip() for version in args.versions.split(',')]}
    if operation == 'floor':
        return {'operation': 'floor', 'min_version': args.min_version}
    return {'operation': 'republish'}


def published_state(args, openssl, now):
    """(current jws or None, current document or None, history) of the published release."""
    found = lists.published_lists(args.release, os.environ['GITHUB_REPOSITORY'])
    current, history = lists.newest_and_history(found, lists.load_keys(args.keys), openssl, now)
    return (found[-1][1] if found else None), current, history


def dry_run_keys(args):
    """A dry run accepts the RFC 8032 test key beside the pinned keys."""
    return [(lists.key_id(lists.TEST_PUBLIC_KEY), lists.TEST_PUBLIC_KEY)] + lists.load_keys(args.keys)


def prepared_state(directory, keys, openssl, now):
    """The dry run's current list: the one in `directory`."""
    path = Path(directory) / PREPARED_CURRENT
    if not path.exists():
        return None, None, []
    jws = lists.read_list(path)
    current = lists.verify_list(jws, keys, openssl, now, allow_expired=True)
    return jws, current, [current]


def state_for(args, openssl, now):
    """The current list and history a signer or publisher checks against: the
    published release, which must still hold the list the document was prepared
    from; in a dry run, the prepared directory's."""
    if args.dry_run:
        return prepared_state(args.prepared, dry_run_keys(args), openssl, now)
    jws, current, history = published_state(args, openssl, now)
    prepared_current = Path(args.prepared) / PREPARED_CURRENT
    prepared_jws = lists.read_list(prepared_current) if prepared_current.exists() else None
    if jws != prepared_jws:
        raise ValueError('The newest published list is not the one the document was prepared from; prepare again')
    return jws, current, history


def prepared_document(args):
    document = lists.parse_document((Path(args.prepared) / PREPARED_DOCUMENT).read_bytes())
    if lists.document_sha256(document) != args.document_sha256:
        raise ValueError('The prepared document is not the one with the given SHA-256')
    return document


# Operations.

def prepare(args, openssl, now):
    output = Path(args.output)
    if args.seed is not None:
        jws, current, history = prepared_state(args.seed, dry_run_keys(args), openssl, now)
    else:
        jws, current, history = published_state(args, openssl, now)
    change = change_of(args)
    document = lists.successor(current, change, now, history)
    output.mkdir(parents=True, exist_ok=False)
    (output / PREPARED_DOCUMENT).write_bytes(lists.document_bytes(document))
    (output / PREPARED_CHANGE).write_text(lists.change_text(change) + '\n')
    if jws is not None:
        (output / PREPARED_CURRENT).write_text(jws)
    warning = lists.size_warning(document)
    if warning:
        annotate('warning', warning)
    write_summary(describe(f'Prepared provider build list ({change["operation"]}; unsigned)', current, document))
    write_output('document_sha256', lists.document_sha256(document))


def sign(args, openssl, now):
    signer = lists.signer(args.signer, openssl)
    document = prepared_document(args)
    _, current, history = state_for(args, openssl, now)
    change = change_of(args, document)
    lists.check_successor(current, document, change, history)
    lists.check_fresh(document, now)
    if change['operation'] == 'release':
        if args.bundle is not None:
            recomputed = lists.published_build(args.bundle, change['build']['version'])
            if recomputed != (change['build']['code_directory_hash'], change['build']['binary_sha256']):
                raise ValueError('The published bundle\'s CodeDirectory or binary hash differs from the list entry')
        elif signer.name != lists.TestSigner.name:
            raise ValueError('Signing a release list recomputes the build from the published bundle (--bundle)')
    jws = lists.sign_list(document, signer)
    kid = lists.key_id(signer.public_key)
    signed = lists.verify_list(jws, [(kid, signer.public_key)], openssl, now)
    lists.check_successor(current, signed, change, history)
    lists.write_list(args.output, signed, jws)
    title = ('Signed provider build list (dry run: RFC 8032 test key, never published)'
             if signer.name == lists.TestSigner.name else 'Signed provider build list')
    write_summary(describe(title, current, signed) + ['', f'- Key ID: `{kid}`'])


def publish(args, openssl, now, run=subprocess.run):
    directory = Path(args.list_dir)
    jws = lists.read_list(directory / lists.LIST_NAME)
    keys = dry_run_keys(args) if args.dry_run else lists.load_keys(args.keys)
    if not args.dry_run and any(public == lists.TEST_PUBLIC_KEY for _, public in keys):
        raise ValueError('The RFC 8032 test key never publishes a list')
    document = lists.verify_list(jws, keys, openssl, now)
    if lists.document_sha256(document) != args.document_sha256:
        raise ValueError('The signed list is not the prepared document with the given SHA-256')
    numbered = directory / lists.sequence_name(document['seq'])
    if lists.read_list(numbered) != jws:
        raise ValueError('The numbered list differs from the list')
    _, current, history = state_for(args, openssl, now)
    lists.check_successor(current, document, change_of(args, document), history)
    lists.check_fresh(document, now)
    repository = os.environ['GITHUB_REPOSITORY']
    # The numbered list first, without --clobber: a sequence number is
    # published once, so two publications can't both take it. Then the fixed
    # name that verifiers fetch.
    plan = [['gh', 'release', 'upload', args.release, str(numbered), '--repo', repository],
            ['gh', 'release', 'upload', args.release, str(directory / lists.LIST_NAME), '--repo', repository,
             '--clobber']]
    if args.dry_run:
        write_summary(['### Publication plan (dry run; nothing is uploaded)', '', '```',
                       *(' '.join(command) for command in plan), '```'])
        return
    for command in plan:
        run(command, check=True, timeout=300)
    with tempfile.TemporaryDirectory(prefix='provider-build-list-') as check:
        run(['gh', 'release', 'download', args.release, '--repo', repository, '--pattern', lists.LIST_NAME,
             '--dir', check], check=True, timeout=120)
        if lists.read_list(Path(check) / lists.LIST_NAME) != jws:
            raise RuntimeError('The published list differs from the signed list')
    write_summary([f'Published provider build list sequence {document["seq"]} on release {args.release}'])


def check(args, openssl, now):
    keys = lists.load_keys(args.keys)
    if not keys:
        annotate('notice', 'No provider-release key is pinned yet, so no list is published; nothing to check')
        write_output('state', 'none')
        return 0
    data = lists.fetch(args.url)
    if data is None:
        state, message = 'escalate', f'No provider build list is published at {args.url}'
    else:
        try:
            document = lists.verify_list(data.decode('ascii'), keys, openssl, now, allow_expired=True)
            state, message = lists.schedule_state(document, now)
        except ValueError as error:
            state, message = 'escalate', f'The published provider build list does not verify: {error}'
    write_output('state', state)
    write_output('message', message)
    annotate({'ok': 'notice', 'due': 'notice', 'escalate': 'error'}[state], message)
    return 1 if state == 'escalate' else 0


def verify(args, openssl, now):
    document = lists.verify_list(lists.read_list(args.list), lists.load_keys(args.keys), openssl, now,
                                 minimum_seq=args.minimum_seq)
    write_summary(describe('Verified provider build list', None, document))


def dry_run_seed(args, openssl, now):
    document = json.loads(lists.DRY_RUN_DOCUMENT.read_text())
    signer = lists.TestSigner(openssl)
    output = Path(args.output)
    lists.write_list(output, document, lists.sign_list(document, signer))
    shutil.copyfile(output / lists.LIST_NAME, output / PREPARED_CURRENT)
    write_summary(describe('Dry-run current list (RFC 8032 test key)', None, document))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)

    def change_arguments(command):
        command.add_argument('operation', choices=lists.OPERATIONS)
        command.add_argument('--publication', type=Path,
                             help="release: this run's downloaded publication artifact")
        command.add_argument('--version', help='release, off CI: the released version')
        command.add_argument('--versions', help='revoke: the versions to revoke, comma-separated')
        command.add_argument('--min-version', help='floor: the new min_version')

    def state_arguments(command):
        command.add_argument('--release', default='provider-builds', help='the release that holds the lists')
        command.add_argument('--keys', type=Path, default=lists.PINNED_KEYS, help='pinned provider-release keys')

    command = commands.add_parser('prepare')
    change_arguments(command)
    state_arguments(command)
    command.add_argument('--seed', type=Path, help='dry run: start from this dry-run-seed directory')
    command.add_argument('--output', type=Path, required=True)

    for name in ('sign', 'publish'):
        command = commands.add_parser(name)
        change_arguments(command)
        state_arguments(command)
        command.add_argument('--prepared', type=Path, required=True, help="prepare's output directory")
        command.add_argument('--document-sha256', required=True, help="the prepared document's SHA-256")
        command.add_argument('--dry-run', action='store_true')
        if name == 'sign':
            command.add_argument('--signer', required=True)
            command.add_argument('--bundle', type=Path, help='release: the published release bundle')
            command.add_argument('--output', type=Path, required=True)
        else:
            command.add_argument('--list-dir', type=Path, required=True, help="sign's output directory")

    command = commands.add_parser('check')
    command.add_argument('--url', required=True)
    command.add_argument('--keys', type=Path, default=lists.PINNED_KEYS)

    command = commands.add_parser('verify')
    command.add_argument('--list', type=Path, required=True)
    command.add_argument('--keys', type=Path, default=lists.PINNED_KEYS)
    command.add_argument('--minimum-seq', type=int, default=1)

    command = commands.add_parser('dry-run-seed')
    command.add_argument('--output', type=Path, required=True)

    args = parser.parse_args(argv)
    operation = {'prepare': prepare, 'sign': sign, 'publish': publish, 'check': check, 'verify': verify,
                 'dry-run-seed': dry_run_seed}[args.command]
    return operation(args, lists.OpenSSL(), time.time()) or 0


if __name__ == '__main__':
    sys.exit(main())
