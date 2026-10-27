### CI can run read-only jobs on Darkbloom Sandboxes

- A route job chooses a Darkbloom Sandbox or the existing Blacksmith runner for each read-only CI job. Routing stays off until the repository variable `DARKBLOOM_ROUTING` is `on`; plane errors, timeouts and unexpected replies keep the Blacksmith runner.
- Release, signing, publication and credentialed jobs, and `master` cache warming, stay on Blacksmith. The component classifier and the `Provider Tests` gate run on GitHub-hosted `ubuntu-24.04`, and routed jobs have job-level timeouts.
