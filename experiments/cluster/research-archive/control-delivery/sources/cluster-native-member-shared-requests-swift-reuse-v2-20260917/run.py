"""Granted Foundation helper/legacy checks, Provider tests, then matching CLI build."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import sys
sys.dont_write_bytecode = True
import source_inventory as inventory
from check_process import run_owned
from context import BASE, ADAPTER, ADAPTER_SHA, WORKSPACE, OUTPUT, SOURCE, SWIFT_FILTER, INVOCATION_METHODS, isolated_environment, CORRECTION_SHA
from guards import sha, save, verify, recheck_sources, require_preserved_cli, require
from coverage import validate as validate_swift_results

def main():
    p = argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--prepared', type=Path, required=True)
    p.add_argument('--phase', choices=['helper', 'tests', 'build'], required=True)
    p.add_argument('--attempt', type=int, required=True)
    args = p.parse_args()
    if not 1 <= args.attempt <= 9: raise ValueError('Attempt bound')
    prepared = args.prepared.resolve(); workspace = WORKSPACE
    require(prepared == OUTPUT, 'Exact incremental output root required')
    _, expected_main, _, expected_candidate = verify()
    preparation = json.loads((prepared / 'preparation.json').read_text())
    require(preparation['workspace'] == str(workspace) and preparation['source'] == str(SOURCE)
        and preparation['wrapperManifestSHA256'] == sha(BASE / 'manifest.json')
        and preparation['adapterManifestSHA256'] == ADAPTER_SHA
        and preparation['correctionManifestSHA256'] == CORRECTION_SHA
        and preparation['integrationSHA256'] == sha(BASE / 'integration.json')
        and preparation['candidateSHA256'] == sha(prepared / 'candidate-before.json'), 'Preparation binding differs')
    before = json.loads((prepared / 'source-before.json').read_text())
    candidate = json.loads((prepared / 'candidate-before.json').read_text())
    require(before == expected_main and candidate == expected_candidate, 'Final source composition differs')
    def recheck():
        verify(); recheck_sources(candidate, before)
    recheck(); require_preserved_cli()
    helper = prepared / ('helper-' + str(args.attempt))
    def prior(name):
        output = prepared / (name + '-' + str(args.attempt))
        value = json.loads((output / 'checks.json').read_text())
        if not value.get('passed') or value['manifestSHA256'] != sha(BASE / 'manifest.json') or value['candidateSHA256'] != sha(prepared / 'candidate-before.json'):
            raise ValueError('Matching prior phase required')
        for row in value.get('artifacts', []):
            if sha(row['path']) != row['sha256']: raise ValueError('Compiled helper artifact changed')
        return value
    if args.phase in ('tests', 'build'): prior('helper')
    if args.phase == 'build':
        if prior('tests')['details']['invocationMethodsPassed'] != len(INVOCATION_METHODS): raise ValueError('Invocation tests incomplete')
    output = prepared / (args.phase + '-' + str(args.attempt)); output.mkdir(mode=0o700, exist_ok=False)
    isolated_environment()
    old_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, old_limit[1]))
    steps = []; details = {}; artifacts = []
    def execute(argv, name, bound):
        try: steps.append(run_owned(argv, output, name, bound))
        finally: recheck()
    try:
        if args.phase == 'helper':
            source = workspace / 'libs/darkbloom-cluster'
            (output / 'module-cache').mkdir(mode=0o700)
            command = ['xcrun', 'swiftc', '-j', '2', '-swift-version', '6', '-warnings-as-errors', '-target', 'arm64-apple-macos14.0', '-parse-as-library', '-module-cache-path', str(output / 'module-cache')]
            linkage = ['-I', str(output), '-L', str(output), '-Xlinker', '-rpath', '-Xlinker', str(output)]
            modules = [('DarkbloomClusterProtocol', []), ('DarkbloomClusterProcess', ['DarkbloomClusterProtocol']),
                ('DarkbloomClusterBootstrap', []), ('DarkbloomClusterSecurity', ['DarkbloomClusterBootstrap']),
                ('DarkbloomClusterRemote', ['DarkbloomClusterProtocol', 'DarkbloomClusterProcess', 'DarkbloomClusterBootstrap', 'DarkbloomClusterSecurity'])]
            for name, dependencies in modules:
                library = output / ('lib' + name + '.dylib')
                execute(command + linkage + ['-l' + x for x in dependencies] + ['-enable-testing', '-emit-library', '-emit-module', '-module-name', name,
                    '-emit-module-path', str(output / (name + '.swiftmodule')), '-Xlinker', '-install_name', '-Xlinker', '@rpath/' + library.name] +
                    list(map(str, sorted((source / 'Sources' / name).glob('*.swift')))) + ['-o', str(library)], name, 60)
            links = linkage + ['-l' + name for name, _ in modules]
            executable = output / 'native-member-fixture'
            execute(command + links + list(map(str, sorted((ADAPTER / 'Tests/OwnedChild').glob('*.swift')))) + ['-o', str(executable)], 'compile-helper', 60)
            # Existing real owner/retirement/diagnostic regressions, same sources
            # and arguments as MAIN SSHChecks. No temp-directory deletion.
            for name in ['FakeClusterWorker', 'FakeOwner', 'RemoteOwnerTests', 'RetirementShutdownTests', 'DiagnosticFailureWorker', 'LateDiagnosticOwner', 'OwnerDiagnosticDrainTests']:
                path = source / ('Tests/ProcessChecks' if name == 'FakeClusterWorker' else 'Tests/SSHChecks') / (name + '.swift')
                files = [source / 'Tests/ProcessChecks/FixtureIdentity.swift', path]
                if name == 'RetirementShutdownTests': files.append(source / 'Tests/SSHChecks/RetirementOwnerConnection.swift')
                execute(command + links + ['-D', 'OWNER_DIAGNOSTIC_DRAIN'] + list(map(str, files)) + ['-o', str(output / name)], 'compile-' + name, 60)
            for directory in ['retirement-checks', 'diagnostic-checks']: (output / directory).mkdir(mode=0o700)
            execute([str(output / 'RemoteOwnerTests'), str(output / 'FakeOwner'), str(output / 'FakeClusterWorker')], 'legacy-remote', 30)
            execute([str(output / 'RetirementShutdownTests'), str(output / 'FakeOwner'), str(output / 'FakeClusterWorker'), str(output / 'retirement-checks'), 'corrected'], 'legacy-retirement', 30)
            execute([str(output / 'OwnerDiagnosticDrainTests'), str(output / 'LateDiagnosticOwner'), str(output / 'DiagnosticFailureWorker'), str(output / 'diagnostic-checks')], 'legacy-diagnostics', 30)
            for path in [executable] + sorted(output.glob('*.dylib')):
                artifacts.append({'path': str(path), 'sha256': sha(path), 'bytes': path.stat().st_size})
            details = {'helperCompiled': True, 'legacySSHChecksExecuted': True, 'newNativeHelperExecuted': False}
        else:
            os.chdir(workspace / 'provider-swift')
            command = ['swift', 'build' if args.phase == 'build' else 'test', '-j', '2', '--disable-automatic-resolution', '--disable-build-manifest-caching']
            if args.phase == 'tests':
                evidence = output / 'owned-native-evidence'; evidence.mkdir(mode=0o700)
                os.environ['DARKBLOOM_NATIVE_MEMBER_FIXTURE'] = str(helper / 'native-member-fixture')
                os.environ['DARKBLOOM_NATIVE_MEMBER_EVIDENCE'] = str(evidence)
                command += ['--filter', SWIFT_FILTER]
            else: command += ['--product', 'darkbloom']
            execute(command, 'execution', 900)
            prior('helper')
            if args.phase == 'tests':
                raw = (output / 'execution.stdout').read_text() + '\n' + (output / 'execution.stderr').read_text()
                details = validate_swift_results(raw)
                for name in INVOCATION_METHODS:
                    if len(re.findall(r'(?m)^✔ Test ' + re.escape(name) + r'\(\) passed after [^\n]+$', raw)) != 1:
                        raise ValueError('Invocation method absent or repeated: ' + name)
                details['invocationMethodsPassed'] = len(INVOCATION_METHODS)
            else:
                binary = workspace / 'provider-swift/.build/debug/darkbloom'
                details = {'binarySHA256': sha(binary), 'binaryBytes': binary.stat().st_size, 'binaryExecuted': False}
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, old_limit)
        recheck(); require_preserved_cli(); save(output / 'source-recheck.json', {'unchanged': True, 'priorQualifiedCLIPreserved': True})
        if args.phase != 'helper': prior('helper')
    save(output / 'checks.json', {'passed': True, 'phase': args.phase, 'details': details, 'artifacts': artifacts,
        'steps': steps, 'manifestSHA256': sha(BASE / 'manifest.json'), 'candidateSHA256': sha(prepared / 'candidate-before.json'),
        'adapterManifestSHA256': ADAPTER_SHA, 'correctionManifestSHA256': CORRECTION_SHA, 'priorQualifiedCLI_SHA256': preparation['qualifiedCLI_SHA256'],
        'modelOrRDMAOrRemoteExecuted': False, 'productionMembershipQualified': False})

if __name__ == '__main__': main()
