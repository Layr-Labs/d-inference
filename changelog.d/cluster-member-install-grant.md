### Cluster pairs register GLM-5.3-Flash and Qwen3.8 27B as cluster members

A pair started with a coordinator approval (DevNet) now registers both Macs as cluster members for GLM-5.3-Flash and Qwen3.8 27B. Before, each Mac's member part ended about a second after it started, with "Cluster member control connection ended", and after three tries the pair served on the leader's local API only.

The member applied the single-Mac requirements (`mlx_nax`, and `glm5_next_v1` for GLM) to its model in two places: before connecting, and when building its registration, which left the model out of `cluster_models`. A member reports hardware-only capabilities, and its pair-serving grant admits its model, so both places now follow the grant. A solo provider keeps the single-Mac requirements.
