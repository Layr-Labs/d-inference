"""Compare one CPU-control solo/pair cohort to actual accepted padded v2."""
import argparse
import json
from pathlib import Path
from dependencies import (HERE, TASK, OLD, HARNESS, BUILD, APPLIED, INTEGRATION,
    NATIVE, BASELINE_NATIVE, c, padded, decode_summary, exact, require,
    source_composition, contract, verify_inputs)

def deployment():
    build = c.joined.read(BUILD)
    applied = c.joined.read(APPLIED)
    source_composition(build, applied, c.joined.read(OLD / 'build/applied-control-frame.json'),
                       c.joined.read(INTEGRATION))
    package_path = HARNESS / 'deployment/package.json'
    package = c.joined.read(package_path)
    package_pin = c.pin(package_path)
    rows = [x for x in package['files'] if x['path'] == 'bundle/GemmaResidentBenchmark']
    exact(len(rows), 1, 'Exactly one packaged native')
    native = padded.file_hash(HARNESS / 'deployment/bundle/GemmaResidentBenchmark', 128 * 1024**2)
    exact(native['sha256'], NATIVE, 'Deployed native hash')
    exact(native['bytes'], build['nativeBytes'], 'Deployed native size')
    exact(rows[0], dict(path='bundle/GemmaResidentBenchmark', bytes=native['bytes'], sha256=NATIVE), 'Packaged native')
    # Every copied remote supervisor belongs to the frozen source-only harness.
    source = c.joined.read(HARNESS / 'source-inputs.json')
    package_by_path = {row['path']: row for row in package['files']}
    exact(len(package_by_path), len(package['files']), 'Unique package inventory')
    for row in source['members']:
        if row['path'].startswith('package/'):
            name = row['path'].removeprefix('package/')
            exact(package_by_path[name], dict(row, path=name), 'Packaged exact supervisor ' + name)
    installs = []
    for host in ('darkbloom-24', 'darkbloom-48'):
        path = HARNESS / f'installation-{host}-{package_pin["sha256"][:12]}.json'
        value = c.joined.read(path)
        exact(value['exitCode'], 0, 'Actual installation exit')
        exact(value['stderr'], '', 'Actual installation stderr')
        exact(value['packageSHA256'], package_pin['sha256'], 'Installed package')
        response = c.joined.decode(value['stdout'])
        exact(response['status'], 'installed', 'Completed installation')
        exact(response['root'], '/Users/developer/DarkbloomDev/gemma4-decode-cpu-control-20260920-v1', 'Exclusive namespace')
        exact(response['packageSHA256'], package_pin['sha256'], 'Remote package identity')
        installs.append(c.pin(path))
    return dict(build=c.pin(BUILD), applied=c.pin(APPLIED), package=package_pin,
                deployedNative=native, installations=installs)

def compare():
    verify_inputs()
    deployed = deployment()
    accepted = c.joined.read(OLD / 'review-padded/actual-padded-1/comparison.json')
    exact(accepted['status'], 'passed', 'Actual accepted padded reference')
    exact(accepted['nativeSHA256'], BASELINE_NATIVE, 'Accepted reference identity')
    cases = {
        'padded': (OLD / 'harness-v2/cases/p4096-cut7-c64-serial-v2',
                   OLD / 'harness-v2/cases/p4096-cut7-c64-overlap-v2', BASELINE_NATIVE),
        'cpuControl': (HARNESS / 'cases/p4096-cut7-c64-serial-cpu',
                       HARNESS / 'cases/p4096-cut7-c64-overlap-cpu', NATIVE),
    }
    roles = [('solo', 'full', 'darkbloom-48'), ('pair', 'stage0', 'darkbloom-24'),
             ('pair', 'stage1', 'darkbloom-48')]
    cohorts = {}
    for name, (solo, pair, native) in cases.items():
        cohorts[name] = [c.validate_role(solo if i == 0 else pair, kind, mode, host, native,
            deployed['package']['sha256'] if name == 'cpuControl' else None)
            for i, (kind, mode, host) in enumerate(roles)]
        padded.within_cohort(cohorts[name])
    contracts = []
    for i in range(3):
        old, new = cohorts['padded'][i], cohorts['cpuControl'][i]
        exact(old[2], accepted['retainedEvidence']['padded'][i], 'Original accepted physical authority')
        contracts.append(contract(new[1], old[1]))
    # No new state buffers or other captures: replay the one new cohort and
    # the retained v2 sidecars, including every original top-level field/byte.
    numerical = padded.numerical(cohorts['cpuControl'], {'padded': cohorts['padded']})
    exact(numerical['newFullRows'], 4, 'Four complete new row comparisons')
    exact(numerical['newComponents'], 360, 'All new KV/position components')
    exact(numerical['baselines']['padded']['fullRows'], 8, 'All baseline row comparisons')
    exact(numerical['baselines']['padded']['stateComponents'], 720, 'All baseline same-role state components')
    timings, profiles = {}, {}
    for i, role in enumerate(('solo', 'lookahead0', 'lookahead1')):
        before = c.original.summarize(cohorts['padded'][i][1]['samples'], 4096, 16)
        after = c.original.summarize(cohorts['cpuControl'][i][1]['samples'], 4096, 16)
        timings[role] = dict(before=before, after=after,
            prefillRateRatio=after['prefillTPS'] / before['prefillTPS'],
            decodeRateRatio=after['decodeTPS'] / before['decodeTPS'])
        profiles[role] = {name: decode_summary.summarize(values[i][1]) for name, values in cohorts.items()}
    verify_inputs()
    for path, row in c.RETAINED_PINS.items(): exact(c.pin(Path(path)), row, 'Unchanged retained execution')
    exact(c.pin(Path(deployed['package']['path'])), deployed['package'], 'Unchanged package')
    exact(padded.file_hash(Path(deployed['deployedNative']['path']), 128 * 1024**2),
          deployed['deployedNative'], 'Unchanged native')
    return dict(schema='gemma4_cpu_control_three_role_comparison_v1', status='passed',
        baselineNativeSHA256=BASELINE_NATIVE, nativeSHA256=NATIVE, deployment=deployed,
        inputSourceSHA256=c.pin(HERE / 'source-inputs.json')['sha256'],
        workload=accepted['workload'], numerical=numerical, timings=timings,
        decodeProfiles=profiles, exactCadenceAndBudget=contracts,
        retainedEvidence={name: [x[2] for x in values] for name, values in cohorts.items()},
        retainedInputPins=list(c.RETAINED_PINS.values()), newSerialPairExecuted=False,
        fullStateAndRowBytesActuallyCompared=True, transport='plaintext JACCL/RDMA',
        runtimePowerReaderChanged=False, residualFencesChanged=False,
        receiveWireCategoryIncludesExistingDataCopy=True,
        externalTTFTMeasured=False, crossProcessClockOriginsJoined=False,
        pureNetworkOrGPUTimeMeasured=False, representativeWorkloadStudyComplete=False,
        plannerEnabled=False)

def markdown(value):
    lines = ['CPU-control comparison passed for one matched solo and lookahead pair. All tokens, complete final rows and native KV bytes match accepted padded v2; exact guard cadence and resource budgets are unchanged.', '',
        '| Role | Padded prefill / decode TPS | CPU-control prefill / decode TPS |',
        '|---|---:|---:|']
    for role, row in value['timings'].items():
        cells = [f'{row[k]["prefillTPS"]:.3f} / {row[k]["decodeTPS"]:.3f}' for k in ('before', 'after')]
        lines.append('| ' + role + ' | ' + ' | '.join(cells) + ' |')
    lines += ['', 'P4096/C64/O16/cut7: one excluded warmup plus three measured requests. All four requests receive full numerical checking. New solo versus combined pair: four full rows and 360 state components. Same-role padded comparisons: eight full rows and 720 state components.', '',
        'Five host-control GPU fences per continuation token are omitted through a Data-only API; CPU completion, all resource/fault checks and the residual CPU/GPU fences remain. Logical decode guard counts must remain exactly the accepted 65/63 per rank/token. No power reader changed. The receive-wire category now includes its existing Data copy; total request clocks are unchanged.', '',
        'These are same-process internal timings for one fixed plaintext-RDMA workload. Inclusive owner/guard/wire intervals overlap and wire time includes peer work. No external TTFT, pure link/GPU timing, encrypted transport or broad throughput claim.', '']
    return '\n'.join(lines)

if __name__ == '__main__':
    p = argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--output-dir', type=Path, required=True)
    args = p.parse_args()
    require(args.output_dir.is_absolute() and args.output_dir == args.output_dir.resolve()
            and not args.output_dir.exists(), 'Fresh canonical comparison output required')
    value = compare()
    args.output_dir.mkdir(mode=0o700)
    raw = (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()
    with (args.output_dir / 'comparison.json').open('xb') as f: f.write(raw)
    with (args.output_dir / 'REPORT.md').open('x') as f: f.write(markdown(value))
    print(json.dumps(dict(status='passed', output=str(args.output_dir), sha256=c.sha(raw))))
