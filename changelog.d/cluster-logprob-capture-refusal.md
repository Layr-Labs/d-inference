### Clear cluster logprob refusal

Cluster requests now reject unsupported token logprobs with a clear HTTP 400 before reserving workers. GLM tensor-parallel logprobs and the existing numeric limits remain supported.
