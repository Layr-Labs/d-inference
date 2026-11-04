#!/usr/bin/env python3
"""Release notes list what a release contains, from a synthetic local history.

No network: the history is a local origin repository with refs/pull/N/head refs
like GitHub's, and pull request titles and authors are fixture data.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location('publication', SCRIPTS / 'provider-release-publication.py')
PUB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUB)

REPOSITORY = 'Layr-Labs/d-inference'
INTRO = '# Changelog\n\nUnreleased changes live in `changelog.d/`.\n'
# Every pull request of the synthetic history: (title, author).
PULLS = {
    11: ('Add feature A', 'alice'), 12: ('Add feature B', 'bob'), 13: ('Sync master into dev', 'carol'),
    14: ('Add feature C', 'alice'), 15: ('Add feature D', 'dave'), 16: ('Add feature E', 'erin'),
    17: ('Add feature F', 'bob'), 18: ('Add feature G', 'erin'), 20: ('Fix master directly', 'frank'),
    21: ('Fix master again', 'frank'), 22: ('Hotfix on master', 'grace'),
    30: ('Release dev into master: provider 1.1.0', 'david'), 31: ('Prepare provider 1.1.0', 'jonathan'),
    40: ('Release dev into master: provider 1.2.0', 'david'), 41: ('Prepare provider 1.2.0', 'jonathan'),
    42: ('Prepare provider 1.2.1', 'jonathan'), 50: ('Release dev into master: provider 1.3.0', 'david'),
    51: ('Prepare provider 1.3.0', 'jonathan'),
}
# Each release of the synthetic history: what it lists through dev and directly
# on master, and the pull requests it names once as release pull requests.
RELEASES = {
    'v1.1.0': {'previous': 'v1.0.0', 'dev': [11, 12, 14], 'master': [20], 'release': [13, 30, 31]},
    'v1.2.0': {'previous': 'v1.1.0', 'dev': [15, 16], 'master': [21], 'release': [40, 41]},
    'v1.2.1': {'previous': 'v1.2.0', 'dev': [], 'master': [22], 'release': [42]},
    'v1.3.0': {'previous': 'v1.2.1', 'dev': [17, 18], 'master': [], 'release': [50, 51]},
}


def git_environment():
    # Real local objects, but no machine-wide identity, hooks or signing tools.
    env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE'):
        env.pop(name, None)
    return env


class History:
    """A local origin with GitHub's shapes: merge-commit and squash pull requests, refs/pull/N/head and tags."""

    def __init__(self, directory):
        self.directory = directory
        self.origin = directory / 'origin'
        self.clock = 0
        self.origin.mkdir()
        self.git('init', '-q', '-b', 'master')
        self.write('CHANGELOG.md', INTRO + '\n## v1.0.0\n\nPublished 2026-01-01.\n\n### First release\n\n- First.\n')
        self.write('VERSION', '1.0.0\n')
        self.commit('Initial provider')
        self.git('tag', '-a', 'v1.0.0', '-m', 'v1.0.0')
        self.git('branch', 'dev')

    def git(self, *args, cwd=None):
        self.clock += 1
        date = f'@{1767225600 + self.clock * 600} +0000'
        env = dict(git_environment(), GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        command = ['git', '-c', 'user.name=Release Test', '-c', 'user.email=test@example.com',
                   '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', '-c', 'core.hooksPath=' + os.devnull]
        return subprocess.run(command + list(args), cwd=cwd or self.origin, env=env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, name, text):
        (self.origin / name).write_text(text)

    def commit(self, message):
        self.git('add', '-A')
        self.git('commit', '-q', '-m', message)
        return self.git('rev-parse', 'HEAD')

    def branch(self, name, start):
        self.git('switch', '-q', '-c', name, start)
        self.write(name.replace('/', '-') + '.txt', name + '\n')
        return self.commit(name)

    def merge(self, number, branch, into='dev'):
        """A pull request merged with a merge commit, as GitHub writes it."""
        self.git('update-ref', f'refs/pull/{number}/head', branch)
        self.git('switch', '-q', into)
        self.git('merge', '-q', '--no-ff', branch, '-m',
                 f'Merge pull request #{number} from Layr-Labs/{branch}\n\n{PULLS[number][0]}')
        return self.git('rev-parse', 'HEAD')

    def squash(self, number, head, into):
        """A pull request squash-merged: one commit on `into` with the merged tree, and no head ancestry."""
        self.git('update-ref', f'refs/pull/{number}/head', head)
        tree = self.git('merge-tree', '--write-tree', into, head).splitlines()[0]
        commit = self.git('commit-tree', tree, '-p', into, '-m', f'{PULLS[number][0]} (#{number})')
        self.git('switch', '-q', '--detach')
        self.git('update-ref', f'refs/heads/{into}', commit)
        self.git('switch', '-q', into)
        return commit

    def feature(self, number, into='dev', squash=False):
        name = f'feature/{number}'
        self.branch(name, into)
        return self.squash(number, name, into) if squash else self.merge(number, name, into)

    def snapshot(self, name, dev_commit):
        """The promotion head: dev at the carried commit, plus master's commits that dev lacks."""
        self.git('switch', '-q', '-c', name, dev_commit)
        self.git('merge', '-q', '--no-ff', 'master', '-m', 'Merge master into the dev-to-master release snapshot')
        return name

    def prepare(self, number, version, upgrade):
        """The release preparation: renders the version's section and bumps the version."""
        name = f'release/prepare-{version}'
        self.git('switch', '-q', '-c', name, 'master')
        text = (self.origin / 'CHANGELOG.md').read_text().removeprefix(INTRO)
        section = (f'\n## v{version} — candidate (unpublished)\n\n'
                   f'Prepared on 2026-02-01; tagging and publication are separate steps.\n\n'
                   f'### Upgrade and rollout notes\n\n- {upgrade}\n\n### Feature of {version}\n\n'
                   f'- Shipped in {version}.\n\n```text\n## not a heading inside a fence\n```\n')
        self.write('CHANGELOG.md', INTRO + section + text)
        self.write('VERSION', version + '\n')
        self.commit(f'Prepare provider {version}')
        return self.squash(number, name, 'master')

    def tag(self, name):
        self.git('tag', '-a', name, '-m', name, 'master')


def build_history(directory):
    """Four releases: two squash promotions, a hotfix without one, then a merge-commit promotion."""
    history = History(directory)
    history.feature(11)
    history.feature(20, into='master', squash=True)
    history.feature(12)
    history.git('switch', '-q', '-c', 'sync/master-into-dev', 'dev')
    history.git('merge', '-q', '--no-ff', 'master', '-m', 'Merge master into dev')
    history.merge(13, 'sync/master-into-dev')
    carried = history.feature(14, squash=True)
    history.snapshot('release/dev-to-master-1', carried)
    # Merged into dev after the snapshot was cut, while the promotion was in review:
    # inside the release's date window, but not in the release.
    history.feature(15)
    history.squash(30, 'release/dev-to-master-1', 'master')
    history.prepare(31, '1.1.0', 'Update both Macs of a pair to 1.1.0.')
    history.tag('v1.1.0')

    history.feature(16)
    history.feature(21, into='master', squash=True)
    history.snapshot('release/dev-to-master-2', 'dev')
    history.feature(17)
    history.squash(40, 'release/dev-to-master-2', 'master')
    history.prepare(41, '1.2.0', 'Nothing to do.')
    history.tag('v1.2.0')

    history.feature(22, into='master', squash=True)
    history.prepare(42, '1.2.1', 'A hotfix: no dev change.')
    history.tag('v1.2.1')

    history.feature(18)
    history.prepare(51, '1.3.0', 'Merge-commit promotion.')
    history.snapshot('release/dev-to-master-3', 'dev')
    history.merge(50, 'release/dev-to-master-3', into='master')
    history.tag('v1.3.0')
    history.git('switch', '-q', 'master')

    work = directory / 'work'
    history.git('clone', '-q', str(history.origin), str(work), cwd=directory)
    return history, work


def graphql_response(args):
    """Answer the pull request query from fixture data, as GitHub's GraphQL API answers it."""
    query = next(arg for arg in args if arg.startswith('query='))
    data = {}
    for number in map(int, re.findall(r'\bpr([0-9]+): issueOrPullRequest\(number: \1\)', query)):
        if number in PULLS:
            title, author = PULLS[number]
            data[f'pr{number}'] = {'__typename': 'PullRequest', 'number': number, 'title': title,
                                   'url': f'https://github.com/{REPOSITORY}/pull/{number}',
                                   'author': {'login': author}}
        else:
            data[f'pr{number}'] = {'__typename': 'Issue'}
    return json.dumps({'data': {'repository': data}})


def pull_line(number):
    title, author = PULLS[number]
    return f'* {title} by @{author} in https://github.com/{REPOSITORY}/pull/{number}'


class ReleasePublicationListsTheReleaseContents(unittest.TestCase):
    """The regression: a release whose dev pull requests reached master through one squash merge."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.history, self.work = build_history(self.base)

    def published_notes(self, tag):
        root = self.base / ('publication-' + tag)
        root.mkdir()
        bundle = root / PUB.BUNDLE
        bundle.write_bytes(b'exact signed bundle')
        (root / 'release-notes.md').write_text(f'## Provider {tag} (Swift CLI)\n\n**Signed and notarized:** yes\n')
        env = {'RELEASE_TAG': tag, 'GITHUB_REPOSITORY': REPOSITORY, 'VERSION': tag[1:]}
        created = {}
        release = {}
        real_run = subprocess.run

        def run(args, **kwargs):
            if args[0] == 'git':
                return real_run(args, **kwargs)
            if args[:3] == ['gh', 'api', 'graphql']:
                return SimpleNamespace(returncode=0, stdout=graphql_response(args), stderr='')
            op = args[2]
            if op == 'view':
                return SimpleNamespace(returncode=1 if not release else 0, stdout=json.dumps(release))
            if op == 'create':
                created['args'] = args
                created['notes'] = Path(args[args.index('--notes-file') + 1]).read_text()
                release.update(tagName=tag, isDraft=True, assets=[])
            elif op == 'upload':
                release['assets'] = [{'name': PUB.BUNDLE, 'state': 'uploaded'}]
            elif op == 'download':
                (Path(args[args.index('--dir') + 1]) / PUB.BUNDLE).write_bytes(bundle.read_bytes())
            elif op == 'edit':
                release['isDraft'] = False
            return SimpleNamespace(returncode=0, stdout='', stderr='')

        git_env = dict(git_environment(), GIT_DIR=str(self.work / '.git'), GIT_WORK_TREE=str(self.work))
        with patch.dict(os.environ, git_env, clear=True), patch('subprocess.run', side_effect=run):
            PUB.publish_github_release(root, PUB.BUNDLE, PUB.sha256(bundle), env, True)
        return created

    def test_squash_promoted_release_lists_every_constituent_dev_pull_request(self):
        created = self.published_notes('v1.1.0')
        notes = created['notes']
        lines = notes.splitlines()
        for number in RELEASES['v1.1.0']['dev'] + RELEASES['v1.1.0']['master']:
            self.assertIn(pull_line(number), lines)
        # GitHub's generated notes list only the pull requests merged into master.
        self.assertNotIn('--generate-notes', created['args'])
        self.assertTrue(notes.startswith('## Provider v1.1.0 (Swift CLI)\n\n**Signed and notarized:** yes\n'))
        # Rollups are named once, never listed as changes of their own.
        for number in RELEASES['v1.1.0']['release']:
            self.assertNotIn(pull_line(number), lines)
        # Merged into dev during the window, after the promoted dev commit.
        self.assertNotIn(pull_line(15), lines)
        self.assertIn('## What\'s new in v1.1.0', notes)
        self.assertIn('- Update both Macs of a pair to 1.1.0.', lines)
        self.assertIn(f'**Full Changelog**: https://github.com/{REPOSITORY}/compare/v1.0.0...v1.1.0', lines)


if __name__ == '__main__':
    unittest.main()
