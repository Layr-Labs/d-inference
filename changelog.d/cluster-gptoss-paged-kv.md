### GPT-OSS demand-grown cluster KV pages

- GPT-OSS cluster requests now keep full and sliding KV histories in demand-grown
  64-token pages, preserving the existing attention layout and sinks. Admission
  retains conservative request bounds and charges page and repack allocations.
