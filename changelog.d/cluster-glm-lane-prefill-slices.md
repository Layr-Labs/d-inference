### GLM pair: a joining prompt no longer stalls decoding lanes

- While other lanes decode on a GLM-5.3-Flash tensor-parallel pair, a joining lane's prefill runs in layer slices of about 500 ms, one slice a step, with every decoding lane's step after it, so decoding streams wait about 0.6 s instead of a whole 8K chunk (about 2.3 s). The lane with the shortest remaining prompt prefills first, and a prompt that fits one slice runs between another prompt's slices. Tokens are the same as a request served alone.
