### Remove leftover console tooling after the console moved to darkbloom-platform

- The web console now lives only in darkbloom-platform. The `.githooks` pre-commit and pre-push hooks, the `Console UI Lint & Build` CI lane, the `ui-*` Make targets and the console Dependabot entry, which all ran in the deleted `console-ui/` directory, are removed. Pushing a branch with the deletion no longer fails the pre-push hook.
- Docs no longer cite `console-ui` paths in this repository, so `make docs-check` passes again; the console architecture page now points to the platform repository.
