### Faster Qwen tensor-parallel decode on two M5 Ultra

- Qwen3.8 27B tensor parallel on two M5 Ultra decodes about 6% faster for one request (75.8 to 80.5 tok/s at 256 tokens, 62.7 to 66.8 at 1,024). The exact decode projections take a layout measured on the M5 Ultra for a verify window's vectors (rows in registers). Outputs are unchanged byte for byte, and other chips keep their layouts.
