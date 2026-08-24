# 055 — Objective reset: weights fixed, execution policy open

Status: **binding owner direction**

The owner rejected stopping at the incumbent FP32/numerical contract:

> Always believe 2.5× is possible. Only the model weights cannot change.

The search space is reopened:

- mixed/lower precision and changed reduction association;
- native packed TensorOps;
- adaptive MoE routing/top-k;
- layer/token skipping and speculative correction;
- compressed/approximate KV and GDN state;
- prefix/block cache reuse;
- alternate cache construction algorithms;
- CPU/GPU/ANE partitioning.

Weight bytes and hashes remain immutable. Numerical drift is reported,
then accepted or rejected on a fixed quality corpus and operational
safety—not checksum identity alone.

The top-down product of prefill is:

1. ten attention-layer KV caches;
2. thirty GDN terminal states and convolution tails;
3. frontier logits.

New experiments work backwards from constructing those artifacts at
acceptable quality. Historical exact-path failures remain useful data,
not a reason to terminate the objective.
