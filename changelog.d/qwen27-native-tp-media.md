### Qwen27 native TP media ownership

Add an exact-artifact, keyed native Qwen3.8 27B image/video path with rank-zero
vision, authenticated features, request-owned MRoPE and explicit preparation
and retirement accounting. The checked worker carrier binds prompt, positions,
source geometry and byte limits to the artifact. Process and peer forwarding
retain encoded bytes only on rank zero and release the owner copy after checked
retirement. Unsupported worker paths reject media before reservation.

Provider HTTP ingress, TP batch integration and full-artifact clustered media
qualification remain separate gates.
