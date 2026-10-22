### GLM tensor-parallel MTP rounds submit their proposals early

- A GLM tensor-parallel MTP round (solo or batched lanes) submits its NextN priming and proposals as soon as they are built, so the GPU computes them while the host builds the verification forward instead of idling through the whole round's build: a depth-2 round 23.06 to 21.64 ms (95.9 to 102.7 tok/s) and two lanes 115.2 to 121.6 tok/s on two M5 Ultra, tokens and top logits identical. `darkbloom-cluster-tp-check glm --mtp-early none|proposals|layers` compares the modes.
