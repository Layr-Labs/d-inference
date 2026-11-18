### The provider zeroes the request and response buffers it owns

- The provider now zeroes the decrypted request body when the request releases it, on every path including cancellation and errors, and zeroes the copies it makes to seal each response chunk and to hold the request's keys. Parsed request text, rendered prompts, tokenizer and model buffers and the streamed response text are not covered; the encryption architecture page lists them.
