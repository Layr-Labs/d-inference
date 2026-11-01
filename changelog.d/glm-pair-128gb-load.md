### GLM pair refusals name the memory they need

- A GLM-5.3-Flash pair rank that cannot hold its share now says why. The error names the rank, the cut, the request the memory plan charges (65,536 tokens) and what the rank needs: weights, load-only memory and the request, against what its GPU keeps resident. Before, it said only "GLM quotation exceeds the bound load/request capacities".
- Two 128 GB Macs (two M5 Max) do not hold GLM-5.3-Flash. At the most balanced cut each half needs about 111 GiB, and a 128 GB Mac's GPU keeps 107.5 GiB resident. Tensor parallel needs about 153 GB a rank. The refusal is unchanged; only its message is new.
