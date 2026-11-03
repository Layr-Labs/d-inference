### CI caches .git and SwiftPM repositories; only master and dev pushes save caches

- Every `ci.yml` job that checks out restores the newest saved `.git` first, so the checkout fetches only new objects and reuses submodule clones. If that checkout fails, the job deletes the workspace and checks out again without the cache. The `.git` key names the UTC day, so each branch saves `.git` at most once a day. The full-history `docs` job keeps its own entries.
- The build lanes restore SwiftPM's repository clones, which a cold build otherwise downloads.
- Only pushes to `master` and `dev` save CI caches. A pull request restores its base branch's entries, then `master`'s, and saves none, so it no longer evicts them from the repository's 10 GB Actions cache.
- Checkouts no longer keep the job token in `.git/config`, which the `.git` cache would otherwise store.
- Each job logs whether `actions/cache` compresses with zstd or gzip; entries saved with one are not restored by a runner using the other.
- Limitation: on a pull request, the provider summary job restores its base branch's newest compatible build and rebuilds the commit's changes instead of reusing its shards' build.
