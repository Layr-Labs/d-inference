### Ordered logprob streaming

- Bind captured logprobs to ordered generation events before canonical chat SSE encoding, preventing a fast producer from attaching future token metadata to earlier content.
- Preserve collected response metadata, request cancellation and the bounded pending window. Parser reasoning/tool source spans remain unclassified; native capture support is unchanged.
