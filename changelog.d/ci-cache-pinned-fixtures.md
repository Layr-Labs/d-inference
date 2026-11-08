### Provider CI: the prompt parity fixtures come from a verified cache

- Provider shard 1 restores the prompt artifacts that both Prompt Parity steps read (tokenizers, templates and configs of the 7 v1 contracts and the Nemotron contract, 104 MB) from an Actions cache keyed by the hash of their manifests. Pushes to `dev` and `master` save it after both parity steps pass; pull requests restore it and save nothing.
- `scripts/prepare-prompt-fixtures.py --download-cache` (`PROMPT_PARITY_DOWNLOAD_CACHE` in both parity scripts) uses a cache entry only if it is a regular file with the pinned size and SHA-256. Any other entry is downloaded and replaced. A cache that cannot store an entry never fails the run. Contracts that share a tokenizer download it once.
- A contract's download deadline is now 120 s plus its missing bytes at 128 KiB/s, at most 900 s, instead of a flat 120 s. The 17 MB Nemotron contract that timed out at under 142 KB/s in run 42330647893 now has 256 s.
- For each contract the script prints how many artifacts came from the cache and how many bytes it downloaded, and how long that took.
