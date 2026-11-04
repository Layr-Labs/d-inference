#!/usr/bin/env python3
"""A release's GitHub notes from what the release contains.

A change reaches master two ways: a pull request merged into master, or a
promotion of dev into master. A merge-commit promotion keeps the dev commits in
master's history. A squash promotion keeps only its own commit, but its head
(refs/pull/N/head, which GitHub keeps after the merge) still holds the dev
history it carried. A release therefore carries the newest dev first-parent
commit that its tag or one of its promotion heads contains. Its dev pull
requests are the ones on dev's first-parent chain after the commit the previous
release carried, up to that one: not every pull request merged in a date window.

Promotions, release preparations and syncs of master into dev are release pull
requests: the notes name them once instead of listing them as changes.
"""
import argparse
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import subprocess
import sys

from changelog import headings

# GitHub refuses a release body longer than this many characters.
GITHUB_BODY_LIMIT = 125_000
STABLE_TAG = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')
MERGED_PULL = re.compile(r'Merge pull request #([1-9][0-9]*) from ')
SQUASHED_PULL = re.compile(r'\(#([1-9][0-9]*)\)$')
# The candidate note of an unpublished CHANGELOG.md section; the published section replaces it.
CANDIDATE_NOTE = re.compile(r'Prepared on [0-9]{4}-[0-9]{2}-[0-9]{2}; tagging and publication are separate steps\.')
UPGRADE_NOTES = 'Upgrade and rollout notes'
# A code span (kept: markdown shows its text as typed), or a character escaped in titles and subjects
# outside one: HTML, links and images, emphasis and stray backticks. "#N" and "@login" stay references.
MARKDOWN_TEXT = re.compile(r'(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)|([\\`*_\[\]<>])')
GRAPHQL_BATCH = 100
# A GitHub noreply commit address, which names the account: [<ID>+]<login>@users.noreply.github.com.
NOREPLY = re.compile(r'(?:[0-9]+\+)?([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)@users\.noreply\.github\.com')
# Earlier releases searched for what a release without a promotion carries.
HOTFIX_RELEASES = 4


@dataclass(frozen=True)
class Commit:
    sha: str
    parents: tuple
    subject: str
    body: str = ''
    email: str = ''

    @property
    def number(self):
        match = MERGED_PULL.match(self.subject) or SQUASHED_PULL.search(self.subject)
        return int(match[1]) if match else None


@dataclass
class Contents:
    """One release's commits by route, each list in merge order."""
    dev: list = field(default_factory=list)            # pull requests merged into dev and promoted
    master: list = field(default_factory=list)         # pull requests merged directly into master
    unreferenced: list = field(default_factory=list)   # commits that name no pull request
    promotions: list = field(default_factory=list)     # (commit, dev commit it carried)
    preparations: list = field(default_factory=list)
    syncs: list = field(default_factory=list)
    promoted_by: list = field(default_factory=list)    # every commit whose head carried dev, a preparation included
    carried: str = ''
    previous_carried: str = ''


def stable_version(tag):
    match = STABLE_TAG.fullmatch(tag)
    return tuple(int(part) for part in match.groups()) if match else None


class Repository:
    """History queries. Fetching updates the remote's dev ref and reads PR heads as objects, without refs."""

    def __init__(self, directory=None, dev='origin/dev', remote='origin', fetch=True, pull_heads=None):
        self.directory = directory
        self.remote = remote
        self.fetch = fetch
        self.heads = dict(pull_heads or {})
        if fetch:
            self.git('fetch', '--quiet', '--no-tags', remote, f'+refs/heads/dev:refs/remotes/{remote}/dev')
        self.chain = self.git('rev-list', '--first-parent', dev).split()
        self.ancestry = {}
        self.mainline = {}
        self.windows = {}
        self.releases = {}

    def git(self, *args):
        result = subprocess.run(['git', *args], cwd=self.directory, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f'git {args[0]} failed: {result.stderr.strip()}')
        return result.stdout

    def commits(self, *args):
        output = self.git('log', '--format=%H%x1f%P%x1f%s%x1f%b%x1f%ae%x1e', *args)
        return [Commit(sha, tuple(parents.split()), subject, body, email) for sha, parents, subject, body, email in
                (record.strip('\n').split('\x1f') for record in output.split('\x1e') if record.strip())]

    def first_own_email(self, commit):
        """The author address of a merged pull request's oldest commit that is not a merge."""
        emails = self.git('log', '--no-merges', '--topo-order', '--format=%ae', *commit.parents[1:],
                          '--not', commit.parents[0])
        return (emails.split() or [''])[-1]

    def ancestors(self, commit):
        if commit not in self.ancestry:
            self.ancestry[commit] = set(self.git('rev-list', commit).split())
        return self.ancestry[commit]

    def carried(self, commit):
        """Position on dev's first-parent chain (newest first) of the newest commit `commit` contains."""
        ancestors = self.ancestors(commit)
        return next((position for position, sha in enumerate(self.chain) if sha in ancestors), len(self.chain))

    def fetch_pull_heads(self, numbers):
        wanted = sorted({number for number in numbers if number not in self.heads})
        if not wanted:
            return
        found = {}
        if self.fetch:
            listing = self.git('ls-remote', self.remote, *(f'refs/pull/{number}/head' for number in wanted))
            for line in listing.splitlines():
                sha, ref = line.split('\t')
                found[int(ref.split('/')[2])] = sha
            if found:
                self.git('fetch', '--quiet', '--no-tags', '--no-write-fetch-head', self.remote,
                         *(f'refs/pull/{number}/head' for number in found))
        for number in wanted:
            self.heads[number] = found.get(number)

    def previous_release(self, version, commit):
        """The newest stable release tag below `version` that `commit` contains."""
        tags = sorted((stable_version(tag), tag) for tag in self.git('tag', '--list', 'v*').split()
                      if stable_version(tag) and stable_version(tag) < version)
        for _, tag in reversed(tags):
            if subprocess.run(['git', 'merge-base', '--is-ancestor', tag, commit], cwd=self.directory,
                              capture_output=True).returncode == 0:
                return tag
        return None

    def window(self, previous, target):
        """master's first-parent commits after `previous` up to `target`, and the promotions among them.

        A promotion is a pull request whose head holds dev commits that master
        did not have: the merge commit's other parents, or a squash's PR head.
        """
        key = (previous, target)
        if key not in self.windows:
            commits = self.commits('--first-parent', '--reverse', f'{previous}..{target}')
            self.fetch_pull_heads(c.number for c in commits if len(c.parents) == 1 and c.number)
            promotions = {}
            for commit in commits:
                heads = commit.parents[1:] or [self.heads.get(commit.number)]
                heads = [head for head in heads if head]
                if not heads:
                    continue
                carried = min(self.carried(head) for head in heads)
                if carried < self.carried(commit.parents[0]):
                    promotions[commit.sha] = carried
            self.windows[key] = commits, promotions
        return self.windows[key]

    def release_carried(self, tag, previous=None, depth=0):
        """Position of the newest dev commit that release `tag` carries.

        A release without a promotion (a hotfix) carries what its previous
        release carried, which its tag alone need not contain. The search
        stops after HOTFIX_RELEASES releases in a row without a promotion,
        where the tag's own history stands for what it carries.
        """
        key = (tag, previous)
        if key not in self.releases:
            previous = previous or self.previous_release(stable_version(tag), tag)
            positions = [self.carried(tag)]
            if previous:
                _, promotions = self.window(previous, tag)
                positions += promotions.values()
                if not promotions and depth < HOTFIX_RELEASES:
                    positions.append(self.release_carried(previous, depth=depth + 1))
            self.releases[key] = min(positions)
        return self.releases[key]

    def preparations(self, version, *range_args):
        """The first-parent commits of a range that add the version's CHANGELOG.md section heading."""
        heading = re.compile(r'\+## v' + re.escape(version) + r'(?:\s|$)')
        output = self.git('log', '--first-parent', '--diff-merges=first-parent', '-p', '-U0', '--format=%x00%H',
                          *range_args, '--', 'CHANGELOG.md')
        found = set()
        for record in output.split('\x00')[1:]:
            sha, _, patch = record.partition('\n')
            if any(heading.match(line) for line in patch.splitlines()):
                found.add(sha.strip())
        return found

    def is_sync(self, commit, target):
        """A merge into dev of master's own commits: it brings a commit of master's first-parent chain,
        and every commit it brings that is not a merge is history of that master commit."""
        if len(commit.parents) < 2:
            return False
        if target not in self.mainline:
            self.mainline[target] = set(self.git('rev-list', '--first-parent', target).split())
        brought = self.git('rev-list', *commit.parents[1:], '--not', commit.parents[0]).split()
        newest = next((sha for sha in brought if sha in self.mainline[target]), None)
        if newest is None:
            return False
        own = self.git('rev-list', '--no-merges', *commit.parents[1:], '--not', commit.parents[0]).split()
        return set(own) <= self.ancestors(newest)


def release_contents(repository, target, previous, version):
    """What release `target` contains beyond release `previous`."""
    commits, promotions = repository.window(previous, target)
    carried = repository.release_carried(target, previous)
    previous_carried = repository.release_carried(previous)
    chain = repository.chain
    contents = Contents(carried=chain[carried] if carried < len(chain) else '',
                        previous_carried=chain[previous_carried] if previous_carried < len(chain) else '')
    preparations = repository.preparations(version, f'{previous}..{target}')
    dev = []
    if carried < previous_carried:
        stop = chain[previous_carried] if previous_carried < len(chain) else None
        dev = repository.commits('--first-parent', '--reverse', chain[carried], *(['--not', stop] if stop else []))
        preparations |= repository.preparations(version, chain[carried], *(['--not', stop] if stop else []))
    for commit in commits:
        # A preparation whose head held dev commits is named as the preparation, but it still
        # counts toward what the release carries, and its dev pull requests reached master with it.
        if commit.sha in promotions:
            contents.promoted_by.append(commit)
        if commit.sha in preparations:
            contents.preparations.append(commit)
        elif commit.sha in promotions:
            contents.promotions.append((commit, chain[promotions[commit.sha]]))
        elif commit.number:
            contents.master.append(commit)
        else:
            contents.unreferenced.append(commit)
    for commit in dev:
        if commit.sha in preparations:
            contents.preparations.append(commit)
        elif repository.is_sync(commit, target):
            contents.syncs.append(commit)
        elif commit.number:
            contents.dev.append(commit)
        else:
            contents.unreferenced.append(commit)
    # A pull request is listed once: merged into master, it is not listed again through dev.
    named = {c.number for c, _ in contents.promotions} | {c.number for c in contents.preparations + contents.syncs}
    contents.master = [c for c in unique(contents.master) if c.number not in named]
    named |= {c.number for c in contents.master}
    contents.dev = [c for c in unique(contents.dev) if c.number not in named]
    return contents


def unique(commits):
    seen = set()
    return [c for c in commits if not (c.number in seen or seen.add(c.number))]


def github_pull_requests(repository, numbers):
    """Title, author and URL of each number that is a pull request, from GitHub's GraphQL API."""
    owner, name = repository.split('/')
    found = {}
    numbers = sorted(set(numbers))
    for start in range(0, len(numbers), GRAPHQL_BATCH):
        fields = ' '.join(f'pr{n}: issueOrPullRequest(number: {n}) {{ __typename ... on PullRequest '
                          f'{{ number title url author {{ login }} }} }}' for n in numbers[start:start + GRAPHQL_BATCH])
        query = f'query($owner: String!, $name: String!) {{ repository(owner: $owner, name: $name) {{ {fields} }} }}'
        result = subprocess.run(['gh', 'api', 'graphql', '-f', 'query=' + query, '-f', 'owner=' + owner,
                                 '-f', 'name=' + name], capture_output=True, text=True)
        try:
            answer = json.loads(result.stdout)
            data = answer['data']['repository']
        except (ValueError, KeyError, TypeError) as error:
            raise RuntimeError(f'GitHub pull request query failed: {result.stderr.strip()}') from error
        # A number that is no issue or pull request answers null with a NOT_FOUND error, and gh exits 1.
        # Any other error could hide a pull request, which would then be listed as a commit without one.
        errors = [error for error in answer.get('errors') or [] if error.get('type') != 'NOT_FOUND']
        if errors:
            details = '; '.join(sorted({f"{error.get('type')}: {error.get('message')}" for error in errors}))
            raise RuntimeError(f'GitHub pull request query failed: {details}')
        for value in data.values():
            if value and value.get('__typename') == 'PullRequest':
                found[value['number']] = {'title': value['title'], 'url': value['url'],
                                          'author': (value.get('author') or {}).get('login')}
    return found


def git_pull_requests(history, commits, repository):
    """Title and author of each pull request from git, for when GitHub's API does not answer.

    GitHub writes a merge commit as "Merge pull request #N from <branch>", a blank line, then the
    title; a squash commit's subject is the title and " (#N)". The author is a login only where the
    pull request's oldest own commit (a squash: its commit) has a noreply address that names one.
    The newest commit of a branch is often someone else's merge of dev, so it does not stand in.
    """
    found = {}
    for commit in commits:
        if MERGED_PULL.match(commit.subject):
            title = next((line.strip() for line in commit.body.splitlines() if line.strip()), commit.subject)
            email = history.first_own_email(commit)
        else:
            title = SQUASHED_PULL.sub('', commit.subject).rstrip()
            email = commit.email
        login = NOREPLY.fullmatch(email)
        found[commit.number] = {'title': title, 'author': login[1] if login else None,
                                'url': f'https://github.com/{repository}/pull/{commit.number}'}
    return found


def changelog_section(text, version):
    """The version's CHANGELOG.md section without its heading or candidate note, or None."""
    lines = text.splitlines()
    marks = list(headings(text, 'CHANGELOG.md'))
    title = re.compile(r'v' + re.escape(version) + r'(?:\s.*)?')
    start = next((number for number, level, name in marks if level == 2 and title.fullmatch(name)), None)
    if start is None:
        return None
    end = next((number for number, level, _ in marks if number > start and level <= 2), len(lines) + 1)
    body = [line for line in lines[start:end - 1] if not CANDIDATE_NOTE.fullmatch(line.strip())]
    return '\n'.join(body).strip('\n')


def upgrade_notes(section):
    marks = list(headings(section, 'CHANGELOG.md'))
    lines = section.splitlines()
    start = next((number for number, level, name in marks if level == 3 and name == UPGRADE_NOTES), None)
    if start is None:
        return ''
    end = next((number for number, level, _ in marks if number > start and level <= 3), len(lines) + 1)
    return '\n'.join(lines[start - 1:end - 1]).strip('\n')


def literal(value):
    """Markdown that shows `value` as typed: a title or subject must not add links, HTML or formatting."""
    return MARKDOWN_TEXT.sub(lambda match: match[0] if match[1] else '\\' + match[2], value)


def pull_line(commit, pulls, repository):
    pull = pulls[commit.number]
    author = f" by @{pull['author']}" if pull['author'] else ''
    return f"* {literal(pull['title'])}{author} in https://github.com/{repository}/pull/{commit.number}"


def short(sha):
    return f'`{sha[:10]}`'


def name(commit):
    return f'#{commit.number}' if commit.number else short(commit.sha)


def numbers(commits):
    return ', '.join(name(c) for c in commits)


def count(number, noun):
    return f'{number} {noun}' + ('' if number == 1 else 's')


def render(header, contents, pulls, section, *, tag, previous, version, repository, limit=GITHUB_BODY_LIMIT):
    """The GitHub release body: the retained header, the changelog section and the pull requests."""
    # A number that names an issue, not a pull request, is a commit without a pull request.
    dev = [c for c in contents.dev if c.number in pulls]
    master = [c for c in contents.master if c.number in pulls]
    unreferenced = contents.unreferenced + [c for c in contents.dev + contents.master if c.number not in pulls]
    pulls_part = ['## Pull requests in this release', '']
    if dev:
        promoted = numbers(contents.promoted_by)
        route = f' with {promoted}, which promoted `dev`' if promoted else ''
        pulls_part += [f'{count(len(dev), "pull request")} merged into `dev` reached `master`{route} '
                       f'up to {short(contents.carried)}:', '']
        pulls_part += [pull_line(c, pulls, repository) for c in dev] + ['']
    if master:
        pulls_part += [f'{count(len(master), "pull request")} merged directly into `master`:', '']
        pulls_part += [pull_line(c, pulls, repository) for c in master] + ['']
    if unreferenced:
        pulls_part += [f'{count(len(unreferenced), "commit")} without a pull request:', '']
        pulls_part += [f'* {literal(c.subject)} (https://github.com/{repository}/commit/{c.sha})' for c in unreferenced]
        pulls_part += ['']
    rollups = [f'{name(c)} promoted `dev` up to {short(carried)}' for c, carried in contents.promotions]
    rollups += [f'{name(c)} prepared the release' for c in contents.preparations]
    rollups += [f'{name(c)} merged `master` into `dev`' for c in contents.syncs]
    if rollups:
        pulls_part += [f'{count(len(rollups), "release pull request")}, not listed above: {"; ".join(rollups)}.', '']
    pulls_part += [f'**Full Changelog**: https://github.com/{repository}/compare/{previous}...{tag}']
    link = f'https://github.com/{repository}/blob/{tag}/CHANGELOG.md'
    if section is None:
        variants = [f'`CHANGELOG.md` at {tag} has no section for v{version}.']
    else:
        variants = [section,
                    '\n\n'.join(part for part in (upgrade_notes(section), f'The entries are in [CHANGELOG.md]({link}).')
                                if part),
                    f'The release notes are in [CHANGELOG.md]({link}).']
    lead = [header.rstrip('\n'), ''] if header.strip() else []
    for changelog in variants:
        body = '\n'.join([*lead, f"## What's new in v{version}", '', changelog, '', *pulls_part]) + '\n'
        if len(body) <= limit:
            return body
    raise ValueError(f'The release notes exceed GitHub\'s {limit}-character limit even without the changelog')


def release_body(header, tag, repository, history, *, target=None, previous=None, version=None, lookup=None,
                 use_github=True):
    """The release's contents, its body and where the titles came from: GitHub, or git when GitHub
    does not answer (or use_github is false)."""
    target = target or tag
    version = version or tag.removeprefix('v')
    previous = previous or history.previous_release(stable_version('v' + version), target)
    if previous is None:
        raise ValueError(f'No release before v{version} in the history of {target}')
    contents = release_contents(history, target, previous, version)
    listed = contents.dev + contents.master
    source = 'git (GitHub not asked)'
    pulls = None
    if use_github:
        try:
            pulls = (lookup or (lambda found: github_pull_requests(repository, found)))([c.number for c in listed])
            source = 'GitHub'
        except Exception as error:  # noqa: BLE001 - git still names every pull request
            source = f'git (GitHub did not answer: {error})'
    if pulls is None:
        pulls = git_pull_requests(history, listed, repository)
    text = history.git('show', f'{target}:CHANGELOG.md')
    section = changelog_section(text, version)
    return contents, render(header, contents, pulls, section, tag=tag, previous=previous, version=version,
                            repository=repository), source


def write_release_notes(root, env):
    """Write the release body next to the retained header and return its path.

    The registration and the latest aliases are already published when this
    runs, so a failure here does not stop the GitHub release: its body says
    that the generated part is missing, and the job logs a warning.
    """
    tag = env.get('RELEASE_TAG') or env['GITHUB_REF_NAME']
    header = (root / 'release-notes.md').read_text()
    try:
        _, body, source = release_body(header, tag, env['GITHUB_REPOSITORY'], Repository())
        if source != 'GitHub':
            print(f'::warning::Release notes for {tag}: pull request titles from {source}. Authors are shown '
                  f"only where a commit's GitHub noreply address names them.", file=sys.stderr)
    except Exception as error:  # noqa: BLE001 - the release itself must still be published
        print(f'::warning::Release notes for {tag} lack the changelog and pull requests: {error}', file=sys.stderr)
        body = (header.rstrip('\n') + '\n\n' + f'The changelog section and pull request list could not be '
                f'generated. Regenerate them with `python3 scripts/provider_release_notes.py --tag {tag}`.\n')
    path = root / 'github-release-notes.md'
    path.write_text(body)
    return path


def summary(contents):
    """What the notes exclude and why, for review."""
    lines = [f'carried dev commit: {contents.carried} (previous release: {contents.previous_carried})',
             f'through dev: {len(contents.dev)} ({numbers(contents.dev)})',
             f'directly into master: {len(contents.master)} ({numbers(contents.master)})']
    lines += [f'promotion: {name(c)} carried dev up to {carried}' for c, carried in contents.promotions]
    lines += [f"preparation: {name(c)} adds the version's CHANGELOG.md section" for c in contents.preparations]
    lines += [f'sync: {name(c)} brings only commits master already has' for c in contents.syncs]
    lines += [f'without a pull request: {c.sha[:10]} {c.subject}' for c in contents.unreferenced]
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--tag', required=True, help='release tag the notes describe, for example v0.10.7')
    parser.add_argument('--target', help='commit standing in for the tag, for a dry run before tagging')
    parser.add_argument('--previous', help='previous release tag (default: the newest lower release tag it contains)')
    parser.add_argument('--dev', default='origin/dev', help='the dev branch (default: origin/dev)')
    parser.add_argument('--pull-head', action='append', default=[], metavar='N=COMMIT',
                        help="a pull request's head, for a promotion that is not merged yet")
    parser.add_argument('--no-fetch', action='store_true',
                        help="read only local objects; a squash promotion is then found only through --pull-head")
    parser.add_argument('--git-titles', action='store_true',
                        help="take titles and authors from git, as when GitHub's API does not answer")
    parser.add_argument('--repository', default='Layr-Labs/d-inference')
    parser.add_argument('--header-file', type=Path, help='retained header (default: none)')
    parser.add_argument('--output', type=Path, help='write the body here (default: standard output)')
    args = parser.parse_args()
    heads = {int(number): sha for number, sha in (item.split('=', 1) for item in args.pull_head)}
    history = Repository(dev=args.dev, fetch=not args.no_fetch, pull_heads=heads)
    header = args.header_file.read_text() if args.header_file else ''
    contents, body, source = release_body(header, args.tag, args.repository, history, target=args.target,
                                          previous=args.previous, version=args.tag.removeprefix('v'),
                                          use_github=not args.git_titles)
    print(summary(contents), file=sys.stderr)
    print(f'pull request titles from {source}', file=sys.stderr)
    if args.output:
        args.output.write_text(body)
    else:
        sys.stdout.write(body)


if __name__ == '__main__':
    main()
