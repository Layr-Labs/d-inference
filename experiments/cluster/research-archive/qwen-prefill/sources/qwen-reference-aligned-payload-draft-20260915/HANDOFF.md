# Reference payload read policy

The unchanged diagnostic binary, after disk-cache purge, refused at tensor1340/1847: active11,282,933,388B, cache1902B, actualfree10,263,773,184B against12,224,874,656B required. This is a load-time actual-free failure, not an allocator-limit failure. The full-reference path had not enabled the descriptor-local aligned reader already used for selected-stage loading.

Two runtime changes: request `bypassTensorPayloadCache` on the existing verified checkpoint after source/resource admission and before the first materialized tensor; explicitly reserve its maximum8MiB+16KiB anonymous host scratch while payload loading remains. The existing F_NOCACHE/F_RDAHEAD calls and aligned pread implementation are reused unchanged. No absence-of-caching proof is claimed. Existing file identity/hash checks, tensor math, conversion, resource floors, allocator limits, request inputs and deadlines are unchanged. There is no automatic purge in the native loader.

The existing CPU admission check now verifies the named scratch allowance, initial full-loading allowance and release after all tensors complete. Its previous negative cases remain. Actual native build, CPU checks and27B generation are required next. Three source files are private derivatives; MAIN and all prior failures/bundles remain unchanged.
