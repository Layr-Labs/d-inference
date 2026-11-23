### Model files download over several connections

- A model file of 256 MiB or more is downloaded over 4 byte ranges at once,
  each on its own connection, from Hugging Face or R2, when the source serves
  byte ranges of exactly the catalog size and the model cache is on an APFS
  volume. This applies to `darkbloom models download`, the `darkbloom start`
  picker, `darkbloom cluster`, background prefetch, Autopilot placements,
  automatic revisions and MTP assistant files.
- An interrupted ranged download resumes each range where it stopped, after a
  cancel or a restart too; a partial single-connection file is kept and
  continued. Every file is still checked against its SHA-256 before it is
  used, and the model against its aggregate digest. A source that answers a
  range request without that range, and a file that fails its check, continue
  over one connection, as before.
- `DARKBLOOM_DOWNLOAD_SEGMENTS` sets the number of ranges (1–8); `1` (or an
  off word) restores one connection per file. A foreground download opens at
  most 16 connections over all its files. Background downloads still fetch
  one file at a time, now over 4 connections of the background network
  service type.
- After a rollback to an earlier release, a partly ranged file is downloaded
  again from the start.
