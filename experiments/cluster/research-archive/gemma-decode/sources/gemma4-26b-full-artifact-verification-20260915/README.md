# Registered Gemma artifact verification

Read-only full SHA-256 verification of all ten files in the existing local Gemma 4 26B QAT 4-bit snapshot against the retained public registry manifest. The aggregate follows the repository's ManifestBuilder and WeightHasher: concatenate the raw per-file SHA-256 digests in relative POSIX path order, then hash that concatenation.

The sequential verifier uses a four-MiB buffer, requires Darwin F_NOCACHE, refuses symbolic links/nonregular files, checks file identity before and after each read and again at completion, and has a 120-second alarm. It constructs no model and writes only fresh evidence under this directory. F_NOCACHE does not evict previously cached pages. No remote copies or inference runs are included.

Execution: `python3 -B verify.py`. The fresh `run-1/verification.json` is the outcome; this preparation alone makes no payload-verification claim.
