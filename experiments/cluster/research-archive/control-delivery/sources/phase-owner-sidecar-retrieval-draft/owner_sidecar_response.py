"""Bounded envelopes and identity only; event semantics are audited separately."""
from sidecar_files import MAX_SIDECAR, parse, require, sha


def decode_envelope(data, context):
    require(type(data) is bytes and len(data) <= MAX_SIDECAR + 4097 and b'\n' in data,
            'Bounded metadata/raw sidecar framing missing')
    header, raw = data.split(b'\n', 1)
    require(len(header) <= 4096 and 0 < len(raw) <= MAX_SIDECAR, 'Sidecar response bounds')
    metadata = parse(header)
    keys = {'kind', 'schema_version', 'path', 'sha256', 'size_bytes', 'mode', 'uid', 'gid',
            'device', 'inode', 'link_count', 'mtime_ns', 'ctime_ns', 'stable_descriptor_read',
            'followed_symlinks', 'remote_file_modified'}
    require(type(metadata) is dict and set(metadata) == keys
            and metadata['kind'] == 'qwen_prefill_phase_sidecar_read'
            and type(metadata['schema_version']) is int and metadata['schema_version'] == 1,
            'Unexpected remote reader schema')
    require(metadata['path'] == context['remote_path'] and metadata['sha256'] == sha(raw)
            and type(metadata['size_bytes']) is int and metadata['size_bytes'] == len(raw)
            and type(metadata['mode']) is int and metadata['mode'] == 0o600
            and type(metadata['link_count']) is int and metadata['link_count'] == 1,
            'Remote sidecar identity, mode, or size differs')
    require(all(type(metadata[key]) is int and metadata[key] >= 0
                for key in ('uid', 'gid', 'device', 'inode', 'mtime_ns', 'ctime_ns'))
            and metadata['stable_descriptor_read'] is True and metadata['followed_symlinks'] is False
            and metadata['remote_file_modified'] is False, 'Invalid remote descriptor observations')
    return raw, metadata


def decode_phase(data, context):
    raw, metadata = decode_envelope(data, context)
    trace = parse(raw)
    require(type(trace) is dict and trace.get('kind') == 'qwen_prefill_local_phase_trace'
            and type(trace.get('schemaVersion')) is int and trace['schemaVersion'] == 1
            and trace.get('identity') == context['expected_identity']
            and trace.get('clockSource') == 'DispatchTime.uptimeNanoseconds', 'Sidecar request/profile/clock mismatch')
    for key, expected in [('diagnosticOnly', True), ('includesRecorderOverhead', True),
                          ('crossProcessClockAlignmentAsserted', False), ('gpuOverlapAsserted', False),
                          ('modelReleaseAsserted', False), ('recorderIndependentlyVerifiesRequestRetirement', False)]:
        require(trace.get(key) is expected, 'Sidecar qualification flag differs: ' + key)
    require(type(trace.get('maximumEvents')) is int and 1 <= trace['maximumEvents'] <= 1024
            and type(trace.get('events')) is list and 1 <= len(trace['events']) <= trace['maximumEvents'],
            'Sidecar event collection bounds')
    return raw, metadata, dict(identity=trace['identity'], clock_source=trace['clockSource'],
                               event_count=len(trace['events']), event_sequence_semantics_audited=False)


def decode_owner(data, context):
    raw, metadata = decode_envelope(data, context)
    trace = parse(raw)
    flags = dict(diagnosticOnly=True, includesRecorderOverhead=True,
                 evaluationIntervalIncludesExistingErrorCheck=True,
                 crossProcessClockAlignmentAsserted=False, gpuKernelTimeAsserted=False,
                 gpuOverlapAsserted=False, modelReleaseAsserted=False,
                 recorderIndependentlyVerifiesOuterSuccess=False)
    keys = {'kind', 'schemaVersion', 'identity', 'clockSource', 'maximumEvents', 'events',
            'firstLocalUptimeNanoseconds', 'lastLocalUptimeNanoseconds', 'traceSpanNanoseconds'} | set(flags)
    require(type(trace) is dict and set(trace) == keys
            and trace['kind'] == 'qwen_prefill_selected_owner_trace'
            and type(trace['schemaVersion']) is int and trace['schemaVersion'] == 1
            and trace['clockSource'] == 'DispatchTime.uptimeNanoseconds',
            'Owner sidecar kind/schema/production clock differs')
    identity = trace['identity']
    require(type(identity) is dict and set(identity) == set(context['expected_identity'])
            and identity == context['expected_identity']
            and all(type(identity[key]) is int for key in
                    ('frameSequence', 'tokenOffset', 'tokenCount', 'committedFrontier')),
            'Owner selected-frame/request/profile/role differs')
    for key, expected in flags.items():
        require(trace[key] is expected, 'Owner qualification flag differs: ' + key)
    require(type(trace['maximumEvents']) is int and trace['maximumEvents'] == 8
            and type(trace['events']) is list and len(trace['events']) == 8,
            'Owner sidecar requires the bounded eight-event collection')
    # Event values, ordering, clock arithmetic and phase containment are opaque here.
    return raw, metadata, dict(identity=identity, clock_source=trace['clockSource'],
                               event_count=8, event_sequence_semantics_audited=False)


def decode_response(data, context):
    require(context['name'] in ('phase', 'owner'), 'Unadmitted sidecar name')
    return (decode_phase if context['name'] == 'phase' else decode_owner)(data, context)
