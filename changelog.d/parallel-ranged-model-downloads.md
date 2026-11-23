### Model files download over several connections

- A model file of 256 MiB or more is downloaded over 4 byte ranges at once,
  each on its own connection, from Hugging Face or R2, when the source serves
  byte ranges of exactly the catalog size. This applies to `darkbloom models
  download`, the `darkbloom start` picker, `darkbloom cluster`, background
  prefetch, Autopilot placements and automatic revisions.
- An interrupted ranged download resumes each range where it stopped, after a
  cancel or a restart too; a partial single-connection file is kept and
  continued. Every file is still checked against its SHA-256 before it is
  used, and the model against its aggregate digest.
- `DARKBLOOM_DOWNLOAD_SEGMENTS` sets the number of ranges (1–8); `1` restores
  one connection per file. A foreground download opens at most 16 connections
  over all its files; background downloads still fetch one file at a time.
