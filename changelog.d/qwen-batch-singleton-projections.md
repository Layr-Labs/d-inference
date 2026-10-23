### Qwen batch projection arithmetic

Optional Qwen 3.5 pipeline batches preserve singleton projection arithmetic for dense packed weights and retain original per-row behavior for custom modules and routed blocks. Batch peers bind the new arithmetic in their load agreement; installed lane defaults stay unchanged pending full-model qualification.
