### Qwen 3.8 27B pairs with the assistant prefill long prompts faster

- A Qwen pair in tensor parallel that decodes with its speculative assistant processed each 512-token prompt chunk one at a time, waiting for its link traffic after each. It now processes up to eight chunks together, as a pair without the assistant already did, so one chunk's link traffic overlaps the next chunk's compute. The prompt's results and the assistant's state are unchanged.
