### Qwen batch joining

Joining requests can progress while existing Qwen pipeline lanes await token decisions. The pair continues exchanging control steps, and each lane waits for its own decision before its next forward.
