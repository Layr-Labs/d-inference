### Model registration sends its key only to a Darkbloom coordinator

- The `Register Model` workflow's `coordinator_url` input is now a choice of the production (`https://api.darkbloom.dev`, the default) and dev (`https://api.dev.darkbloom.dev`) coordinators. The job's first step stops any other value before a step that reads the publishing key runs.
