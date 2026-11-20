### Super stream logprobs and a lost pair's capacity no longer depend on timing

- A streamed Nemotron Super reply that ends with a tool call no longer carries,
  at random, the logprob entry of the call's first tag. The owner now hands the
  relay and the local stream an entry only before a chunk that shows reasoning
  or content, as it already did for a complete response, so every path carries
  the same entries.
- A distributed pair whose peer was lost reports no capacity from the moment its
  requests are told so. Before, a capacity read in that window could report the
  full capacity again if the peer's readiness came back.
