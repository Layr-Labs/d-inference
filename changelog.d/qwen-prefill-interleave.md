### Qwen streams keep decoding during long prefills

- Run four decode-only steps between prompt chunks on Qwen 3.5-family slots. Two Qwen3.8-27B streams decoding beside a 30K-token prefill go from 2.6 to 8.5 tok/s, and the long prompt's first token from 37.6 to 45.5 s on an M5 Max.
