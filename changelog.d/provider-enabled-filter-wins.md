### The enabled-model filter wins over coordinator model changes

- A provider with an `enabled_models` filter no longer serves, downloads or loads a model outside it because the coordinator asked. Before, a public model rollout could bring back a model you deselected: with `gemma-4-26b` selected and `gemma-4-26b-qat-4bit` deselected, the coordinator's `gemma-4-26b` rollout downloaded `gemma-4-26b-qat-4bit` again (also after `darkbloom models remove`), served it in place of `gemma-4-26b`, and `darkbloom status` showed `Serving outside the enabled model filter: gemma-4-26b-qat-4bit`.
- The provider now refuses a coordinator `load_model` or `prefetch_model` for a model outside the filter (`model_not_selected`), and does not move a selected model to a newer build outside the filter. It keeps serving the selected build and logs `desired_models: <model> → <build> is outside the enabled model filter; not converging`.
- `darkbloom switch` makes its selection the filter at once, without a restart.
- With an empty `enabled_models` (serve every downloaded model) nothing changes. To take a new build of a selected model, add it with `darkbloom switch`.
- Autopilot keeps its own consent-based downloads and placements.
