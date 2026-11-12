### Bonsai 2 27B decodes several requests at full speed again on a single Mac

- With prompts batched again (#2022), a single Mac also ran each decode step of several Bonsai 2 27B requests as one batched matrix multiply. At two requests on an M5 Ultra that was 8.9 % slower than 0.10.11's one-row kernel (71.5 against 78.4 tokens per second, steady state).
- Now a single Mac computes calls of fewer than 12 rows row by row again, as 0.10.11 did, which restores 0.10.11's concurrent decode speed. That covers decode steps of up to 11 requests, tiny prompts and the tail of a prompt chunk. Prompt chunks of 12 rows or more stay batched, 6 to 7 times faster than 0.10.11 at 1K to 8K tokens.
- A request's exact output can still depend on the requests decoding beside it, as in 0.10.11. Pairs are unchanged.
- `libs/mlx-swift` moves to `49c145c2c9` (Layr-Labs/mlx-swift#71, on the fork's `release/provider-0.10.12`). Only Swift sources change there, so `mlx.metallib` is unchanged.
