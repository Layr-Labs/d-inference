# Qwen27B 8K full reference

Fresh P8192/C512/O128, cut16, greedy BF16, empty stops and MTP off. Uses the unchanged d717 full-model native and its existing resources. All 21 Python runtime/test members are exact copies of the qualified cut16 package, including safe worker_processes26448b0b. One obsolete historical .before-fix test copy is omitted to keep the existing 64-member launcher bound; its original remains untouched. Existing copied CPU receipts are historical. The new prompt is included as a pinned package member. The job changes workload/request/run paths from the prior short reference, and changes only prompt_file relative to the frozen 8K inputs job. No result exists at preparation.

Remote launcher: /Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/supervisor-27b-8k-owned. Root alone copies/runs/collects after the compiler slot is released. No model, owner, interface or configuration is changed by preparing this source package.
