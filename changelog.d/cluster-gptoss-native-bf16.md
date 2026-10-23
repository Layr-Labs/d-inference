### GPT-OSS native BF16 residuals

- Match the GPT-OSS cluster residual and logits profile to the pinned SDK's native BF16 arithmetic. Wire estimates use the actual two-byte residual while memory admission keeps its conservative allowances; no forward cast or checkpoint change is introduced.
