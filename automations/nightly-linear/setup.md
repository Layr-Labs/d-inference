# Set up my nightly Darkbloom Linear update from our shared repo

Paste this file into a local Codex desktop chat. The shared repository is
`https://github.com/Layr-Labs/d-inference.git`, branch **master**, the verified
default branch as of October 5, 2026. Use that branch unless I explicitly name
another. This is a one-time setup; future workflow changes come from the repo
before each run.

## Request and authorization

Set up my nightly Linear update using the shared repository. Review my Darkbloom
work in Codex, Claude Code, and Pi, then update Linear at the end of each night.
I authorize factual progress comments, supported status updates on my issues,
and creation of missing issues for my work in the configured team. Preserve
existing ownership and project assignments. Put genuinely unclassified new work
in the existing **Others** project. This covers recurring runs without another
approval round for each routine update.

I also authorize fetching updates from the configured repository branch before
each run and using its latest fetched skills and playbook within that scope.
Keep personal configuration and recovery state outside the shared clone.

Default schedule: **every day at 22:00 in my local IANA time zone**. Use my client
time zone and any schedule override I provide.

## Set up once

1. **Resolve the shared repo.** Use the URL I provide, or the verified origin of
   the checkout containing this prompt. If neither exists, ask for the URL. Read
   the remote's default branch rather than assuming main. Verify Git access.
   The package lives under `automations/nightly-linear/` in the repo.

2. **Create a dedicated clone.** Normally use `~/.codex/nightly-linear/source/`
   for the clone and its parent for private configuration and state. Use a
   persistent writable location when the sandbox requires one. Do not pull or
   reset my product development checkout. Clone the configured branch, then
   mark only this dedicated clone with the local Git configuration
   `nightlyLinear.managed=true`. Reuse an existing managed clone after checking
   its exact origin, branch, and clean status. Do not overwrite local edits.

3. **Resolve my Linear scope and work folders.** Read the connected workspace,
   authenticated user, Darkbloom team, existing statuses, and catch-all project.
   Reuse [Others](https://linear.app/eigenlabs/project/others-195b4f5ab76f) after
   verifying its team, or find the team's equivalent if this URL is unavailable.
   If none exists, ask for the canonical catch-all instead of creating another.
   Discover my work roots from recent session metadata and the current project,
   including relevant worktrees. Read applicable AGENTS.md files. If identity or
   work scope is ambiguous, bundle the missing information into one question.
   Inspect Codex, Claude Code, and Pi source layouts using the repo's history
   skill. Save custom roots explicitly. Disable tools I do not use; distinguish
   missing access from a source with no work.

4. **Link the repo skills.** Link each canonical folder under
   `source/automations/nightly-linear/skills/`
   into the supported Codex user skill directory, normally `~/.agents/skills/`:
   `darkbloom-work-history` and `darkbloom-linear-nightly`. Verify discovery.
   Use symlinks rather than copied skill bodies. Read existing installations
   first; preserve unrelated customizations and avoid duplicate discovery paths.
   Do not install packages, hooks, or configuration in Claude Code or Pi.

5. **Save local configuration.** Use this package's `config.example.json` as the
   shape and replace every example value with verified settings. Write the
   actual `config.json` next to the clone, with `source_repo` containing
   `checkout_path`, exact `origin_url`,
   and `branch`; `workspace_id`, `team_id`, `owner_id`, `others_project_id`,
   `timezone`, `schedule`, `work_roots`, and `sources` with enabled flags and
   explicit root paths. Record this automation's chat ID when available. Save
   `initial_since` as the start of today in my local time zone converted to UTC.
   Keep `state.json` beside it using `state.example.json` for a new installation:
   per-source UTC checkpoints in `source_checkpoints`, verified action entries
   in `actions`, `pending_actions`, `unresolved_work`, and revision/coverage
   reports in `runs`. Start with empty state only for a new installation;
   preserve all existing checkpoints and pending work. Store
   no credentials or raw transcripts. Record the actual Python 3 executable
   supported by the scheduled environment; the updater needs only its standard
   library and Git.

6. **Test a read-only preview.** Run the clone's
   `automations/nightly-linear/refresh.py` with the absolute `config.json` path.
   Check its exit code and parse its JSON output. It fetches the configured branch
   and returns `revision`, `playbook`, and both `skills` from that one commit.
   Read all returned instruction bodies, then run that playbook with
   `mode=preview` and the local config/state paths. Do not rely on previously
   loaded skill content. Refresh failure means stop before Linear writes; do
   not use a cached version. Show proposed issue matches, changes, Others items,
   and coverage. Preview does not mutate Linear or checkpoint/recovery state.
   Empty activity is valid. Fix routine setup errors independently.

7. **Save a small launcher and schedule it.** Save the launcher described below
   as `run.md` beside the private config, using actual absolute paths and a
   safely quoted refresh command. Inspect existing Codex automation records and
   reuse this person's matching workflow rather than create a duplicate. Use
   the app's current automation tool to schedule a follow-up in this local chat
   at the configured time, with current model defaults. Enable it once required
   scope, Git access, source access, skill discovery, and preview are verified.
   Prepare all files before reporting any required user action. Do not create
   a cloud or OS cron substitute or hand-write scheduler records.

## The stable launcher

Save only the following behavior and resolved local paths in `run.md` and the
scheduled automation prompt. Keep the actual update playbook in the repository:

> Run my nightly Darkbloom Linear update in apply mode. My one-time setup request
> authorizes the configured Linear changes and refreshing the configured shared
> repository branch. Read config.json and use state.json at the absolute paths
> supplied here. Run the specified Python executable with the dedicated clone's
> refresh.py and config.json. Check success and read the complete
> JSON result. Follow its playbook and both skill bodies from the returned
> revision, passing apply mode and these local paths. Use these freshly fetched
> instructions even if older skills were loaded earlier in this chat. If refresh
> or instruction loading fails, stop before Linear writes and report the problem.
> Keep personal configuration and state outside the repo. Record the fetched
> revision with the run. Stay quiet when there is no new work or actionable issue.

Resolve every path and command in the saved launcher. Keep existing launchers
and automation records consistent. Manual runs read the same `run.md`, use the
same updater, and share the same checkpoints and recovery state. Give me a
copyable manual invocation: “Read <absolute path to run.md> and run it now.”

Report the installed skill paths, repository and branch, preview revision,
covered work roots and sources, schedule and time zone, and Others link. Clearly
separate prepared files, a created schedule, and a verified live run. Local
history requires this computer to be on and the desktop app running.

To change the workflow later, the maintainer edits the canonical skills or run
playbook and pushes to the configured branch. Each trigger loads the latest
successfully fetched commit. No replacement setup prompt is needed for ordinary
playbook changes. Repository URL, branch, permission, personal-scope, or launcher
contract changes may require a one-time setup adjustment.
