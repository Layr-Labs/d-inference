### Inkling 2 Mini's draft cap can be set per Mac

- `DARKBLOOM_INKLING_MTP_MAX_DRAFT` sets the most drafts one Inkling 2 Mini MTP round may propose: a whole number from 1 to 7, with values outside that range clamped. Unset, it stays at 7, the drafter's whole block, as before.
- The adaptive depth policy still picks each round's depth at or below the cap, and every draft is verified exactly, so tokens are the same at any cap. Only how much each round tries changes.
