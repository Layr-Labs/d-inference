### Inkling 2 Mini drafts on more requests and in busy batches

- On Inkling 2 Mini, a request that sent a `logit_bias` never drafted. It decoded at plain-step speed for its
  whole life. Such a request now drafts like any other. Every token is checked against the model with the request's bias applied, so the
  output is the same as before. `DARKBLOOM_MTP_LOGIT_BIAS_ROWS=0` turns this off.
- When several Inkling requests share a Mac, one request with poor draft acceptance no longer stops the others
  from drafting, and a request that stopped drafting tries again later. Under the default exact MTP
  acceptance, output is unchanged. Under an operator-set typical acceptance, a different draft depth can
  change which drafts are kept, within typical acceptance's contract. Other models keep their draft cadence.
  `DARKBLOOM_CBV2_MTP_BATCH_DEPTH=0` restores the previous behaviour.
- `darkbloom benchmark --runtime-concurrency` takes `--runtime-temperature`, `--runtime-top-p` and
  `--runtime-bias-rows`, so a run can measure sampled rows and rows that send a `logit_bias`.
