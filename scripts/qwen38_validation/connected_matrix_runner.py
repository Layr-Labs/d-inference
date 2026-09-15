"""Run unchanged API oracles through Go, bind drain metrics to its SAME native engine.

No model launch or inference via the local metrics endpoint. Requests go only to
the coordinator origin. Native metric reads use the separate authenticated
loopback listener in the same unified provider process. No output/oracle repair.
"""
import argparse
from contextlib import contextmanager
import importlib
import json
import os
from pathlib import Path
import runpy
import sys
import time

HARNESS = Path(__file__).resolve().parent
COUNTS = dict(api_matrix=12, responses_matrix=10, reasoning_on_matrix=20,
              invalid_reasoning_matrix=14, multi_tool_matrix=4)


def verdict(suite, summary, code):
    rows = summary if isinstance(summary, list) else (summary or {}).get('cases', [])
    required = [row for row in rows if row.get('required', True)]
    expected = 19 if suite == 'reasoning_on_matrix' else COUNTS[suite]
    passed = code == 0 and len(rows) == COUNTS[suite] and len(required) == expected \
        and all(row.get('passed') is True for row in required)
    if isinstance(summary, dict):
        passed = passed and summary.get('passed') is True
    return dict(passed=passed, exit_code=code, rows=len(rows), required_rows=len(required))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=COUNTS, required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    assert args.output.is_absolute()
    args.output.mkdir(mode=0o700, exist_ok=False)
    sys.path.insert(0, str(HARNESS))
    import endpoint_config
    import lifecycle_matrix
    from api_matrix import MODEL
    assert MODEL == 'DarkBloom/Qwen3.8-Flash-Next-Q4-mtp'
    for name in ['endpoint_config', 'lifecycle_matrix', 'api_matrix']:
        assert Path(importlib.import_module(name).__file__).resolve().parent == HARNESS
    coordinator = endpoint_config.base_url()
    endpoint_config.headers()  # Enforce private file ownership/mode without printing its value.
    native_url = os.environ['QWEN4_NATIVE_METRICS_URL']
    native_key = os.environ['QWEN4_NATIVE_METRICS_KEY_FILE']
    assert native_url != coordinator
    mode = os.environ['DARKBLOOM_FLASH_NEXT_MATRIX_MTP']
    assert mode in ('off', 'auto')
    original_metrics = lifecycle_matrix.metrics

    @contextmanager
    def native_transport():
        original = {key: os.environ[key] for key in (endpoint_config.BASE_VARIABLE, endpoint_config.KEY_VARIABLE)}
        os.environ[endpoint_config.BASE_VARIABLE] = native_url
        os.environ[endpoint_config.KEY_VARIABLE] = native_key
        try:
            endpoint_config.base_url(); endpoint_config.headers()
            yield
        finally:
            os.environ.update(original)

    def metrics():
        with native_transport():
            return original_metrics()

    # Keep the existing metric parser and exact four-field drain oracle. Only
    # the transport binding changes; its values come from the actual provider.
    lifecycle_matrix.metrics = metrics
    def save(name, value):
        with (args.output / name).open('x') as file:
            json.dump(value, file, indent=2)
    def ready():
        deadline = time.monotonic() + 20
        while True:
            sample = metrics()
            lifecycle_matrix.require_posture(sample, cached=False)
            assert lifecycle_matrix.metric(sample, 'mtp_active') == int(mode == 'auto')
            if all(lifecycle_matrix.metric(sample, name) == 0 for name in lifecycle_matrix.DRAIN_FIELDS):
                return sample
            assert time.monotonic() < deadline, 'Actual native requests/pages did not drain'
            time.sleep(0.2)
    save('binding.json', dict(scope=__doc__, model=MODEL, mode=mode, coordinator=coordinator,
        native_metrics=native_url, suite=args.suite, planned_rows=COUNTS[args.suite],
        required_rows=19 if args.suite == 'reasoning_on_matrix' else COUNTS[args.suite]))
    save('before.metrics.json', ready())
    script = HARNESS / (args.suite + '.py')
    sys.argv = [str(script), '--output', str(args.output / 'cases')]
    code = 1
    try:
        try:
            runpy.run_path(str(script), run_name='__main__')
            code = 0
        except SystemExit as result:
            code = result.code or 0
    finally:
        assert endpoint_config.base_url() == coordinator
        save('after.metrics.json', ready())
        summary_path = args.output / 'cases/summary.json'
        summary = json.loads(summary_path.read_text()) if summary_path.is_file() else None
        result = verdict(args.suite, summary, code)
        save('summary.json', dict(**result, source_summary=str(summary_path), scope=__doc__))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
