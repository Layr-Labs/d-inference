#!/usr/bin/env python3
"""Check runner/credential boundaries. Requires PyYAML 6.0.3; no credentials."""
from pathlib import Path
import re
import sys

import yaml

ROOT = Path(__file__).resolve().parent.parent
TENKI = {'tenki-standard-medium-4c-8g', 'tenki-macos-26-large'}
GITHUB = {'ubuntu-24.04', 'xcode-27'}
BLACKSMITH = {'blacksmith-12vcpu-macos-latest'}
EXTERNAL = TENKI | BLACKSMITH
# Jobs entrusted with credentials or writes must never drift to a third party.
PROTECTED = {
    'release-swift.yml': {'resolve-env', 'build-and-release', 'stage-release', 'publish-release'},
    'provider-signing-validation.yml': {'signing'},
    'register-model.yml': {'register'},
    'claude.yml': {'claude'},
    'codex.yml': {'codex', 'post_feedback'},
    'benchmarks.yml': {'approve', 'report'},
    'ci.yml': {'runner-policy'},
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
        for required in PROTECTED.get(filename, set()):
            if required not in jobs:
                errors.append(f'{filename}: missing protected job {required}')
        for name, job in jobs.items():
            label = f'{filename}/{name}'
            runner = job.get('runs-on')
            if not isinstance(runner, str) or runner not in EXTERNAL | GITHUB:
                errors.append(f'{label}: runner must be an approved static label')
                continue
            if runner in BLACKSMITH and (filename, name) != ('benchmarks.yml', 'benchmark'):
                errors.append(f'{label}: Blacksmith is allowed only for the 48 GB benchmark')
            if name in PROTECTED.get(filename, set()) and runner not in GITHUB:
                errors.append(f'{label}: privileged job must use GitHub')
            if runner not in EXTERNAL:
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
                errors.append(f'{label}: secrets context must not reach external runners')
            if runner == 'tenki-macos-26-large' and name != 'validate-older-macos':
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
    print('CI runner policy: external jobs are read-only and contain no secret references; privileged jobs use GitHub.')
