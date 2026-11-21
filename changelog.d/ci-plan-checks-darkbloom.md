### CI: Check the CI plans runs on Darkbloom

- The `ci-plan-checks` job (Check the CI plans) of every CI (dev) and CI (master) run that runs the test jobs now reads its own route lane, `ci-plan-checks` (Linux, 4x16), which the plan asks for in the run's one route request. It runs on a Darkbloom Linux sandbox when the plane grants one and keeps GitHub-hosted `ubuntu-24.04` otherwise. Its checks and the Provider Tests gate are unchanged.
- The test jobs usually outlast it by minutes, so the sandbox's start mainly delays a run that tests no component.
