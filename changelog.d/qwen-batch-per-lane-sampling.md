### Qwen batch sampling

Optional Qwen pipeline batches now apply each request's sampling settings and token history throughout decode. Greedy-only selection keeps its existing argmax path.
