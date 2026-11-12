### Two Bonsai 2 27B requests decoding together run at full speed again on a single Mac

- With prompts batched again (#2022), a single Mac also ran each decode step of several Bonsai 2 27B requests as one batched matrix multiply. At two requests on an M5 Ultra that was 9.5 % slower than 0.10.11's one-row kernel (71.1 against 78.6 tokens per second, steady state).
- Now two requests decoding together on a single Mac are computed row by row again, as 0.10.11 computed them on every Mac, and run at full speed again (78.6 tokens per second on the M5 Ultra). Prompts and decode steps of three or more requests stay batched: batched prompts are 6 to 7 times faster than 0.10.11 at 1K to 8K tokens, and from three requests batched decode is as fast or faster (116.0 against 107.3 tokens per second at four).
- A request's exact output can still depend on the requests decoding beside it, as in 0.10.11. Pairs are unchanged.
- `libs/mlx-swift` moves to `4e79ee5f7f` (Layr-Labs/mlx-swift#71, on the fork's `release/provider-0.10.12`). Only Swift sources change there, so `mlx.metallib` is unchanged.
