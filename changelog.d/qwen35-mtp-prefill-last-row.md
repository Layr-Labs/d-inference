### Qwen 3.5 MTP prompts project only their last position

- With MTP active, every prompt chunk of a Qwen 3.5-family model (Qwen3.5-9B, Qwen3.5-35B-A3B, Qwen3.6,
  Qwen3.8-27B and Bonsai 2 9B) went through the 248,320-way output head at every position, though only the last
  row is used. The pinned SDK (mlx-swift-lm #302) now projects only the last position of the last chunk. On an
  M3 Ultra, time to first token with MTP fell by about a tenth at 4K–16K prompt tokens on Qwen3.5-9B and
  Qwen3.5-35B-A3B, with identical temperature-0 outputs. The first token's logits now equal the MTP-off path's
  exactly. Requests where MTP does not run see no change.
