"""Explicit local phase request only; sidecar collection/auditing stays separate."""
from .common import require
from .long_profile import COMMANDS


def requested(args):
    value = getattr(args, 'prefill_phase_trace', False)
    require(type(value) is bool, 'Phase trace request must be boolean')
    return value


def arguments(context):
    value = context.get('prefill_phase_trace', False)
    require(type(value) is bool and context['mode'] in COMMANDS, 'Invalid long phase context')
    return ['--prefill-phase-trace-file', '@rank/phase-trace.json'] if value else []


def receipt(mode):
    require(mode in COMMANDS, 'Phase traces are only available for the registered long commands')
    count = 2 if mode == 'long-prefill-ranks' else 1
    return dict(requested=True,
        expected_owned_relative_paths=['rank-' + str(rank) + '/phase-trace.json' for rank in range(count)],
        included_in_rank_files=False, sidecars_verified=False, phase_semantics_audited=False)
