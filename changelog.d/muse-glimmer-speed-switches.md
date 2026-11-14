### Muse Glimmer 30B drafter speed switches (opt-in)

- Three opt-in switches for the Muse Glimmer 30B drafter. With none set, the provider binds exactly as before: one decoding request per round, argmax proposals and one drafter pass per request. A switch changes only how often drafts are accepted, never the output: acceptance stays exact, and the `DARKBLOOM_MTP_` prefix keeps each setting's SSD checkpoints apart.
  - `DARKBLOOM_MTP_MUSE_GLIMMER_ROWS=2`: two decoding requests share an exact round, drafting three tokens each (the 8 verify rows of one request at depth seven); `wide` allows up to four, drafting two each at three or four rows.
  - `DARKBLOOM_MTP_MUSE_GLIMMER_COUPLED=1`: a sampled request's drafts are raced with the noise of the target's own verify draw. Greedy requests are unchanged. Measured so far, this lowers sampled acceptance, so leave it off.
  - `DARKBLOOM_MTP_MUSE_GLIMMER_BATCHED=1`: the requests of one step share the drafter's context commit, block forward and head product, so its weights are read once per step instead of once per request.
  - Each is forwarded to the launchd provider job; any other value keeps the default and logs a warning. Other models ignore them.
- `DARKBLOOM_DEBUG_MTP_RECEIPTS=1` keeps each finished request's MTP rounds, proposed and accepted counts, decode rows and engine timing (no text, token ids, sampling values or request identity). Only `darkbloom start --local --no-auth` serves them, at `GET /v1/debug/mtp-receipts`.
