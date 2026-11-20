#!/usr/bin/env python3
"""CPU replay of supplied short-parity/runtime evidence; no native launch or admission."""
import argparse
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from binding_common import parse, require, same
from binding_inputs import Inputs
from binding_manifests import bundle_manifest, source_manifest
from binding_observations import replay_observations
from binding_oracle import load, replay, tokens
from binding_parent import schema, validate_parent
from binding_pins import PRIVATE_SOURCES
from binding_result import result
from runtime_binding import validate_runtime_pair


def audit_packet(path):
    inputs = Inputs(path)
    oracle, contract = load()
    profile, core = inputs.packet['profile'], inputs.core
    require(type(profile) is str and profile in contract.PROFILES, 'Unsupported registered profile')
    require(core['retained_metadata']['sha256'] == oracle.FIXTURE_SHA, 'Wrong retained registered metadata')
    source = parse(core['source_manifest']['raw'])
    sources = source_manifest(source)
    bundle = bundle_manifest(parse(core['bundle_manifest']['raw']), sources)
    token_metadata = tokens(core)
    outer = contract.validate_result(core['stdout']['raw'], profile, token_metadata)
    parent = parse(core['parent']['raw'])
    joined = validate_parent(parent, profile, core, source, sources, bundle, outer, token_metadata, contract)
    records = [contract.decode(row) for row in core['stdout']['raw'].split(b'\n')[:-1]]
    runtime = validate_runtime_pair(records[0]['runtime'], records[1]['pair']['runtime'],
                                    joined['nativePID'], joined['allowedBundlePaths'])
    require(runtime['executablePathReported'], 'A complete execution binding needs reported executable path evidence')
    observations = replay_observations(parent, contract, joined['executable'])
    counts = dict(source=inputs.members('source', sources), bundle=inputs.members('bundle', bundle),
                  private=inputs.members('private', PRIVATE_SOURCES))
    numerical = replay(core, profile, token_metadata)
    same(parse(core['numerical']['raw']), numerical, 'Saved numerical result versus fresh replay')
    same(numerical['passed'], True, 'fresh numerical result')
    for name in ('recordedRequestFingerprint', 'referenceAdmissionFingerprint', 'baselineEvidenceSHA256'):
        same(numerical[name], parent[name], 'numerical parent ' + name)
    output = result(inputs, parent, source, sources, bundle, runtime, numerical, observations, counts)
    inputs.recheck()
    load(); schema()  # Recheck independently pinned oracle and parent schema files.
    return output


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('packet', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(arguments)
    require(args.output.parent.is_dir() and not os.path.lexists(args.output), 'New output file in an existing directory required')
    try:
        value = audit_packet(args.packet)
    except Exception as error:
        value = dict(kind='private_short_execution_binding_audit', schemaVersion=1, passed=False,
                     error=type(error).__name__ + ': ' + str(error), executionAdmission=False,
                     providerEligibilityEstablished=False, throughputQualification=False)
    raw = (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()
    require(len(raw) <= 1024**2, 'Binding report exceeds its publication limit')
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(raw)
    print(json.dumps(dict(passed=value['passed'], receipt=str(args.output))))
    return 0 if value['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
