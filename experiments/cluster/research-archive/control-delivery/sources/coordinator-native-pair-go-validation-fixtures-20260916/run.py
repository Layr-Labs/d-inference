"""Bounded Go qualification with exhaustive compiled-name API batches."""
import argparse
import json
import os
from pathlib import Path
import resource
import sys
sys.dont_write_bytecode = True
from check_process import run_owned
from go_coverage import API, completed, combine, discover, exact_filter, require_feature_passes
from guards import sha, save, verify_overlay, verify_go, isolated_environment
from inputs import (BASE, SOURCE, OVERLAY_SHA, B_OVERLAY_SHA, CORRECTION_SHA,
                    GO, GO_SHA, GO_PACKAGES, GO_FILTER)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=['go-focused', 'go-all'], required=True)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--attempt', type=int, required=True)
    args = parser.parse_args()
    if args.attempt < 1:
        raise ValueError('Invalid attempt')
    prepared = args.prepared.resolve(); workspace = prepared / 'workspace'
    if prepared.parent != BASE.parent or prepared == BASE or workspace.is_symlink():
        raise ValueError('Expected the private Go preparation sibling')
    preparation = json.loads((prepared / 'preparation.json').read_text())
    inventory_sha = sha(prepared / 'source-before.json')
    if (preparation['overlayManifestSHA256'] != OVERLAY_SHA or
        preparation.get('nativeOverlayManifestSHA256') != B_OVERLAY_SHA or
        preparation.get('correctionManifestSHA256') != CORRECTION_SHA or
        preparation['workspace'] != str(workspace) or preparation['source'] != str(SOURCE) or
        preparation['phase'] != 'go' or preparation['sourceInventorySHA256'] != inventory_sha):
        raise ValueError('Prepared source identity differs')
    before = json.loads((prepared / 'source-before.json').read_text())

    def recheck():
        verify_overlay(); verify_go(before, workspace)

    recheck()
    if args.phase == 'go-all':
        focused = json.loads((prepared / ('go-focused-' + str(args.attempt)) / 'checks.json').read_text())
        if not focused.get('passed') or focused.get('phase') != 'go-focused' or focused.get('sourceInventorySHA256') != inventory_sha:
            raise ValueError('Full batches require matching focused PASS first')
    output = prepared / (args.phase + '-' + str(args.attempt)); output.mkdir(mode=0o700, exist_ok=False)
    if sha(Path(GO)) != GO_SHA:
        raise ValueError('Go toolchain changed')
    base_command = [GO, 'test', '-json', '-race', '-p', '2', '-count=1']
    os.chdir(workspace)
    isolated_environment()
    executions = []

    def execute(name, options, packages):
        recheck()
        command = base_command + options + ['./' + package for package in packages]
        print(json.dumps({'starting': name, 'packages': packages, 'parentSeconds': 300}), flush=True)
        try:
            run_owned(command, output, name, 300, diagnostic_limit=16_777_216)
        finally:
            recheck()
            save(output / (name + '.source-recheck.json'), {'sourcePinsUnchanged': True, 'mainUnchanged': True})
        executions.append({'name': name, 'executionSHA256': sha(output / (name + '.json'))})
        return [json.loads(line) for line in (output / (name + '.stdout')).read_text().splitlines() if line]

    old_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, old_limit[1]))
    try:
        if args.phase == 'go-focused':
            coverage = completed(execute('execution', ['-timeout=120s', '-run', GO_FILTER], GO_PACKAGES))
            details = require_feature_passes(coverage)
        else:
            catalog = discover(execute('compiled-list', ['-timeout=180s', '-list', '.'], GO_PACKAGES))
            catalog['sourceInventorySHA256'] = inventory_sha
            save(output / 'discovery.json', catalog)
            # Core packages keep normal unfiltered go test behavior. API batches
            # select every compiled Test/Example/Fuzz seed entry exactly once.
            core_expected = {package: names for package, names in catalog['packages'].items() if package != API}
            core = completed(execute('registry-protocol', ['-timeout=180s'], GO_PACKAGES[:2]), core_expected)
            save(output / 'registry-protocol.coverage.json', core)
            parts = [core]
            for index, names in enumerate(catalog['apiBatches'], 1):
                name = 'api-' + str(index)
                part = completed(execute(name, ['-timeout=180s', '-run', exact_filter(names)], [GO_PACKAGES[2]]), {API: names})
                save(output / (name + '.coverage.json'), part)
                parts.append(part)
            coverage = combine(parts, catalog['packages'])
            details = require_feature_passes(coverage, full=True)
            details.update(compiledDiscoverySHA256=sha(output / 'discovery.json'), apiBatches=4,
                           exactDisjointCoverage=True, excludedBenchmarks=catalog['excludedBenchmarks'])
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, old_limit)
        recheck()
        save(output / 'source-recheck.json', {'sourcePinsUnchanged': True, 'mainUnchanged': True})
    save(output / 'coverage.json', coverage)
    save(output / 'checks.json', {'passed': True, 'phase': args.phase, 'details': details,
        'sourceInventorySHA256': inventory_sha, 'sourcePinsUnchanged': True, 'mainChanged': False,
        'modelOrRemoteExecuted': False, 'providerNativeInvocationQualified': False,
        'encryptedRDMAQualified': False, 'executions': executions})
    print(json.dumps(details, sort_keys=True), flush=True)


if __name__ == '__main__':
    main()
