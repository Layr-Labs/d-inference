### GLM-5.3-Flash SDK speedups shared with the single-Mac release

- The SDK's pipelined KDA prefill recurrence now also covers 64 heads on an 80-core M5 Ultra (two
  value-row ranges per GPU core): one Mac and each GLM pipeline stage prefill faster with bit-identical
  outputs; a tensor-parallel rank's 32 heads keep their cut, so tensor-parallel GLM is unchanged.
- The CBv2 MTP loop can submit every draft step as soon as it is built (on for the single-Mac GLM
  profile); the two-Mac GLM path runs its own speculation loop and is unchanged.
