### Gemma 4 plain decode commits by operation count

- Plain decode steps of Gemma 4, the rows served without its assistant, commit a Metal command buffer every 100 operations instead of many times per step. Outputs are bitwise identical. Prefill and assistant rounds keep MLX's defaults.
