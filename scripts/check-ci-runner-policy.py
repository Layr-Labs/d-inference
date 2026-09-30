#!/usr/bin/env python3
"""Check runner/credential boundaries. Requires PyYAML 6.0.3; no credentials."""
from pathlib import Path
import re
import sys

import yaml

ROOT = Path(__file__).resolve().parent.parent
TENKI = {'tenki-standard-medium-4c-8g', 'tenki-macos-26-large'}
BLACKSMITH_LINUX = 'blacksmith-4vcpu-ubuntu-2404'
BLACKSMITH_MAC_27 = 'blacksmith-12vcpu-macos-27'
BLACKSMITH_MAC_26 = 'blacksmith-12vcpu-macos-26'
BLACKSMITH_BENCHMARK = 'blacksmith-12vcpu-macos-latest'
BLACKSMITH = {BLACKSMITH_LINUX, BLACKSMITH_MAC_27, BLACKSMITH_MAC_26,
              BLACKSMITH_BENCHMARK}
PINNED_PYTHON_ACTION = 'actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97'
# Release inputs, credentials and write-capable jobs must stay on the reviewed
# Blacksmith images. The signed older-OS proof uses a separate macOS 26 image.
BLACKSMITH_JOBS = {
    'release-swift.yml': {
        'resolve-env': BLACKSMITH_LINUX,
        'build-provider': BLACKSMITH_MAC_27,
        'qualify-sdk': BLACKSMITH_MAC_27,
        'build-and-release': BLACKSMITH_MAC_27,
        'stage-release': BLACKSMITH_LINUX,
        'publish-release': BLACKSMITH_LINUX,
        'validate-older-macos': BLACKSMITH_MAC_26,
    },
    'provider-release-cache.yml': {'warm': BLACKSMITH_MAC_27},
    'provider-signing-validation.yml': {
        'build': BLACKSMITH_MAC_27,
        'signing': BLACKSMITH_MAC_27,
    },
    'register-model.yml': {'register': BLACKSMITH_LINUX},
    'claude.yml': {'claude': BLACKSMITH_LINUX},
    'threat-model-review.yml': {'review': BLACKSMITH_LINUX},
    'codex.yml': {'codex': BLACKSMITH_LINUX, 'post_feedback': BLACKSMITH_LINUX},
    'benchmarks.yml': {
        'approve': BLACKSMITH_LINUX,
        'benchmark': BLACKSMITH_BENCHMARK,
        'report': BLACKSMITH_LINUX,
    },
}
SECRET = re.compile(r'\$\{\{[^}]*\bsecrets\b', re.S)


def load(path):
    # BaseLoader keeps GitHub's `on` and scalar values as strings (YAML 1.2).
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


def strings(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    else:
        yield str(value)


def check(workflows, root=ROOT):
    errors = []
    for filename, workflow in workflows.items():
        jobs = workflow.get('jobs', {})
        for name, expected in BLACKSMITH_JOBS.get(filename, {}).items():
            if name not in jobs:
                errors.append(f'{filename}: missing Blacksmith job {name}')
            elif jobs[name].get('runs-on') != expected:
                errors.append(f'{filename}/{name}: must run on {expected}')
        for name, job in jobs.items():
            label = f'{filename}/{name}'
            runner = job.get('runs-on')
            if not isinstance(runner, str) or runner not in TENKI | BLACKSMITH:
                errors.append(f'{label}: runner must be an approved static label')
                continue
            if runner in BLACKSMITH and name not in BLACKSMITH_JOBS.get(filename, {}):
                errors.append(f'{label}: Blacksmith placement requires a policy entry')
            if runner in {BLACKSMITH_MAC_27, BLACKSMITH_MAC_26}:
                # /usr/bin/git uses xcrun on macOS. An image-specific app path
                # set at job scope can break checkout before any guard runs.
                if 'DEVELOPER_DIR' in workflow.get('env', {}) or 'DEVELOPER_DIR' in job.get('env', {}):
                    errors.append(f'{label}: select the image Xcode after checkout, not at job scope')
            if runner == BLACKSMITH_MAC_27:
                steps_for_python = job.get('steps', [])
                checkouts = [i for i, step in enumerate(steps_for_python)
                             if step.get('uses', '').startswith('actions/checkout@')]
                python = [i for i, step in enumerate(steps_for_python)
                          if step.get('uses') == PINNED_PYTHON_ACTION
                          and step.get('with', {}).get('python-version') == '3.12.10']
                last_checkout = max(checkouts, default=-1)
                first_helper = next((i for i, step in enumerate(steps_for_python)
                                     if i > last_checkout and
                                     (step.get('run') or step.get('uses', '').startswith('./'))), len(steps_for_python))
                if not checkouts or len(python) != 1 or not (last_checkout < python[0] < first_helper):
                    errors.append(f'{label}: pin Python 3.12.10 after checkout and before release helpers')
            # Benchmark compute remains read-only even though it needs a 48 GB
            # Blacksmith Mac. Every Tenki job has the same credential boundary.
            if runner not in TENKI and (filename, name) != ('benchmarks.yml', 'benchmark'):
                continue
            permissions = job.get('permissions', workflow.get('permissions'))
            if not isinstance(permissions, dict) or any(
                value not in {'read', 'none'} or (key == 'id-token' and value != 'none')
                for key, value in (permissions or {}).items()
            ):
                errors.append(f'{label}: explicit read-only permissions required; no OIDC')
            if 'environment' in job or 'secrets' in job or 'uses' in job:
                errors.append(f'{label}: environments, secret inheritance and reusable jobs are forbidden')
            scopes = [job, workflow.get('env', {}), workflow.get('defaults', {})]
            if any(SECRET.search(text) for scope in scopes for text in strings(scope)):
                errors.append(f'{label}: secrets context must not reach read-only runners')
            if runner == 'tenki-macos-26-large':
                env = {**workflow.get('env', {}), **job.get('env', {})}
                if env.get('DEVELOPER_DIR') != '/Applications/Xcode_27.0.app/Contents/Developer':
                    errors.append(f'{label}: explicitly select Xcode 27')

            def steps(items, seen=()):
                for step in items:
                    uses = step.get('uses', '')
                    if uses.startswith('actions/checkout@'):
                        if step.get('with', {}).get('persist-credentials') != 'false':
                            errors.append(f'{label}: checkout must discard credentials')
                    if uses.startswith('./'):
                        path = (root / uses).resolve()
                        if not path.is_relative_to(root.resolve()) or path in seen:
                            errors.append(f'{label}: invalid local action path or cycle')
                            continue
                        action_file = next((path / f for f in ('action.yml', 'action.yaml') if (path / f).is_file()), None)
                        if action_file is None:
                            errors.append(f'{label}: missing local action {uses}')
                            continue
                        action = load(action_file)
                        if any(SECRET.search(text) for text in strings(action)):
                            errors.append(f'{label}: local action references secrets')
                        if action.get('runs', {}).get('using') != 'composite':
                            errors.append(f'{label}: local action requires explicit policy review')
                        steps(action.get('runs', {}).get('steps', []), (*seen, path))
            steps(job.get('steps', []))
    return errors


if __name__ == '__main__':
    workflows = {p.name: load(p) for p in sorted((ROOT / '.github/workflows').glob('*.y*ml'))}
    problems = check(workflows)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        sys.exit(1)
    print('CI runner policy: Tenki jobs are read-only; release and credentialed jobs use pinned Blacksmith runners.')
