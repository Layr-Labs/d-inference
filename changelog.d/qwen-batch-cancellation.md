### Independent Qwen batch cancellation

Optional Qwen pipeline batches now retire a cancelled started lane without cancelling other lanes, including a start still waiting to join. Both ranks finish announced work and release native state before acknowledging cancellation. The lane default stays one; other generation modes and GLM behavior are unchanged.
