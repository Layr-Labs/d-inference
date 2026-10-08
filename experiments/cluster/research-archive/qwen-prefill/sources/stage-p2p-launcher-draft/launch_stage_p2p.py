#!/usr/bin/env python3
"""Root-run only: bounded no-model, two-process stage transport check on loopback."""

import argparse
from pathlib import Path
import signal
import sys
import uuid

from stage_p2p_archive import (archive_launcher, archive_sources, digest, load_archived_runtime,
                               verify_archive, write_json)
from stage_p2p_contract import rank_configuration, require_timeout
from stage_p2p_supervision import supervise
from stage_p2p_memory import MemoryGate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout-seconds', type=int, default=60)
    parser.add_argument('--scenario', choices=['success', 'bootstrap-timeout', 'peer-loss'], default='success')
    arguments = parser.parse_args()
    require_timeout(arguments.timeout_seconds)
    output = arguments.output.expanduser().resolve()
    runtime = arguments.runtime.expanduser().resolve(strict=True)
    repository = runtime.parents[2]
    if output.exists() or output.is_relative_to(repository):
        raise ValueError('Output must be a new directory outside the repository')
    output.mkdir(mode=0o700, parents=True)
    epoch = uuid.uuid4().hex
    receipt = dict(schema_version=1, kind='stage_p2p_launcher', epoch=epoch,
                   passed=False, native_execution_attempted=False, no_models=True,
                   correctness_only=True, throughput_measurement_valid=False)
    previous_handlers = {}
    memory = None
    try:
        launcher = archive_launcher(output)
        sources = archive_sources(runtime, output)
        modules = load_archived_runtime(output, epoch)
        bundle_hash = modules['bundle'].snapshot(arguments.release.expanduser().resolve(strict=True), output / 'bundle')
        verify_archive(modules, output, sources, bundle_hash, launcher)
        memory = MemoryGate()
        hosts = modules['configuration'].loopback_addresses()
        ranks = []
        for index in range(2):
            directory = output / f'rank-{index}'
            directory.mkdir(mode=0o700)
            config = rank_configuration(output / 'bundle', bundle_hash, index, epoch,
                                        arguments.timeout_seconds, hosts)
            write_json(directory / 'rank.json', config)
            ranks.append(dict(rank=index, host=None, directory=str(directory), local=str(directory),
                              bundle=str(output / 'bundle')))
        receipt.update(source_manifest_sha256=digest(output / 'source-manifest.json'),
                       source_file_count=len(sources['files']), bundle_manifest_sha256=bundle_hash,
                       launcher_files=launcher, hostfile=hosts, timeout_seconds=arguments.timeout_seconds,
                       scenario=arguments.scenario,
                       rank_configuration_sha256=[digest(output / f'rank-{i}/rank.json') for i in range(2)])
        write_json(output / 'receipt.json', receipt)
        def interrupted(signum, _frame):
            raise SystemExit(128 + signum)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[signum] = signal.signal(signum, interrupted)
        receipt['native_execution_attempted'] = True
        write_json(output / 'receipt.json', receipt)
        result = supervise(ranks, epoch, arguments.timeout_seconds,
                           start=modules['processes'].start, stop=modules['processes'].stop_processes,
                           scenario=arguments.scenario, memory_check=memory.observe)
        receipt['cohort'] = result
        memory.observe()
        for i, expected in enumerate(receipt['rank_configuration_sha256']):
            if digest(output / f'rank-{i}/rank.json') != expected:
                raise ValueError('Rank configuration changed during execution')
        verify_archive(modules, output, sources, bundle_hash, launcher)
        receipt['source_bundle_runtime_unchanged_after_run'] = True
        receipt['passed'] = result['scenario_passed']
        receipt['native_success'] = result['passed']
        receipt['rank_files'] = []
        for i in range(2):
            for name in ('rank.json', 'hosts.json', 'stdout.jsonl', 'stderr.log'):
                path = output / f'rank-{i}' / name
                if path.exists():
                    receipt['rank_files'].append(dict(path=path.relative_to(output).as_posix(),
                                                     sha256=digest(path), size_bytes=path.stat().st_size))
    except BaseException as error:
        receipt['error'] = type(error).__name__ + ': ' + str(error)
        receipt['passed'] = False
    finally:
        if memory is not None:
            receipt['memory_samples'] = memory.samples
            receipt['memory_gate'] = 'pressure <= 2, no increase in OS-reported swap used'
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        write_json(output / 'receipt.json', receipt)
    print(str(output / 'receipt.json'))
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
