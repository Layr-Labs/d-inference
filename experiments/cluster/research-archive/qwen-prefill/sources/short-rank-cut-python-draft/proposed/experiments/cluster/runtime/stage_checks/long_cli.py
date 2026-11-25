"""Thin local coordinator for the separately admitted registered long profile."""
from pathlib import Path
import signal
import uuid
from . import archive, long_artifacts, long_configuration, long_inputs, long_supervision, long_phase
from .common import integer, require, sha
from .long_profile import ARTIFACT, COMMANDS, MAX_PARENT_TIMEOUT, NATIVE_TIMEOUT, POLICIES
from .long_resources import MemoryGate
from .long_stream import source_stderr_contract
from .prefill_resources import initial_free_screen
from .resources import resource_preflight


def add_parsers(commands):
    for name in COMMANDS:
        command = commands.add_parser(name)
        for key in ('release','runtime','output','model-dir','tokens-file','prompt-origin-file'):
            command.add_argument('--' + key, type=Path, required=True)
        for key in ('expected-binary-sha256','artifact-aggregate-sha256','tokens-sha256','prompt-origin-sha256'):
            command.add_argument('--' + key, required=True)
        command.add_argument('--parent-timeout-seconds', type=int, default=MAX_PARENT_TIMEOUT)
        command.add_argument('--minimum-reclaimable-gib', type=int, default=8)
        command.add_argument('--prefill-phase-trace', action='store_true',
                             help='Request owned local phase sidecars; verification remains separate')
        if name == 'long-prefill-ranks':
            command.add_argument('--stage-prefill-policy', choices=POLICIES, required=True)
            command.add_argument('--stage-logits-dtype', choices=['bfloat16'], required=True)
        else: command.set_defaults(stage_prefill_policy=None, stage_logits_dtype=None)


def run(args):
    integer(args.parent_timeout_seconds, 1, MAX_PARENT_TIMEOUT)
    integer(args.minimum_reclaimable_gib, 8, 1024)
    phase_requested = long_phase.requested(args)
    for pin in (args.expected_binary_sha256, args.tokens_sha256, args.prompt_origin_sha256): sha(pin)
    require(args.command in COMMANDS and args.artifact_aggregate_sha256 == ARTIFACT, 'Registered9B long profile required')
    runtime = args.runtime.resolve(strict=True); output = args.output.expanduser().resolve()
    model = args.model_dir.expanduser().resolve(strict=True)
    require(not output.exists() and not output.is_relative_to(runtime.parents[2])
            and not output.is_relative_to(model), 'Output must be new and outside repository/model')
    output.mkdir(mode=0o700, parents=True)
    paired = args.command == 'long-prefill-ranks'; epoch = uuid.uuid4().hex
    memory = modules = context = None; ranks = []; children = []; handlers = {}
    receipt = dict(kind='stage_checks_run', schema_version=1, mode=args.command, epoch=epoch,
        long_contract_schema_version=1, passed=False, native_execution_attempted=False,
        throughput_qualification=False, physical_two_machine_execution=False,
        timing_diagnostic_only=True, native_timeout_seconds=NATIVE_TIMEOUT,
        parent_timeout_seconds=args.parent_timeout_seconds, local_owner_count=2 if paired else 1,
        baseline_audit=dict(performed=False), independent_numerical_action_timing_audit=dict(performed=False),
        primary_failure=None, cleanup_errors=[], post_run_errors=[])
    if phase_requested: receipt['phase_trace_request'] = long_phase.receipt(args.command)
    try:
        initial = initial_free_screen(); receipt['initial_free_screen'] = initial
        require(initial['passed'], 'Initial actual-free screen refused before snapshots/artifact hashing')
        memory = MemoryGate(); memory.observe()
        launcher = archive.archive_launcher(output); sources = archive.archive_sources(runtime, output)
        modules = archive.load_archived_runtime(output, epoch)
        bundle_hash = modules['bundle'].snapshot(args.release.resolve(strict=True), output / 'bundle')
        require(archive.digest(output / 'bundle/cluster-inference') == args.expected_binary_sha256, 'Explicit native binary pin differs')
        archive.verify_archive(modules, output, sources, bundle_hash, launcher)
        context = long_inputs.prepare(args, output, epoch, modules['artifacts'])
        archive.write_json(output / 'context.json', context)
        warning = source_stderr_contract(output, paired)
        preflight = resource_preflight(output, args.minimum_reclaimable_gib); receipt['preflight'] = preflight
        require(preflight['passed'], 'Post-hash reclaimable/disk/descriptor screen refused')
        memory.observe()
        hosts = modules['configuration'].loopback_addresses() if paired else None
        ranks, retained = long_configuration.stage(output, context, bundle_hash, hosts)
        retained.append(dict(path='context.json', size_bytes=(output / 'context.json').stat().st_size,
                             sha256=archive.digest(output / 'context.json')))
        receipt.update(source_manifest_sha256=archive.digest(output / 'source-manifest.json'),
            source_file_count=len(sources['files']), bundle_manifest_sha256=bundle_hash, launcher_files=launcher,
            context_sha256=archive.digest(output / 'context.json'), retained_files=retained,
            stderr_contract=warning, endpoint_reservation=dict(hostfile=hosts, held_through_launch=False,
                bind_race_retried=False) if paired else None)
        def interrupted(signum, _frame): raise SystemExit(128 + signum)
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            handlers[signum] = signal.signal(signum, interrupted)
        def start(rank):
            child = modules['processes'].start(rank); children.append(child); return child
        receipt['native_execution_attempted'] = True; archive.write_json(output / 'receipt.json', receipt)
        result = long_supervision.run(ranks, context, args.parent_timeout_seconds,
            start, modules['processes'].stop_processes, memory.observe)
        receipt['cohort'] = result; receipt['cleanup_errors'].extend(result['cleanup_errors'])
        if not result['passed']:
            receipt['primary_failure'] = dict(operation='native_cohort', reason=result['cancellation_reason'], error=result['error'])
        memory.observe()
        archive.verify_archive(modules, output, sources, bundle_hash, launcher)
        long_inputs.verify(context, output, modules['artifacts'])
        long_artifacts.verify_files(output, retained)
        require(source_stderr_contract(output, paired) == warning, 'Archived stderr source changed')
        receipt['frozen_inputs_artifact_bundle_source_rechecked'] = True
        receipt['passed'] = result['passed']
    except BaseException as caught:
        failure = dict(operation='launcher', error=type(caught).__name__ + ': ' + str(caught))
        if receipt['primary_failure'] is None: receipt['primary_failure'] = failure
        else: receipt['post_run_errors'].append(failure)
        receipt['passed'] = False
    finally:
        if children and not receipt['passed']:
            try: modules['processes'].stop_processes(ranks, children)
            except BaseException as caught: receipt['cleanup_errors'].append(dict(operation='final_stop_owned_cohort', error=repr(caught)))
        if memory is not None: receipt['memory_samples'] = memory.samples
        try: receipt['rank_files'] = long_artifacts.rank_files(output, paired)
        except BaseException as caught:
            receipt['passed'] = False
            failure = dict(operation='archive_rank_files', error=repr(caught))
            if receipt['primary_failure'] is None: receipt['primary_failure'] = failure
            else: receipt['post_run_errors'].append(failure)
        for signum, handler in handlers.items(): signal.signal(signum, handler)
        archive.write_json(output / 'receipt.json', receipt)
    print(str(output / 'receipt.json')); return 0 if receipt['passed'] else 1
