"""Pinned exact reference/off/depth-one values; physical authority is separate."""
import argparse
import json
import os
from pathlib import Path

from accepted_rounds import POLICY, accepted_agreement, check_rounds
from accepted_target import compare as compare_accepted
from audit_candidate import compare as compare_ordinary
from audit_common import agreement, exact, fields, parse, request_context, sha
from audit_reference import check_reference
from audit_scope import AuditScope
from recorded_math import canonical, digest, require
from snapshot import snapshot

LIMITS = dict(binding=65536, build_receipt=262144, bundle=65536, prompt=65536,
              reference_stdout=32*1024**2, off_rank0=16*1024**2, off_rank1=16*1024**2,
              depth1_rank0=16*1024**2, depth1_rank1=16*1024**2)


def audit(path, wanted):
    packet_item = snapshot(path, 65536)
    exact(packet_item['sha256'], sha(wanted), 'Packet pin')
    packet = fields(parse(packet_item['raw']), 'schema files', 'comparison packet')
    exact(packet['schema'], 'qwen_mtp_short_comparison_packet_v1', 'Packet schema')
    fields(packet['files'], ' '.join(LIMITS), 'Packet roles')
    saved = [(Path(path), 65536, packet_item)]; values = {}; identities = {packet_item['identity'][:2]}
    for role, cap in LIMITS.items():
        entry = fields(packet['files'][role], 'path sha256', role)
        filename = Path(entry['path'])
        require(filename.is_absolute() and filename == filename.resolve(), 'Canonical absolute input required')
        item = snapshot(filename, cap)
        exact(item['sha256'], sha(entry['sha256']), 'Pinned ' + role)
        require(item['identity'][:2] not in identities, 'Distinct input file identities required')
        identities.add(item['identity'][:2]); values[role] = item['raw']; saved.append((filename, cap, item))
    b = fields(parse(values['binding']), 'schema requestID promptSHA256 sourceSnapshotSHA256 dependencySnapshotSHA256 '
        'workerSHA256 referenceSHA256 bundleSHA256 buildReceiptSHA256 acceptedManifestSHA256 offAgreement depth1Agreement', 'prospective binding')
    exact(b['schema'], 'qwen_mtp_short_expected_v1', 'Expected schema')
    exact(b['acceptedManifestSHA256'], 'aa3b66fce361d1086bfaa979679ce25f844f6630630336805e3e1ea17460bbd4', 'Exact accepted source')
    exact(b['buildReceiptSHA256'], digest(values['build_receipt']), 'Build receipt binding')
    exact(b['bundleSHA256'], digest(values['bundle']), 'Native bundle binding')
    build = parse(values['build_receipt']); bundle = parse(values['bundle'])
    for actual, schema in [(build, 'qwen_mtp_same_source_build_v1'), (bundle, 'qwen_mtp_accepted_native_bundle_v1')]:
        exact(actual['schema'], schema, 'Build/bundle schema')
        for key in ['sourceSnapshotSHA256', 'dependencySnapshotSHA256', 'acceptedManifestSHA256']:
            exact(actual[key], sha(b[key]), 'Source composition ' + key)
    exact(build['status'], 'passed', 'Actual same-source build completion')
    exact(bundle['buildReceiptSHA256'], b['buildReceiptSHA256'], 'Packaged build receipt')
    for product, key in [('darkbloom-cluster-worker', 'workerSHA256'), ('cluster-inference', 'referenceSHA256')]:
        matches = [x for x in build['products'] if x['product'] == product]
        members = [x for x in bundle['files'] if x['path'] == product]
        require(len(matches) == 1 and len(members) == 1, 'Both actual products required')
        exact(matches[0]['sha256'], sha(b[key]), 'Built product')
        exact(members[0]['sha256'], b[key], 'Packaged product')
        exact(matches[0]['bytes'], members[0]['bytes'], 'Product size')
    context = request_context(values['prompt'], b['requestID'], AuditScope('registered_qwen35_9b', 32, 16, 8, 4))
    exact(context['prompt_sha'], sha(b['promptSHA256']), 'Matched prompt')
    agreement(b['offAgreement'], context); accepted_agreement(b['depth1Agreement'], context)
    require(b['offAgreement']['membershipEpoch'] != b['depth1Agreement']['membershipEpoch'], 'Fresh membership per arm')
    for expected in [b['offAgreement'], b['depth1Agreement']]:
        exact(expected['rankBuildSHA256'], [b['workerSHA256']]*2, 'Same actual worker for both arms')
    for key in ['storageCommitmentSHA256', 'numericalPolicySHA256']:
        exact(b['offAgreement'][key], b['depth1Agreement'][key], 'Matched target source/policy')
    # Validate the complete full reference before inspecting either candidate.
    reference = check_reference(values['reference_stdout'], context)
    off = compare_ordinary(reference, [parse(values['off_rank0']), parse(values['off_rank1'])], b['offAgreement'], context)
    wrapped = [parse(values['depth1_rank0']), parse(values['depth1_rank1'])]
    targets, rounds = check_rounds(wrapped, context, reference['selected'], b['depth1Agreement'])
    accepted = compare_accepted(reference, targets, b['depth1Agreement'], context)
    for filename, cap, item in saved:
        exact(snapshot(filename, cap, keep=False), {k:v for k,v in item.items() if k != 'raw'}, 'Input identity/bytes recheck')
    return dict(schema='qwen_mtp_short_reference_off_depth1_comparison_v1', status='passed',
        packetSHA256=packet_item['sha256'], expectedBindingSHA256=digest(values['binding']),
        selectedTokenIDs=reference['selected'], comparedSelectedTokens=8,
        exactFullFinalRowsCompared=2, fullRowBytesPerArm=248320*2, orderedStateEntriesPerArm=72,
        ordinary=off, depth1=accepted, acceptedRounds=rounds, sourceInputsRechecked=True,
        independentlyObservedPhysicalExecution=False, runtimeResourcePolicyReplayed=False,
        processLeaseAndAliasRetirementVerified=False, performanceQualified=False, encryptedTransportQualified=False,
        servingEnabled=False)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--packet', required=True, type=Path)
    parser.add_argument('--packet-sha256', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(); code = 0
    try:
        result = audit(args.packet, args.packet_sha256)
    except Exception as error:
        code = 1
        result = dict(schema='qwen_mtp_short_reference_off_depth1_comparison_v1', status='failed',
                      error=(type(error).__name__ + ': ' + str(error))[:2048], numericalQualified=False)
    raw = canonical(result) + b'\n'
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, 'wb') as out:
        out.write(raw); out.flush(); os.fsync(out.fileno())
    print(json.dumps(dict(status=result['status'], resultSHA256=digest(raw)), sort_keys=True))
    raise SystemExit(code)


if __name__ == '__main__':
    main()
