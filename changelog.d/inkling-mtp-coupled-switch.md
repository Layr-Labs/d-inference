### Inkling 2 Mini can draft with coupled proposals (off by default)

- `DARKBLOOM_INKLING_MTP_COUPLED=1` turns on coupled drafting for Inkling 2 Mini. With it on, a sampled request under exact acceptance proposes the draft that the target's own sampling at that position would most likely pick, instead of the drafter's single most likely token.
- Output is the same with it on or off, because exact acceptance keeps only the target's own tokens. Only how many drafts are kept, and so speed, can change.
- Greedy requests, constrained output and typical acceptance are unchanged. The setting is off unless the variable turns it on.
