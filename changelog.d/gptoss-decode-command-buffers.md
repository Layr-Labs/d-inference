### GPT-OSS plain decode commits by operation count

- Plain decode steps of GPT-OSS commit a Metal command buffer every 100 operations instead of after almost every MoE layer. Outputs are bitwise identical. Prefill keeps MLX's defaults.
