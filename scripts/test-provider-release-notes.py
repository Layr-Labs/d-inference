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
import provider_release_notes as NOTES  # noqa: E402 - after the scripts directory is importable

REPOSITORY = 'Layr-Labs/d-inference'
INTRO = '# Changelog\n\nUnreleased changes live in `changelog.d/`.\n'
# Every pull request of the synthetic history: (title, author).
PULLS = {
    11: ('Add feature A <b>bold</b>', 'alice'), 12: ('Add feature B', 'bob'), 13: ('Sync master into dev', 'carol'),
    14: ('Add feature C with `--flag` and *stars*', 'alice'), 15: ('Add feature D', 'dave'),
    16: ('Add feature E', 'erin'),
    17: ('Add feature F', 'bob'), 18: ('Add feature G', 'erin'), 19: ('Add feature H', 'hank'),
    20: ('Fix master directly', 'frank'), 21: ('Fix master again', 'frank'), 22: ('Hotfix on master', 'grace'),
    30: ('Release dev into master: provider 1.1.0', 'david'), 31: ('Prepare provider 1.1.0', 'jonathan'),
    40: ('Release dev into master: provider 1.2.0', 'david'), 41: ('Prepare provider 1.2.0', 'jonathan'),
    42: ('Prepare provider 1.2.1', 'jonathan'), 50: ('Release dev into master: provider 1.3.0', 'david'),
    51: ('Prepare provider 1.3.0', 'jonathan'), 60: ('Prepare provider 1.4.0 from dev', 'jonathan'),
}
# Titles as the release page must show them: as typed, a code span kept as code.
RENDERED = {11: 'Add feature A \\<b\\>bold\\</b\\>', 14: 'Add feature C with `--flag` and \\*stars\\*'}
# Commit authors other than the fixture's own: GitHub noreply addresses, with and without an account ID.
AUTHORS = {12: 'Bob <1234+bob@users.noreply.github.com>', 20: 'Frank <frank@users.noreply.github.com>'}
# Each release of the synthetic history: what it lists through dev and directly
# on master, and the pull requests it names once as release pull requests.
RELEASES = {
    'v1.1.0': {'previous': 'v1.0.0', 'dev': [11, 12, 14], 'master': [20], 'release': [13, 30, 31]},
    'v1.2.0': {'previous': 'v1.1.0', 'dev': [15, 16], 'master': [21], 'release': [40, 41]},
    'v1.2.1': {'previous': 'v1.2.0', 'dev': [], 'master': [22], 'release': [42]},
    'v1.3.0': {'previous': 'v1.2.1', 'dev': [17, 18], 'master': [], 'release': [50, 51]},
    'v1.4.0': {'previous': 'v1.3.0', 'dev': [19], 'master': [], 'release': [60]},
}


def setUpModule():
    # provider_release_notes.py reads merges with git log --diff-merges (git 2.31).
    version = subprocess.run(['git', '--version'], capture_output=True, text=True, check=True).stdout.strip()
    if tuple(int(part) for part in re.findall(r'[0-9]+', version)[:2]) < (2, 31):
        raise RuntimeError(f'The release notes and these tests need git 2.31 or newer; this runner has {version}')


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

    def commit(self, message, author=None):
        self.git('add', '-A')
        self.git('commit', '-q', '-m', message, *(['--author', author] if author else []))
        return self.git('rev-parse', 'HEAD')

    def branch(self, name, start, author=None):
        self.git('switch', '-q', '-c', name, start)
        self.write(name.replace('/', '-') + '.txt', name + '\n')
        return self.commit(name, author)

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
        self.git('switch', '-q', into)
        self.git('merge', '-q', '--squash', head)
        author = AUTHORS.get(number)
        self.git('commit', '-q', '-m', f'{PULLS[number][0]} (#{number})', *(['--author', author] if author else []))
        return self.git('rev-parse', 'HEAD')

    def feature(self, number, into='dev', squash=False):
        name = f'feature/{number}'
        self.branch(name, into, None if squash else AUTHORS.get(number))
        return self.squash(number, name, into) if squash else self.merge(number, name, into)

    def snapshot(self, name, dev_commit):
        """The promotion head: dev at the carried commit, plus master's commits that dev lacks."""
        self.git('switch', '-q', '-c', name, dev_commit)
        self.git('merge', '-q', '--no-ff', 'master', '-m', 'Merge master into the dev-to-master release snapshot')
        return name

    def prepare(self, number, version, upgrade, start='master'):
        """The release preparation: renders the version's section and bumps the version.

        Cut from a dev commit instead of master, it also promotes that commit.
        """
        name = f'release/prepare-{version}'
        if start == 'master':
            self.git('switch', '-q', '-c', name, 'master')
        else:
            self.snapshot(name, start)
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
    """Five releases: two squash promotions, a hotfix without one, a merge-commit promotion, then a
    release whose preparation, cut from dev, is its only promotion."""
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

    history.feature(19)
    history.prepare(60, '1.4.0', 'Prepared on a dev snapshot.', start='dev')
    history.tag('v1.4.0')
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
    return SimpleNamespace(returncode=0, stdout=json.dumps({'data': {'repository': data}}), stderr='')


def graphql_forbidden(args):
    """GitHub's answer to a token without pull request access, such as the release job's."""
    numbers = re.findall(r'\bpr([0-9]+): issueOrPullRequest', next(arg for arg in args if arg.startswith('query=')))
    errors = [{'type': 'FORBIDDEN', 'path': ['repository', 'pr' + number],
               'message': 'Resource not accessible by integration'} for number in numbers]
    stdout = json.dumps({'data': {'repository': {'pr' + number: None for number in numbers}}, 'errors': errors})
    return SimpleNamespace(returncode=1, stdout=stdout, stderr='gh: Resource not accessible by integration')


def pull_line(number, author=True):
    """A listed pull request; author=None for no author, or a login other than GitHub's."""
    title, login = PULLS[number]
    login = login if author is True else author
    by = f' by @{login}' if login else ''
    return f'* {RENDERED.get(number, title)}{by} in https://github.com/{REPOSITORY}/pull/{number}'


class ReleasePublicationListsTheReleaseContents(unittest.TestCase):
    """The regression: a release whose dev pull requests reached master through one squash merge."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.history, self.work = build_history(self.base)

    def published_notes(self, tag, graphql=graphql_response):
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
                return graphql(args)
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

    def test_without_githubs_api_every_pull_request_is_listed_with_its_title_from_git(self):
        # The release job's token has no pull request access, so GitHub may refuse the title lookup.
        with patch('sys.stderr') as stderr:
            created = self.published_notes('v1.1.0', graphql=graphql_forbidden)
        lines = created['notes'].splitlines()
        # Titles from the merge commit's body or the squash's subject, as typed; an author only
        # where the pull request's own commit has a GitHub noreply address that names the login.
        for number, author in ((11, None), (12, 'bob'), (14, None), (20, 'frank')):
            self.assertIn(pull_line(number, author), lines)
        for number in RELEASES['v1.1.0']['release'] + [15]:
            self.assertFalse([line for line in lines if line.endswith(f'/pull/{number}')], number)
        self.assertIn('3 pull requests merged into `dev` reached `master` with #30, which promoted `dev` up to',
                      created['notes'])
        warning = ''.join(call.args[0] for call in stderr.write.call_args_list)
        self.assertIn('::warning::', warning)
        self.assertIn('titles from git', warning)
        self.assertIn('Resource not accessible by integration', warning)

    def test_a_failed_generation_still_publishes_the_release_and_says_so(self):
        with patch.object(NOTES.Repository, 'carried', side_effect=RuntimeError('no history')), \
                patch('sys.stderr') as stderr:
            notes = self.published_notes('v1.1.0')['notes']
        self.assertTrue(notes.startswith('## Provider v1.1.0 (Swift CLI)\n'))
        self.assertIn('could not be generated', notes)
        self.assertIn('scripts/provider_release_notes.py --tag v1.1.0', notes)
        self.assertIn('::warning::', ''.join(call.args[0] for call in stderr.write.call_args_list))


class ReleaseContents(unittest.TestCase):
    """Each release of the synthetic history, against its own contents."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.history, cls.work = build_history(Path(cls.tmp.name))
        env = git_environment()
        cls.run_env = patch.dict(os.environ, env, clear=True)
        cls.run_env.start()

    @classmethod
    def tearDownClass(cls):
        cls.run_env.stop()
        cls.tmp.cleanup()

    def repository(self):
        return NOTES.Repository(directory=self.work)

    def contents(self, tag):
        return NOTES.release_contents(self.repository(), tag, RELEASES[tag]['previous'], tag[1:])

    def test_each_release_lists_its_own_pull_requests_once(self):
        for tag, expected in RELEASES.items():
            with self.subTest(tag=tag):
                contents = self.contents(tag)
                self.assertEqual([c.number for c in contents.dev], expected['dev'])
                self.assertEqual([c.number for c in contents.master], expected['master'])
                rollups = [c.number for c, _ in contents.promotions] + [c.number for c in contents.preparations]
                rollups += [c.number for c in contents.syncs]
                self.assertEqual(sorted(rollups), expected['release'])
                self.assertEqual(contents.unreferenced, [])

    def test_the_carried_commit_is_the_promoted_dev_commit_not_the_newest_in_the_window(self):
        carried = self.contents('v1.1.0').carried
        self.assertEqual(self.history.git('log', '-1', '--format=%s', carried), f'{PULLS[14][0]} (#14)')
        # #15 merged into dev after that commit and before the promotion merged: inside
        # the release's date window, it is not in the release and waits for the next one.
        times = dict(line.split('\t', 1)[::-1] for line in
                     self.history.git('log', '--all', '--format=%ct\t%s').splitlines())
        self.assertLess(times['Merge pull request #15 from Layr-Labs/feature/15'],
                        times['Release dev into master: provider 1.1.0 (#30)'])
        self.assertNotIn(15, [c.number for c in self.contents('v1.1.0').dev])
        self.assertIn(15, [c.number for c in self.contents('v1.2.0').dev])

    def test_a_hotfix_release_carries_what_the_squash_release_before_it_carried(self):
        hotfix = self.contents('v1.2.1')
        self.assertEqual(hotfix.carried, self.contents('v1.2.0').carried)
        self.assertEqual(hotfix.dev, [])
        # Without that, the next release would list v1.1.0's and v1.2.0's dev pull requests again.
        self.assertEqual([c.number for c in self.contents('v1.3.0').dev], [17, 18])

    def test_a_merge_commit_promotion_is_a_release_pull_request(self):
        contents = self.contents('v1.3.0')
        self.assertEqual([c.number for c, _ in contents.promotions], [50])
        self.assertEqual([c.number for c in contents.preparations], [51])

    def test_an_unmerged_promotion_head_can_stand_in_for_a_dry_run(self):
        # Before v1.2.0's promotion merged: a local squash of its snapshot onto master
        # after #21, as pull request #99, which has no refs/pull head on the remote.
        snapshot = self.history.git('rev-parse', 'release/dev-to-master-2')
        squash = self.history.git('commit-tree', snapshot + '^{tree}', '-p', 'v1.2.0^{commit}~2', '-m',
                                  'Release dev into master: provider 1.2.0 (#99)', cwd=self.work)
        repository = NOTES.Repository(directory=self.work, pull_heads={99: snapshot})
        contents = NOTES.release_contents(repository, squash, 'v1.1.0', '1.2.0')
        self.assertEqual([c.number for c in contents.dev], [15, 16])
        self.assertEqual([c.number for c in contents.master], [21])
        self.assertEqual([c.number for c, _ in contents.promotions], [99])
        self.assertEqual(contents.preparations, [])

    def test_body_names_routes_rollups_and_the_compare_link(self):
        pulls = {number: {'title': title, 'author': author, 'url': ''} for number, (title, author) in PULLS.items()}
        contents, body, _ = NOTES.release_body('## Provider v1.1.0 (Swift CLI)\n', 'v1.1.0', REPOSITORY,
                                            self.repository(), lookup=lambda wanted: pulls)
        self.assertIn('3 pull requests merged into `dev` reached `master` with #30, which promoted `dev` up to '
                      f'`{contents.carried[:10]}`:', body)
        self.assertIn('1 pull request merged directly into `master`:', body)
        self.assertIn(f'3 release pull requests, not listed above: #30 promoted `dev` up to `{contents.carried[:10]}`; '
                      '#31 prepared the release; #13 merged `master` into `dev`.', body)
        self.assertLess(body.index('## What\'s new in v1.1.0'), body.index('## Pull requests in this release'))

    def test_dev_pull_requests_that_a_preparation_promoted_are_listed(self):
        # v1.4.0's only promotion is its Prepare pull request, cut from dev: named once as the
        # preparation, it is still the commit its dev pull requests reached master with.
        pulls = {number: {'title': title, 'author': author, 'url': ''} for number, (title, author) in PULLS.items()}
        contents, body, _ = NOTES.release_body('', 'v1.4.0', REPOSITORY, self.repository(),
                                               lookup=lambda wanted: pulls)
        lines = body.splitlines()
        self.assertIn(pull_line(19), lines)
        self.assertIn('1 pull request merged into `dev` reached `master` with #60, which promoted `dev` up to '
                      f'`{contents.carried[:10]}`:', lines)
        self.assertIn('1 release pull request, not listed above: #60 prepared the release.', lines)
        self.assertNotIn(pull_line(60), lines)

    def test_githubs_title_and_author_come_first_when_github_answers(self):
        pulls = {number: {'title': title, 'author': author, 'url': ''} for number, (title, author) in PULLS.items()}
        pulls[11] = {'title': 'Renamed after the merge', 'author': 'alice', 'url': ''}
        _, body, source = NOTES.release_body('', 'v1.1.0', REPOSITORY, self.repository(), lookup=lambda wanted: pulls)
        self.assertIn(f'* Renamed after the merge by @alice in https://github.com/{REPOSITORY}/pull/11', body)
        self.assertIn(pull_line(12), body.splitlines())
        self.assertEqual(source, 'GitHub')

    def test_titles_from_git_on_request(self):
        def refuse(wanted):
            raise AssertionError('GitHub was asked')
        _, body, source = NOTES.release_body('', 'v1.1.0', REPOSITORY, self.repository(), lookup=refuse,
                                             use_github=False)
        for number, author in ((11, None), (12, 'bob'), (14, None), (20, 'frank')):
            self.assertIn(pull_line(number, author), body.splitlines())
        self.assertEqual(source, 'git (GitHub not asked)')

    def test_a_git_failure_says_what_git_said(self):
        # The release job's warning carries the message, so it must say why git failed.
        with patch.dict(os.environ, {'LC_ALL': 'C'}), self.assertRaisesRegex(RuntimeError, 'unknown revision'):
            NOTES.Repository(directory=self.work, dev='no-such-branch', fetch=False)

    def test_a_number_that_names_no_pull_request_is_a_commit_without_one(self):
        pulls = {number: {'title': title, 'author': author, 'url': ''} for number, (title, author) in PULLS.items()
                 if number != 20}
        _, body, _ = NOTES.release_body('', 'v1.1.0', REPOSITORY, self.repository(), lookup=lambda wanted: pulls)
        self.assertIn('1 commit without a pull request:', body)
        self.assertIn('* Fix master directly (#20) (https://github.com/Layr-Labs/d-inference/commit/', body)
        self.assertNotIn('merged directly into `master`', body)


class ChangelogSection(unittest.TestCase):
    TEXT = (INTRO + '\n## v1.1.0 — candidate (unpublished)\n\n'
            'Prepared on 2026-02-01; tagging and publication are separate steps.\n\n'
            '### Upgrade and rollout notes\n\n- Update both Macs.\n\n### Feature\n\n- A.\n\n'
            '```text\n## v1.0.0 inside a fence\n```\n\n## v1.0.0\n\nPublished 2026-01-01.\n')

    def test_the_candidate_heading_and_note_are_left_out_and_every_entry_kept(self):
        section = NOTES.changelog_section(self.TEXT, '1.1.0')
        self.assertEqual(section, '### Upgrade and rollout notes\n\n- Update both Macs.\n\n### Feature\n\n- A.\n\n'
                                  '```text\n## v1.0.0 inside a fence\n```')
        self.assertEqual(NOTES.changelog_section(self.TEXT, '1.0.0'), 'Published 2026-01-01.')
        self.assertIsNone(NOTES.changelog_section(self.TEXT, '1.1'))
        self.assertIsNone(NOTES.changelog_section(self.TEXT, '1.2.0'))

    def test_a_body_over_githubs_limit_keeps_the_upgrade_notes_and_every_pull_request(self):
        section = NOTES.changelog_section(self.TEXT.replace('- A.', '- A.\n' + 'x' * 500), '1.1.0')
        commit = NOTES.Commit('a' * 40, ('b' * 40,), 'Fix (#20)')
        contents = NOTES.Contents(master=[commit])
        pulls = {20: {'title': 'Fix', 'author': 'frank', 'url': ''}}
        render = lambda limit: NOTES.render('## Header\n', contents, pulls, section, tag='v1.1.0', previous='v1.0.0',
                                            version='1.1.0', repository=REPOSITORY, limit=limit)
        full = render(NOTES.GITHUB_BODY_LIMIT)
        self.assertIn('x' * 500, full)
        shorter = render(len(full) - 1)
        self.assertNotIn('x' * 500, shorter)
        self.assertIn('- Update both Macs.', shorter)
        self.assertIn(f'The entries are in [CHANGELOG.md](https://github.com/{REPOSITORY}/blob/v1.1.0/CHANGELOG.md).',
                      shorter)
        self.assertIn(f'* Fix by @frank in https://github.com/{REPOSITORY}/pull/20', shorter)
        self.assertLessEqual(len(shorter), len(full) - 1)
        with self.assertRaisesRegex(ValueError, 'limit'):
            render(10)


class UntrustedText(unittest.TestCase):
    """Titles and commit subjects are plain text on the release page, and GitHub's answer is checked."""

    def test_titles_and_subjects_render_as_literal_text(self):
        # v0.10.7's page shows #1650 "Gemma 4 and <think> models: …" as "Gemma 4 and  models: …".
        # A code span already shows its text as typed, so `--rollback` in #1729's title stays code.
        contents = NOTES.Contents(master=[NOTES.Commit('a' * 40, ('b' * 40,), 'Fix (#20)')],
                                  unreferenced=[NOTES.Commit('c' * 40, ('d' * 40,), 'Revert <b>[x](y)</b> ``z`')])
        pulls = {20: {'title': '<!-- hide [link](https://example.com) *a* _b_ `<think>` <think> \\d',
                      'author': 'frank', 'url': ''}}
        lines = NOTES.render('', contents, pulls, None, tag='v1.1.0', previous='v1.0.0', version='1.1.0',
                             repository=REPOSITORY).splitlines()
        self.assertIn('* \\<!-- hide \\[link\\](https://example.com) \\*a\\* \\_b\\_ `<think>` \\<think\\> \\\\d '
                      f'by @frank in https://github.com/{REPOSITORY}/pull/20', lines)
        self.assertIn(f'* Revert \\<b\\>\\[x\\](y)\\</b\\> \\`\\`z\\` (https://github.com/{REPOSITORY}/commit/{"c" * 40})',
                      lines)

    def test_a_github_error_other_than_an_unknown_number_fails_the_lookup(self):
        def answer(error_type):
            data = {'pr20': {'__typename': 'PullRequest', 'number': 20, 'title': 'Fix', 'url': '',
                             'author': {'login': 'frank'}}, 'pr99': None}
            errors = [{'type': error_type, 'path': ['repository', 'pr99'], 'message': 'pr99 failed'}]
            stdout = json.dumps({'data': {'repository': data}, 'errors': errors})
            return SimpleNamespace(returncode=1, stdout=stdout, stderr='')
        with patch('subprocess.run', return_value=answer('NOT_FOUND')):
            self.assertEqual(list(NOTES.github_pull_requests(REPOSITORY, [20, 99])), [20])
        # Otherwise a pull request would be listed as a commit without one.
        with patch('subprocess.run', return_value=answer('FORBIDDEN')), self.assertRaisesRegex(RuntimeError, 'FORBIDDEN'):
            NOTES.github_pull_requests(REPOSITORY, [20, 99])


if __name__ == '__main__':
    unittest.main()
