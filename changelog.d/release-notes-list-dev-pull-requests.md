### Release pages list every pull request in the release

- A provider release page on GitHub now lists every pull request in the release, with its title, its author where known, and a link. This includes the pull requests that reached `master` through `dev` in a squash merge, which GitHub's generated list left out: the v0.10.7 page showed 5 of its 50 pull requests. Pull requests merged directly into `master` are listed separately. The promotion of `dev`, the release preparation and syncs of `master` into `dev` are named once, not listed as changes.
- When the release job cannot read pull requests through GitHub's API, the titles come from the merge commits, and an author is shown only where a commit's GitHub address names the account.
- The page also shows the release's whole `CHANGELOG.md` section, with its upgrade and rollout notes. The update banner's short summary is unchanged.
