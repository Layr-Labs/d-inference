"""One root-scheduled phase at a time; fresh outputs, exact default sources, no retries."""
import argparse
import fcntl
import os
import resource
import sys
from common import BASE, RUN, WORKSPACE, clean_environment, inputs, prepared, read, require, save, sha, source_contract
from completions import completion
from inventory import inventory
from check_process import run_owned
from helper import build_helper, require_helper


def preceding(phase, candidate):
    out = RUN / phase
    receipt = read(out / 'receipt.json')
    require(receipt['passed'] and receipt['manifestSHA256'] == sha(BASE / 'manifest.json') and receipt['candidateSHA256'] == candidate and receipt['terminalInventoryMatchesCandidate'], 'Matching completed preceding phase required: ' + phase)
    if phase == 'tests':
        require(receipt['executionSHA256'] == sha(out / 'execution.json') and receipt['execution'] == read(out / 'execution.json'), 'Test execution receipt changed')
        require(receipt['details'] == completion((out / 'execution.stdout').read_text() + '\n' + (out / 'execution.stderr').read_text()), 'Actual test completions changed')
    return receipt


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('phase', choices=['prepare', 'helper', 'tests', 'build'])
    phase = parser.parse_args().phase
    clean_environment()
    contract = inputs()
    RUN.mkdir(mode=0o700, exist_ok=True)
    lock = (RUN / 'phase.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    out = RUN / phase
    out.mkdir(mode=0o700, exist_ok=False)
    receipt = dict(passed=False, phase=phase, manifestSHA256=sha(BASE / 'manifest.json'), compilerExecuted=phase != 'prepare', hardwareOrRemoteExecuted=False, defaultProduct=True)
    expected = None
    limits = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, limits[1]))
    try:
        if phase == 'prepare':
            receipt['execution'] = run_owned([sys.executable, '-B', str(BASE / 'prepare.py'), str(out)], out, 'execution', 300)
            value = read(out / 'prepared.json')
            require(value['passed'] and value['manifestSHA256'] == receipt['manifestSHA256'], 'Preparation result mismatched')
            receipt['candidateSHA256'] = value['candidateSHA256']
            expected = read(out / 'candidate.json')
        else:
            contract, value, expected = prepared()
            receipt['candidateSHA256'] = value['candidateSHA256']
            require(inventory(WORKSPACE) == expected, 'Full compilation context changed before phase')
            if phase == 'helper':
                receipt['details'] = build_helper(out)
            else:
                preceding('helper', value['candidateSHA256'])
                require_helper(RUN / 'helper')
                os.chdir(WORKSPACE / 'provider-swift')
                argv = ['swift', 'test' if phase == 'tests' else 'build', '-j', '2', '--disable-automatic-resolution', '--disable-build-manifest-caching']
                if phase == 'tests':
                    evidence = out / 'owned-native-evidence'
                    evidence.mkdir(mode=0o700)
                    os.environ['DARKBLOOM_NATIVE_MEMBER_FIXTURE'] = str(RUN / 'helper/native-member-fixture')
                    os.environ['DARKBLOOM_NATIVE_MEMBER_EVIDENCE'] = str(evidence)
                    argv += ['--filter', read(BASE / 'test-coverage.json')['swiftFilter']]
                else:
                    preceding('tests', value['candidateSHA256'])
                    argv += ['--product', 'darkbloom']
                receipt['execution'] = run_owned(argv, out, 'execution', 900)
                if phase == 'tests':
                    receipt['details'] = completion((out / 'execution.stdout').read_text() + '\n' + (out / 'execution.stderr').read_text())
                else:
                    binary = WORKSPACE / 'provider-swift/.build/debug/darkbloom'
                    receipt['details'] = dict(binarySHA256=sha(binary), bytes=binary.stat().st_size, binaryExecuted=False, signedForRelease=False)
        inputs()
        source_contract(WORKSPACE)
        require(inventory(WORKSPACE) == expected, 'Complete source/dependency context changed')
        receipt['passed'] = True
    except BaseException as error:
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, limits)
        if (out / 'execution.json').exists():
            receipt['executionSHA256'] = sha(out / 'execution.json')
        try:
            if expected is not None:
                actual = inventory(WORKSPACE)
                save(out / 'inventory-terminal.json', actual)
                receipt['terminalInventoryMatchesCandidate'] = actual == expected
                require(actual == expected, 'Terminal compilation context changed')
        except BaseException as error:
            receipt['passed'] = False
            receipt['terminalRecheckFailure'] = type(error).__name__ + ': ' + str(error)
            raise
        finally:
            save(out / 'receipt.json', receipt)
            lock.close()


if __name__ == '__main__':
    os.umask(0o077)
    main()
