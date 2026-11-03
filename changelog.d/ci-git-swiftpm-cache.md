### CI caches .git and SwiftPM repositories; only master pushes save caches

- Every CI job restores the newest `.git` saved by a `master` push before it checks out, so the checkout fetches only new objects and reuses submodule clones. If that checkout fails, the job deletes the workspace and checks out again without the cache. The full-history `docs` job keeps its own entries.
- The provider and SDK build lanes restore SwiftPM's repository clones, which a cold build otherwise downloads.
- Only `master` pushes save CI caches. Pull requests and `dev` pushes restore `master`'s entries and save none, so they no longer evict `master`'s entries from the repository's 10 GB Actions cache. The push-only `cache-swift` job still saves its own cache on every push.
- Checkouts no longer keep the job token in `.git/config`, which the `.git` cache would otherwise store.
- Each job logs whether `actions/cache` compresses with zstd or gzip; entries saved with one are not restored by a runner using the other.
- Limitation: on a pull request, the provider summary job no longer restores the build its shards saved; it restores `master`'s newest compatible build and rebuilds the commit's changes. Timing of a warm `.git` restore can be measured only after the first `master` push saves an entry.
