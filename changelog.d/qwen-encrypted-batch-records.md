### Encrypted Qwen batch records

Qwen cluster batching now binds every encrypted transfer to its batch and step, with request and frontier checks for residuals. Record ordering remains continuous across batches, so replayed or mismatched transfers fail the session.
