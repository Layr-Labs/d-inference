### Provider repository ownership

- Remove centralized coordinator/backend, admin, integration-harness and deployment implementation from this repository; retain the Swift provider, local native runtime and landing site. The console source snapshot and its existing build, lint, test and hosting configuration remain unchanged. New backend, console and admin development belongs in the sibling platform repository; release/model registration remains an external API operation. Source ownership changes do not change deployed endpoints or authorize deployment.
