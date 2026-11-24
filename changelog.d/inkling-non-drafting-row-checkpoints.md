### Inkling 2 Mini requests that cannot draft write prefix checkpoints

- An Inkling 2 Mini request that cannot draft (a logit bias, a token constraint or a reasoning budget) now records the drafter's prompt history when its prompt can be cached, as the Qwen 3.5/3.6, Qwen4, Nemotron Super and MiMo heads already do. It writes the same checkpoints a drafting request writes, so a later request with the same prefix can restore from it. Requests with media still record nothing, by design.
- Inkling requests with logprobs, a repetition, presence or frequency penalty, or a stop string draft in this release (see their own entries), so they save checkpoints as drafting requests do. When one of those rows is kept target-only by its switch, it saves checkpoints through this path instead.
- Output is unchanged: a restored request answers exactly as its cold run. The change comes with the SDK pin; there is no setting.
