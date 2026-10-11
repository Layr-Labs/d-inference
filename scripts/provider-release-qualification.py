#!/usr/bin/env python3
"""Validate retained signed release candidates on macOS 26 or 27."""
import argparse
import os
from pathlib import Path

from provider_release_qualification.contract import candidate
from provider_release_qualification.download import download
from provider_release_qualification.macos import check_macos


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    fetch = commands.add_parser('download')
    fetch.add_argument('--artifact-id', required=True)
    fetch.add_argument('--artifact-digest', required=True)
    fetch.add_argument('--run-id', required=True)
    fetch.add_argument('--output', type=Path, required=True)
    check = commands.add_parser('check')
    check.add_argument('--directory', type=Path, required=True)
    check.add_argument('--output', type=Path, required=True)
    check.add_argument('--macos-major', type=int, choices=[26, 27], required=True)
    args = parser.parse_args()
    if args.command == 'download':
        download(os.environ['GITHUB_REPOSITORY'], args.artifact_id, args.artifact_digest, args.run_id, args.output)
        return
    _, build = candidate(args.directory, os.environ['RELEASE_PAYLOAD_SHA256'],
                         os.environ['RELEASE_PROVENANCE_SHA256'], os.environ['RELEASE_SOURCE_SHA'],
                         os.environ['RELEASE_SIGNING_RUN_ID'])
    check_macos(args.directory, build, args.output, args.macos_major, os.environ['GITHUB_RUN_ID'],
                int(os.environ['GITHUB_RUN_ATTEMPT']), os.environ['RELEASE_QUALIFICATION_POLICY'])


if __name__ == '__main__':
    main()
