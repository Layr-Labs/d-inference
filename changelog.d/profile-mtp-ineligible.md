### Request profiles record why a request does not draft with MTP

- The request profile's `engine` object can carry `mtp_ineligible`: the
  whole-request gates that kept the request from drafting with MTP (media,
  reasoning budget, grammar, sampling, logprobs, logit bias, repetition
  penalty, penalties, stop strings, multimodal history), each present as `true`
  only when it failed. `{}` means none failed. It is absent where nothing was
  evaluated, for example on a slot without a drafter. Booleans only.
