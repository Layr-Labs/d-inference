### GLM tensor-parallel greedy MTP rounds split the head's vocabulary

- A greedy GLM tensor-parallel MTP round (solo or batched lanes) reads out only its half of the head's vocabulary rows on each rank and agrees on every window token through the round's existing agreement sum (each rank's half maximum and argmax; rank 0's lower index wins a tie, as MLX's argmax does): a depth-2 round 21.32 to 21.05 ms on two M5 Ultra, tokens and top logits identical. Sampled rounds keep the whole head. `darkbloom-cluster-tp-check glm --mtp-vocab-split yes|no` compares them.
