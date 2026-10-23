### Qwen27 feature-preserving cluster modes

Keep images, video and committed-token logprobs in the registered Qwen3.8 27B cluster route by admitting tensor parallel before unchanged speed ranking. Replan old pipeline setups instead of silently serving fewer features, retain native link/shape/memory gates, and require matching actual media READY and logprob support before creating the bridge. Other model and GLM mode policies remain unchanged.
