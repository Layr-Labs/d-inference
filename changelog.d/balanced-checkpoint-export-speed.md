### Faster balanced checkpoint donation

- Balanced (affine) prefix checkpoints are encoded with one prepared row encoder per write segment instead of rebuilding conversion state for every row. The stored bytes are unchanged. On LFM2.5-24B-A2B in a release build, the time a donating request waits for its checkpoint fell from about 2.5 s to 1.2 s at 8,192 prompt tokens, and balanced restores at 4,096 tokens fell from 0.43 s to 0.25 s to first token.
