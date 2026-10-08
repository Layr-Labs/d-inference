from pathlib import Path
import datetime, hashlib, json, os, signal, subprocess, time
ROOT = Path(__file__).resolve().parent
PACKAGE = ROOT / 'workspace/libs/darkbloom-cluster'
RUN = ROOT / 'tests-1'
RUN.mkdir(exist_ok=False)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
inputs = [PACKAGE / 'Package.swift', PACKAGE / 'Package.resolved'] + sorted((PACKAGE / 'Sources').rglob('*.swift')) + sorted((PACKAGE / 'Tests').rglob('*.swift'))
pins = [{'path': str(path.relative_to(PACKAGE)), 'sha256': sha(path)} for path in inputs]
fixture = Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json')
assert sha(fixture) == '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25'
argv = ['swift', 'test', '--package-path', str(PACKAGE), '--jobs', '2', '--disable-index-store', '--disable-automatic-resolution', '--skip-update', '--filter', 'ResidentFacadeTests|ResidentRecordingTests']
environment = dict(os.environ)
environment['DARKBLOOM_RETAINED_PROFILE_FIXTURE'] = str(fixture)
started = time.monotonic()
record = {'argv': argv, 'atUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'sourcePinsBefore': pins, 'fixtureSHA256': sha(fixture), 'modelOrGPUExecution': False}
with (RUN / 'stdout.txt').open('xb') as stdout, (RUN / 'stderr.txt').open('xb') as stderr:
    process = subprocess.Popen(argv, cwd=PACKAGE, env=environment, stdout=stdout, stderr=stderr, start_new_session=True)
    try:
        code = process.wait(timeout=600)
    except BaseException as error:
        record['supervisionError'] = type(error).__name__
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
        code = process.returncode
        record['exitCode'] = code
        record['wallSeconds'] = time.monotonic() - started
        (RUN / 'execution.json').write_text(json.dumps(record, indent=2) + '\n')
        raise
record.update(exitCode=code, wallSeconds=time.monotonic()-started, stdoutSHA256=sha(RUN/'stdout.txt'), stderrSHA256=sha(RUN/'stderr.txt'), sourcePinsUnchanged=all(sha(PACKAGE/x['path'])==x['sha256'] for x in pins))
(RUN / 'execution.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({key: value for key, value in record.items() if key != 'sourcePinsBefore'}, indent=2))
print('receiptSHA256', sha(RUN / 'execution.json'))
raise SystemExit(code)
