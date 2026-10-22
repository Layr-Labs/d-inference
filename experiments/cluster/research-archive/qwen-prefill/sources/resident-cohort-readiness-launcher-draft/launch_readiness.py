#!/usr/bin/env python3
"""Private root-run model-free readiness qualification; one fresh local cohort."""
import argparse
from pathlib import Path
import signal
import sys
import uuid
sys.dont_write_bytecode = True

from prefill_compute_archive import (archive_launcher, archive_sources, digest,
    load_archived_runtime, verify_archive, write_json)
from readiness_config import SCENARIOS, NATIVE_SECONDS, configuration, parent_seconds, pin, require
from readiness_contract import source_contract
from readiness_memory import Observations
from readiness_supervision import supervise
from readiness_stream import LIMIT


def run(arguments):
    pin(arguments.expected_native_sha256)
    parent_seconds(arguments.scenario)
    runtime = arguments.runtime.expanduser().resolve(strict=True)
    repository = runtime.parents[2]
    require(runtime == repository / 'experiments/cluster/runtime', 'Unexpected runtime layout')
    release = arguments.release.expanduser().resolve(strict=True)
    output = arguments.output.expanduser().resolve()
    require(not output.exists() and output.parent.is_dir() and not output.is_relative_to(repository),
            'Output must be new, have an existing parent, and be outside the repository')
    output.mkdir(mode=0o700)
    epoch = uuid.uuid4().hex
    receipt = dict(schema_version=1, kind='private_model_free_cohort_readiness_launcher',
        epoch=epoch, scenario=arguments.scenario, status='preparing', scenario_passed=False,
        native_success=False, expected_native_sha256=arguments.expected_native_sha256,
        native_timeout_seconds=NATIVE_SECONDS, parent_timeout_seconds=parent_seconds(arguments.scenario),
        native_execution_attempted=False, no_models=True, primary_failure=None,
        cleanup_errors=[], post_run_errors=[], model_payload_or_numerical_audit_performed=False,
        resident_reuse_qualified=False, physical_transfer_qualified=False, throughput_qualified=False)
    save = lambda: write_json(output / 'receipt.json', receipt)
    save()
    observations = Observations(output)
    modules = sources = bundle_hash = launcher = None
    configs = []; previous_handlers = {}
    try:
        observations.observe(initial_free=True, refuse_existing=True)
        launcher = archive_launcher(output)
        sources = archive_sources(runtime, output)
        modules = load_archived_runtime(output, epoch)
        bundle_hash = modules['bundle'].snapshot(release, output / 'bundle')
        require(digest(output / 'bundle/cluster-inference') == arguments.expected_native_sha256,
                'Archived native differs from the explicit release pin')
        verify_archive(modules, output, sources, bundle_hash, launcher)
        receipt.update(source_manifest_sha256=digest(output / 'source-manifest.json'),
            source_file_count=len(sources['files']), bundle_manifest_sha256=bundle_hash,
            launcher_files=launcher, native_source_contract=source_contract(output))
        hosts = modules['configuration'].loopback_addresses()
        ranks = []
        for rank in range(2):
            directory = output / ('rank-' + str(rank)); directory.mkdir(mode=0o700)
            config = configuration(output / 'bundle', bundle_hash, rank, epoch, arguments.scenario, hosts)
            write_json(directory / 'rank.json', config)
            write_json(directory / 'hosts.json', hosts)
            configs.extend(dict(path=str((directory / name).relative_to(output)),
                                sha256=digest(directory / name)) for name in ['rank.json', 'hosts.json'])
            ranks.append(dict(rank=rank, host=None, directory=str(directory),
                              local=str(directory), bundle=str(output / 'bundle')))
        receipt.update(hostfile=hosts, planned_ranks=ranks, configuration_files=configs)
        observations.observe(initial_free=True)
        def interrupted(signum, _frame):
            raise KeyboardInterrupt('Readiness driver interrupted by signal ' + str(signum))
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[signum] = signal.signal(signum, interrupted)
        receipt.update(native_execution_attempted=True, status='running'); save()
        receipt['execution'] = supervise(ranks, epoch, arguments.scenario,
            start=modules['processes'].start, stop=modules['processes'].stop_processes,
            memory=lambda deadline: observations.observe(deadline=deadline), started=observations.started)
        receipt['cleanup_errors'].extend(receipt['execution']['cleanup_errors'])
        receipt['native_success'] = receipt['execution']['native_success']
        receipt['scenario_passed'] = receipt['execution']['scenario_passed']
    except BaseException as error:
        receipt['primary_failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        # Each postflight failure is retained independently, including after expected negatives.
        actions = [('memory', lambda: observations.observe()),
                   ('owned_process_inventory', observations.postflight)]
        if modules and sources and bundle_hash and launcher is not None:
            actions.append(('source_bundle_launcher_recheck',
                lambda: verify_archive(modules, output, sources, bundle_hash, launcher)))
        for name, action in actions:
            try:
                result = action()
                if name == 'owned_process_inventory':
                    receipt['postflight'] = result
                    require(not result['observed_remaining'], 'Owned process remains after cohort cleanup')
                if name == 'source_bundle_launcher_recheck':
                    receipt['source_bundle_launcher_unchanged_after_run'] = True
            except BaseException as error:
                receipt['post_run_errors'].append(dict(operation=name, error=repr(error)))
        for entry in configs:
            try:
                require(digest(output / entry['path']) == entry['sha256'], 'Rank config/host bytes changed')
            except BaseException as error:
                receipt['post_run_errors'].append(dict(operation='configuration_recheck', path=entry['path'], error=repr(error)))
        receipt['rank_files'] = []
        for rank in range(2):
            for name in ['rank.json', 'hosts.json', 'stdout.jsonl', 'stderr.log', 'cancel']:
                path = output / ('rank-' + str(rank)) / name
                try:
                    if path.exists():
                        size = path.stat().st_size
                        receipt['rank_files'].append(dict(path=str(path.relative_to(output)), size_bytes=size,
                            sha256=digest(path) if size <= LIMIT else None, oversized=size > LIMIT))
                        require(size <= LIMIT, 'Retained rank file exceeds its bound')
                except BaseException as error:
                    receipt['post_run_errors'].append(dict(operation='retain_rank_file',
                        path=str(path.relative_to(output)), error=repr(error)))
        receipt['memory_samples'] = observations.samples
        receipt['memory_policy'] = 'initial/prelaunch actual free >=1GiB; pressure<=2; no new reported swap'
        receipt['scenario_passed'] = bool(receipt['scenario_passed'] and not receipt['primary_failure'] and
            not receipt['cleanup_errors'] and not receipt['post_run_errors'])
        receipt['status'] = 'passed' if receipt['scenario_passed'] else 'failed'
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        save()
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['runtime', 'release', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--expected-native-sha256', required=True)
    parser.add_argument('--scenario', choices=SCENARIOS, required=True)
    arguments = parser.parse_args()
    receipt = run(arguments)
    print(str(arguments.output.expanduser().resolve() / 'receipt.json'))
    return 0 if receipt['scenario_passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
