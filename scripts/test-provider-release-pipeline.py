#!/usr/bin/env python3
"""Pin release safety/DAG boundaries without credentials, runners or downloads."""
from fnmatch import fnmatchcase
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
# release-swift.yml is the thin caller that owns the triggers and routes each one
# to one or more environment lanes; release-provider.yml is the reusable workflow
# that holds the resolve -> build -> sign -> stage -> publish job chain.
CALLER = (ROOT / '.github/workflows/release-swift.yml').read_text()
RELEASE = (ROOT / '.github/workflows/release-provider.yml').read_text()
# The SDK qualification shards and their gate, called by each caller's job
# `qualify` with no secrets before its credentialed release-provider.yml call.
QUALIFY = (ROOT / '.github/workflows/release-qualify.yml').read_text()
DEV_CALLER = (ROOT / '.github/workflows/release-dev-branch.yml').read_text()
# The checked downloader: it fetches one artifact by ID and refuses it unless
# its zip's SHA-256 equals the digest (provider_release_artifact.download).
DOWNLOADER = 'scripts/provider-release-publication.py download'
# A download that a name selects, which any job of the run can replace.
BY_NAME = re.compile(r'gh run download|actions/download-artifact@|gh api [^\n]*artifacts\?name')
WARM = (ROOT / '.github/workflows/provider-release-cache.yml').read_text()
ACTION = (ROOT / '.github/actions/provider-release-build/action.yml').read_text()
FACTS_SCRIPT = (ROOT / 'scripts/provider-cluster-runtime-facts.sh').read_text()
REQUIREMENTS = ROOT / 'scripts/provider-release-publication-requirements.txt'
STAGE_STEP = '- name: Stage bundle and smoke it before signing\n'
REMOVE_STEP = '- name: Remove the signing keychain\n'
FACTS_STEP = '- name: Compute cluster runtime facts from the final signed app\n'
SHOW_STEP = '- name: Show the cluster runtime facts\n'
RETAIN_STEP = '- name: Retain the cluster runtime facts\n'
SIGNING_VALIDATION = (ROOT / '.github/workflows/provider-signing-validation.yml').read_text()
NATIVE_WORKER_BUILD = (ROOT / 'libs/darkbloom-cluster-worker/build-native-worker.sh').read_text()
STACK_CHECK = ROOT / 'scripts/check-fixed-stack.sh'
FIXED_STACK = '-Xlinker -stack_size -Xlinker 0x800000'


def step(content, name):
    """The body of the step that starts with `name`, up to the next step."""
    return content.split(name, 1)[1].split('\n      - name:', 1)[0].split('\n      # ', 1)[0]


def caller_jobs(text):
    """Every job of a caller workflow, by id."""
    body = text.split('\njobs:\n', 1)[1]
    parts = re.split(r'(?m)^  ([a-z][a-z0-9_-]*):\n', body)
    return dict(zip(parts[1::2], parts[2::2]))


def condition(job_text):
    """A job's `if:` expression body, on one line."""
    value = re.search(r'(?ms)^    if: (?:>-\n)?(.+?)\n    \S', job_text).group(1)
    return ' '.join(value.strip().removeprefix('${{').removesuffix('}}').split())


def named_steps(content):
    """(name, body) of every named step of a job, in order. The comment lines
    above a step describe that step, so they end the body before them."""
    parts = re.split(r'(?m)^      - name: (.+)\n', content)
    return [(name, re.sub(r'(?:\n      #.*|\n[ ]*)*\n\Z', '\n', body)) for name, body in zip(parts[1::2], parts[2::2])]


# The app's own executable followed by an argument: a run of the provider this
# release built. A path that codesign, cmp, cp or grep only reads ends its
# argument list, or is followed by another path or a redirection.
PROVIDER_RUN = re.compile(r'/Contents/MacOS/\$CLI_NAME" [a-z-]')


def runs_release_code(body):
    return bool(PROVIDER_RUN.search(body)) or 'provider-cluster-runtime-facts.sh' in body


def caller_lanes():
    return {
        'dev': CALLER.split('\n  dev:\n', 1)[1].split('\n  staging:\n', 1)[0],
        'staging': CALLER.split('\n  staging:\n', 1)[1].split('\n  prod:\n', 1)[0],
        'prod': CALLER.split('\n  prod:\n', 1)[1],
    }


def job(workflow, name):
    match = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [a-zA-Z0-9_-]+:|\Z)',
                      workflow.split('\njobs:\n', 1)[1], re.M | re.S)
    if match is None:
        raise AssertionError('Missing job: ' + name)
    return match.group(1)


# A lane's gate: qualification passed, or it was skipped for a resume.
QUALIFIED = ("(needs.qualify.result == 'success' || "
             "(inputs.resume_run_id && needs.qualify.result == 'skipped'))")


class ReleasePipelineTests(unittest.TestCase):
    maxDiff = 1000
    def test_master_push_and_tags_start_the_release_lanes(self):
        # The caller owns the triggers; path filters still apply to pushes, not tags.
        trigger = CALLER.split('\non:\n', 1)[1].split('\n  workflow_dispatch:', 1)[0]
        self.assertIn("    tags:\n      - 'v*.*.*'\n", trigger)
        self.assertIn('    branches: [master]\n', trigger)
        paths = re.findall(r"(?m)^      - '([^']+)'$", trigger.split('    paths:\n', 1)[1])
        for required in ['provider-swift/**', 'libs/**', '.github/workflows/release-swift.yml',
                         '.github/workflows/release-provider.yml',
                         '.github/actions/provider-release-build/**']:
            self.assertIn(required, paths)
        # Every script a release runs must start the push lanes when it changes.
        scripts = set(re.findall(r'scripts/[A-Za-z0-9_.*-]+\.(?:sh|py)', RELEASE + CALLER + ACTION))
        scripts |= {'scripts/provider_release_resume/api.py', 'scripts/provider_release_artifact.py',
                    'scripts/provider_release_github.py', 'scripts/provider_release_notes.py',
                    'scripts/provider_release_build_list.py',
                    'scripts/changelog.py', 'scripts/provider_release_cache/mtimes.py',
                    'scripts/stage-swiftpm-resource-bundles.sh'}
        for script in sorted(scripts):
            with self.subTest(script=script):
                self.assertTrue(any(fnmatchcase(script, pattern) for pattern in paths), script)
        self.assertNotIn('branches-ignore', trigger)
        self.assertNotIn('pull_request', trigger)

    def test_caller_routes_each_trigger_to_the_right_environment_lanes(self):
        # A master push runs staging only; a tag runs prod; a dispatch runs the
        # chosen environment, or the dev lane for a signed validation build. No
        # master path publishes a dev release: DevNet runs the dev branch
        # (release-dev-branch.yml). Every lane calls the reusable workflow and
        # inherits the credentials it needs.
        lanes = caller_lanes()
        push_branch = "(github.event_name == 'push' && github.ref_type == 'branch')"
        self.assertIn(push_branch, lanes['staging'])
        self.assertIn("(github.event_name == 'workflow_dispatch' && inputs.environment == 'staging' &&\n"
                      "            !inputs.validation_only)", lanes['staging'])
        # The dev lane runs only for a dispatched validation build and always
        # passes validation_only, so it never publishes.
        dev_if = lanes['dev'].split('    if:', 1)[1].split('\n', 1)[0]
        self.assertEqual(dev_if, " ${{ !cancelled() && github.event_name == 'workflow_dispatch' && "
                                 "inputs.validation_only && " + QUALIFIED + " }}")
        self.assertNotIn("github.event_name == 'push'", lanes['dev'])
        self.assertNotIn('inputs.environment', lanes['dev'])
        self.assertIn('      validation_only: true\n', lanes['dev'])
        # The dispatch offers no dev environment and no run name for a dev release.
        options = CALLER.split('      environment:\n', 1)[1].split('      version_override:', 1)[0]
        self.assertIn('        options: [staging, prod]\n        default: staging\n', options)
        self.assertNotIn("inputs.environment == 'dev'", CALLER)
        self.assertNotIn('dev provider release', CALLER)
        for name in ('dev', 'staging', 'prod'):
            with self.subTest(lane=name):
                self.assertIn('uses: ./.github/workflows/release-provider.yml', lanes[name])
                self.assertIn('environment: ' + name, lanes[name])
                self.assertIn('secrets: inherit', lanes[name])
        # prod never runs on a branch push: it is tag-gated (or a recovery dispatch).
        self.assertIn("github.ref_type == 'tag'", lanes['prod'])
        self.assertIn("(github.event_name == 'workflow_dispatch' && inputs.environment == 'prod' &&\n"
                      "           !inputs.validation_only)", lanes['prod'])
        self.assertNotIn(push_branch, lanes['prod'])
        # The caller holds no secrets, run steps or job chain of its own: it only
        # routes triggers to lanes. Every lane calls the one reusable workflow.
        self.assertNotIn('secrets.', CALLER)
        self.assertNotRegex(CALLER, r'(?m)^\s+run:')
        self.assertNotRegex(CALLER, r'(?m)^\s+steps:')
        for job in ('resolve-env:', 'build-and-release:', 'stage-release:', 'publish-release:'):
            self.assertNotIn('\n  ' + job, CALLER)
        self.assertEqual(CALLER.count('uses: ./.github/workflows/release-provider.yml'), 3)

    def test_each_release_lane_starts_only_after_its_qualification_or_on_a_resume(self):
        # Each caller has one `qualify` job, which calls release-qualify.yml
        # with read-only permissions and no secrets, and every credentialed
        # call of release-provider.yml needs it. Only a resume, which signs a
        # retained build whose run already passed qualification
        # (provider_release_resume/identity.py), skips it.
        lanes = caller_lanes()
        swift = caller_jobs(CALLER)
        dev = caller_jobs(DEV_CALLER)
        for text, jobs in ((CALLER, swift), (DEV_CALLER, dev)):
            qualify = jobs['qualify']
            self.assertEqual(text.count('uses: ./.github/workflows/release-qualify.yml'), 1)
            self.assertIn('    uses: ./.github/workflows/release-qualify.yml\n', qualify)
            self.assertIn('    permissions:\n      contents: read\n    uses:', qualify)
            self.assertNotIn('secrets', qualify)
            for name, job in jobs.items():
                if 'uses: ./.github/workflows/release-provider.yml' in job:
                    with self.subTest(lane=name):
                        self.assertIn('    needs: qualify\n', job)
                        self.assertIn('secrets: inherit', job)
        dev_guard = "    if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/dev'\n"
        self.assertIn(dev_guard, dev['qualify'])
        self.assertIn('    needs: qualify\n' + dev_guard, dev['dev'])
        # release-swift.yml: qualification runs exactly when one lane runs and
        # this is not a resume; each lane runs on its own condition and only
        # after qualification passed (or skipped on a resume).
        triggers = {}
        for name in ('dev', 'staging', 'prod'):
            lane = condition(lanes[name])
            self.assertTrue(lane.startswith('!cancelled() && '), lane)
            self.assertTrue(lane.endswith(' && ' + QUALIFIED), lane)
            triggers[name] = lane.removeprefix('!cancelled() && ').removesuffix(' && ' + QUALIFIED)
        self.assertEqual(condition(swift['qualify']),
                         "!inputs.resume_run_id && ((" + triggers['dev'] + ") || (" + triggers['staging'] +
                         ") || " + triggers['prod'] + ")")

    def test_staging_lane_is_gated_off_until_the_infra_var_is_set(self):
        # A master push publishes staging only when the STAGING_ENABLED repo
        # variable is 'true' (set once the staging stack and STAGING_* secrets
        # exist), so a push never burns a build that would hard-fail at staging
        # publication for want of secrets. Unset, a master push publishes nothing.
        lanes = caller_lanes()
        staging_if = lanes['staging'].split('    if:', 1)[1].split('    concurrency:', 1)[0]
        self.assertIn("vars.STAGING_ENABLED == 'true'", staging_if)
        # The gate ANDs with the trigger routing, so disabling it drops staging
        # entirely, and no other lane matches the push.
        self.assertIn("(github.event_name == 'push' && github.ref_type == 'branch')", staging_if)
        self.assertNotIn("vars.STAGING_ENABLED", lanes['dev'])
        self.assertNotIn("vars.STAGING_ENABLED", lanes['prod'])
        # Once in the staging lane and once in its qualification's condition.
        self.assertEqual(CALLER.count("vars.STAGING_ENABLED"), 2)
        self.assertEqual(CALLER.count("github.event_name == 'push'"), 3)
        self.assertIn("(github.event_name == 'push' && format('staging provider release (master push -staging.{0})', "
                      "github.run_number))", CALLER)

    def test_reusable_workflow_takes_the_environment_as_a_called_input(self):
        header = RELEASE.split('\njobs:\n', 1)[0]
        self.assertIn('\non:\n  workflow_call:\n', header)
        inputs = header.split('    inputs:\n', 1)[1]
        self.assertIn('      environment:\n', inputs)
        self.assertRegex(inputs, r'environment:\n(?:.*\n)*?        required: true')
        # The reusable workflow carries no triggers of its own.
        self.assertNotIn('  push:', header)
        self.assertNotIn('workflow_dispatch:', header)

    def test_staging_publication_is_serialized_and_validation_builds_are_not(self):
        # Each caller lane owns its group. Staging publishes one at a time across
        # runs and is never cancelled. The dev lane only builds a validation
        # artifact, so it keeps a per-run group and never joins a publication
        # group; no master path holds the release-dev group.
        lanes = caller_lanes()
        self.assertIn('group: release-staging', lanes['staging'])
        self.assertIn('cancel-in-progress: false',
                      lanes['staging'].split('    concurrency:\n', 1)[1].split('    uses:', 1)[0])
        per_run = "group: ${{ format('release-swift-{0}', github.run_id) }}"
        for name in ('dev', 'prod'):
            with self.subTest(lane=name):
                group = lanes[name].split('    concurrency:\n', 1)[1].split('    uses:', 1)[0]
                self.assertIn(per_run, group)
                self.assertIn('cancel-in-progress: false', group)
        self.assertNotRegex(CALLER, r'release-dev(?!-branch\.yml)')

    def test_production_secrets_require_the_resolved_production_environment(self):
        references = re.findall(r'(?m)^\s+((?:DEV|PROD|LEGACY)_[A-Z0-9_]+): (.*)$', RELEASE)
        self.assertEqual(len(references), 42)
        for name, value in references:
            with self.subTest(name=name):
                if name.startswith('DEV_'):
                    self.assertEqual(value, '${{ secrets.%s }}' % name)
                else:
                    self.assertRegex(value, r"^\$\{\{ needs\.resolve-env\.outputs\.environment == 'prod' && "
                                            r"(secrets|vars)\.[A-Z0-9_]+ \|\| '' \}\}$")
        self.assertNotRegex(RELEASE, r'secrets\[')

    def test_release_lane_stamps_only_a_resolved_dev_version_after_clean_source_check(self):
        self.assertIn('version: ${{ needs.resolve-env.outputs.version }}', job(RELEASE, 'build-provider'))
        self.assertNotIn('version:', job(QUALIFY, 'qualify-sdk-shard').split('lane: qualification', 1)[1])
        stamp = ACTION.split('- name: Stamp dev release version\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertLess(ACTION.index('- name: Verify checked-out source'), ACTION.index('- name: Stamp dev release version'))
        self.assertLess(ACTION.index('- name: Stamp dev release version'), ACTION.index('- name: Build optimized provider products'))
        self.assertIn("if: inputs.lane == 'release' && inputs.version != ''", stamp)
        self.assertEqual(stamp.count('./scripts/check-release-version.sh "$VERSION"'), 2)
        self.assertIn('test "$(git diff --name-only)" = "$SOURCE"', stamp)
        self.assertNotIn('version:', WARM.split('uses: ./.github/actions/provider-release-build', 1)[1].split('\n      - ', 1)[0])

    def test_build_and_qualification_lanes_use_sdk27_without_signing_secrets(self):
        # The build stays on Blacksmith in the credentialed workflow; the
        # shards read their lane in the workflow that gets no secrets.
        lanes = [(RELEASE, 'build-provider', 'release', 'resolve-env', 'blacksmith-12vcpu-macos-27'),
                 (QUALIFY, 'qualify-sdk-shard', 'qualification', 'route',
                  "${{ fromJSON(needs.route.outputs.routes)['release-qualify'] }}")]
        for workflow, name, lane, needed, runner in lanes:
            content = job(workflow, name)
            self.assertRegex(content, r'(?m)^    needs: ' + needed + '$')
            self.assertIn('    runs-on: ' + runner + '\n', content)
            self.assertIn('lane: ' + lane, content)
            self.assertIn('contents: read', content)
            self.assertNotIn('secrets.', content)
            self.assertNotRegex(content, r'(?m)^    environment:')

    def test_only_the_release_lane_compiles_the_release_environment(self):
        selector = 'DARKBLOOM_RELEASE_ENVIRONMENT: ${{ needs.resolve-env.outputs.environment }}'
        self.assertIn(selector, job(RELEASE, 'build-provider'))
        qualify = job(QUALIFY, 'qualify-sdk-shard')
        self.assertNotIn(selector, qualify)
        self.assertEqual(re.findall(r'DARKBLOOM_RELEASE_ENVIRONMENT: (\S+)', qualify), ['prod'])
        # Named once, in the job-level env: (no step or shell override).
        self.assertEqual(qualify.count('DARKBLOOM_RELEASE_ENVIRONMENT'), 1)
        self.assertRegex(qualify, r'(?m)^    env:\n(?:      #.*\n)*      DARKBLOOM_RELEASE_ENVIRONMENT: prod$')
        signing = job(RELEASE, 'build-and-release')
        for output in ['PRE_SIGN_SMOKE_OUTPUT', 'FINAL_SMOKE_OUTPUT']:
            self.assertIn(f'printf \'%s\\n\' "${output}" \\\n'
                          '            | grep -Eq "^build-environment-runtime-smoke: ${ENV_PREFIX} cli=${CLI_NAME} "', signing)
        # The packaged names follow the version; the compiled names must agree.
        resolve = 'python3 scripts/provider_release_identity.py "$VERSION" >> "$GITHUB_ENV"'
        for name in ['build-and-release', 'validate-older-macos']:
            self.assertIn(resolve, job(RELEASE, name))

    def test_signing_requires_the_build_after_qualification(self):
        content = job(RELEASE, 'build-and-release')
        # Qualification passed before this workflow started (the callers' lanes need `qualify`).
        self.assertIn('needs: [resolve-env, build-provider]', content)
        self.assertNotRegex(RELEASE, r'(?m)^  qualify')
        self.assertNotIn('needs.qualify', RELEASE)
        self.assertNotRegex(content, r'(?m)^    if:.*always')
        # Every release step is required. The only exceptions are the cluster
        # runtime facts steps: their failure fails the job only when the
        # payload carries the block (CLUSTER_RUNTIME_SEND); and the provider
        # build list's dry run, which starts after publication.
        self.assertEqual(RELEASE.count('continue-on-error:'), 4)
        self.assertIn('    continue-on-error: true\n', job(RELEASE, 'provider-build-list'))
        self.assertIn("continue-on-error: ${{ env.CLUSTER_RUNTIME_SEND != 'true' }}\n", step(content, FACTS_STEP))
        for name in (SHOW_STEP, RETAIN_STEP):
            self.assertIn('continue-on-error: true\n', step(content, name))
        self.assertNotIn('continue-on-error:', ACTION)
        self.assertIn('needs: [resolve-env, build-and-release]', job(RELEASE, 'validate-older-macos'))

    def test_publication_is_separate_and_retryable_without_signing(self):
        sign = job(RELEASE, 'build-and-release')
        stage = job(RELEASE, 'stage-release')
        publish = job(RELEASE, 'publish-release')
        for content in [sign, stage]:
            self.assertNotIn('/v1/releases', content)
            self.assertNotIn('gh release create', content)
            self.assertNotIn('releases/latest/', content)
            self.assertNotIn('secrets.PROD_RELEASE_KEY', content)
        # The release notes list the release's own pull requests (provider_release_notes.py);
        # GitHub's generated notes would list only those merged into master.
        for content in [RELEASE, CALLER, (ROOT / 'scripts/provider_release_github.py').read_text()]:
            self.assertNotIn('--generate-notes', content)
        self.assertNotIn('provider-release-publication.py stage', sign)
        self.assertNotIn('secrets.PROD_R2_ACCESS_KEY_ID', sign)
        self.assertNotIn('secrets.PROD_R2_SECRET_ACCESS_KEY', sign)
        self.assertNotIn('aws s3', sign)
        self.assertIn('publication_artifact: ${{ steps.publication_identity.outputs.artifact_name }}', sign)
        self.assertIn('provider-release-publication.py stage', stage)
        self.assertIn('provider-release-publication.py publish', publish)
        self.assertIn('needs: [resolve-env, build-and-release]', stage)
        self.assertIn('needs: [resolve-env, build-and-release, stage-release]', publish)
        for content in [stage, publish]:
            self.assertIn('needs.build-and-release.outputs.publication_artifact', content)
            self.assertIn('provider-release-publication.py download', content)
            self.assertIn('PUBLICATION_ARTIFACT_ID', content)
            self.assertIn('PUBLICATION_ARTIFACT_DIGEST', content)
            self.assertIn('--run-id "$RELEASE_SIGNING_RUN_ID"', content)
            self.assertIn('RELEASE_PAYLOAD_SHA256:', content)
            self.assertIn('RELEASE_PROVENANCE_SHA256:', content)
            self.assertNotIn('GITHUB_RUN_ATTEMPT', content)
            self.assertNotIn('notarytool', content)
            self.assertNotIn('APPLE_', content)
            self.assertNotIn('provider-release-build', content)
            self.assertIn("needs.resolve-env.outputs.publish == 'true'", content)
            self.assertNotRegex(content, r'(?m)^    if:.*always')
        self.assertIn('cancel-in-progress: false', publish)

    def test_source_policy_runs_from_master_before_candidate_code(self):
        resolver = job(RELEASE, 'resolve-env')
        self.assertNotIn('secrets.', resolver)
        self.assertIn('contents: read', resolver)
        self.assertIn('actions: read', resolver)
        self.assertLess(resolver.index('ref: master'), resolver.index('provider-release-resume.py verify-source'))
        self.assertLess(resolver.index('provider-release-resume.py verify-source'),
                        resolver.index('ref: ${{ steps.trust.outputs.source_sha }}'))
        self.assertLess(resolver.index('ref: ${{ steps.trust.outputs.source_sha }}'),
                        resolver.index('./scripts/resolve-provider-release.sh'))
        self.assertIn('workflow_sha: ${{ steps.trust.outputs.source_sha }}', resolver)
        for name in ['build-provider', 'build-and-release',
                     'stage-release', 'publish-release', 'validate-older-macos', 'provider-build-list']:
            content = job(RELEASE, name)
            self.assertIn('ref: ${{ needs.resolve-env.outputs.workflow_sha }}', content)
            self.assertIn('resolve-env', content.split('steps:', 1)[0])
        # The qualification jobs test the run's own commit; they hold nothing
        # the source gate protects, and the build action refuses another HEAD.
        for name in ['qualify-sdk-shard', 'qualify-sdk']:
            content = job(QUALIFY, name)
            self.assertIn('ref: ${{ github.sha }}', content)
            self.assertNotRegex(content, r'(?m)^    environment:')
        self.assertIn('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"', ACTION)

    def test_no_separate_hardware_or_receipt_authority(self):
        for forbidden in ['qualify-release:', 'validate-signed-macos26:', 'validate-signed-macos27:',
                          'PLATFORM_QUALIFICATION', 'RELEASE_QUALIFICATION',
                          'provider-release-qualification', '/v1/releases/qualify', '/v1/admin/app-attest/builds']:
            self.assertNotIn(forbidden, RELEASE)

    def test_artifact_handoff_is_same_run_and_source_bound(self):
        build = job(RELEASE, 'build-provider');sign = job(RELEASE, 'build-and-release')
        self.assertIn('provider-signing-validation.py stage', build)
        self.assertIn('unsigned-provider-${GITHUB_SHA}-${GITHUB_RUN_ATTEMPT}', build)
        # The signing job takes the build job's artifact by id and digest from
        # this run, never by name: the upload step's own outputs name it.
        upload = step(build, '- name: Transfer only unsigned products and resources\n')
        self.assertIn('        id: unsigned_retention\n', upload)
        self.assertIn('      artifact_id: ${{ steps.unsigned_retention.outputs.artifact-id }}\n', build)
        self.assertIn('      artifact_digest: ${{ steps.unsigned_retention.outputs.artifact-digest }}\n', build)
        self.assertIn('      RELEASE_UNSIGNED_ARTIFACT_ID: ${{ needs.resolve-env.outputs.unsigned_artifact_id || '
                      'needs.build-provider.outputs.artifact_id }}\n', sign)
        self.assertIn('      RELEASE_UNSIGNED_ARTIFACT_DIGEST: ${{ needs.resolve-env.outputs.unsigned_artifact_digest || '
                      'needs.build-provider.outputs.artifact_digest }}\n', sign)
        fetch = step(sign, "- name: Fetch and verify this run's unsigned build\n")
        self.assertIn('python3 scripts/provider-release-publication.py download \\\n'
                      '              --artifact-id "$RELEASE_UNSIGNED_ARTIFACT_ID" '
                      '--artifact-digest "$RELEASE_UNSIGNED_ARTIFACT_DIGEST" \\\n'
                      '              --run-id "$GITHUB_RUN_ID" --directory "$RUNNER_TEMP/unsigned-download"\n', fetch)
        self.assertIn('python3 scripts/provider-release-resume.py download', fetch)
        for by_name in ('gh run download', '--name', 'EXPECTED_ARTIFACT'):
            self.assertNotIn(by_name, sign)
        self.assertIn('EXPECTED_SOURCE: ${{ needs.resolve-env.outputs.source_sha }}', sign)
        self.assertIn('--source-sha "$EXPECTED_SOURCE" --version "$VERSION"', sign)
        self.assertLess(sign.index('provider-signing-validation.py unpack'),
                        sign.index('Import Developer ID certificate'))
        self.assertIn('test "$BUILD_SDK_VERSION" = "$PROVIDER_SDK_VERSION"', sign)
        self.assertIn('Final executable SDK differs from the selected build SDK', sign)

    def test_compilation_and_signing_require_ready_metal_toolchain(self):
        self.assertIn('python3 scripts/prepare-metal-toolchain.py', ACTION)
        signing = job(RELEASE, 'build-and-release')
        self.assertIn('python3 scripts/prepare-metal-toolchain.py', signing)
        self.assertLess(signing.index('python3 scripts/prepare-metal-toolchain.py'),
                        signing.index(STAGE_STEP))

    def test_checks_run_even_on_exact_cache_hits(self):
        for name in ['Verify public prompt golden vectors', 'Test provider with release SDK',
                     'Build optimized provider products', 'Build or validate source-matched metallib']:
            step = ACTION.split('- name: ' + name + '\n', 1)[1].split('\n    - name:', 1)[0]
            self.assertNotIn('cache-hit', step)
        self.assertIn('-- ../scripts/run-provider-tests.sh', ACTION)
        self.assertIn('steps.test-build.outcome == \'success\'', ACTION)
        self.assertIn('snapshot-mtimes', ACTION)
        self.assertIn('steps.keys.outputs.swift-prefix', ACTION)
        self.assertNotIn('spm-v3-', ACTION)

    def test_qualification_keeps_public_prompt_vectors_without_backend_execution(self):
        step = ACTION.split('- name: Verify public prompt golden vectors\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn("if: inputs.lane == 'qualification'", step)
        self.assertIn('./scripts/verify-prompt-parity.sh', step)
        self.assertNotIn('cache-hit', step)
        for forbidden in ('coordinator/', 'go.mod', 'actions/setup-go@', 'cargo ', 'rust-key', 'install-release-rust.sh'):
            self.assertNotIn(forbidden, ACTION)
            self.assertNotIn(forbidden, WARM)

    def test_warming_cannot_publish_or_seed_default_branch_from_pr(self):
        self.assertIn("cron: '47 6 * * *'", WARM)
        self.assertNotIn("branches: [master]", WARM)
        self.assertNotIn("'scripts/**'", WARM)
        # A pull request warms only when the one-shot `run-release-ci` label is
        # added: no path filter starts it, `unlabel` consumes the label, and the
        # gate (so the route and both lanes) skips every other label, which gets
        # a concurrency group of its own and cancels nothing.
        trigger = WARM.split('\non:\n', 1)[1].split('\npermissions:', 1)[0]
        self.assertIn("  pull_request:\n    types: [labeled]\n  workflow_dispatch:\n", trigger)
        self.assertNotIn('paths:', trigger)
        labeled = "github.event.label.name == 'run-release-ci'"
        self.assertIn("  cancel-in-progress: ${{ github.event_name != 'pull_request' || " + labeled + " }}\n", WARM)
        self.assertIn("(github.event_name == 'pull_request' && github.event.label.name != 'run-release-ci' && "
                      "format('provider-sdk27-cache-label-{0}', github.run_id))", WARM)
        self.assertIn("    if: ${{ github.event_name != 'pull_request' || " + labeled + " }}\n", job(WARM, 'gate'))
        unlabel = job(WARM, 'unlabel')
        self.assertIn("    if: ${{ github.event_name == 'pull_request' && " + labeled + " }}\n", unlabel)
        self.assertIn('    runs-on: ubuntu-24.04\n', unlabel)
        self.assertIn('issues/$PR_NUMBER/labels/run-release-ci" >/dev/null 2>&1 || true', unlabel)
        for name in ('gate', 'route', 'warm'):
            self.assertNotIn('issues:', job(WARM, name))
            self.assertNotIn('pull-requests:', job(WARM, name))
        self.assertIn("    needs: gate\n    if: ${{ needs.gate.outputs.run == 'true' }}\n", job(WARM, 'route'))
        self.assertIn("needs.gate.outputs.run == 'true' && (github.event_name == 'pull_request' || github.ref == 'refs/heads/master')", WARM)
        self.assertIn('lane: [release, qualification]', WARM)
        self.assertIn('max-parallel: 2', WARM)
        # Only PR warming may use a Darkbloom Sandbox; master and dispatched
        # warming feed release builds and keep the literal Blacksmith runner.
        self.assertIn("    runs-on: ${{ github.event_name == 'pull_request' && "
                      "fromJSON(needs.route.outputs.routes)['warm'] || 'blacksmith-12vcpu-macos-27' }}\n", WARM)
        self.assertIn("        warm macos_arm64 blacksmith-12vcpu-macos-27 "
                      "${{ github.event_name == 'pull_request' && 2 || 0 }} balanced 12x32\n", WARM)
        self.assertNotRegex(WARM, r'(?m)^  (pull_request_target|workflow_run):')
        for text in [WARM, ACTION]:
            for forbidden in ['secrets.', 'contents: write', 'gh release create', 'aws s3', 'notarytool']:
                self.assertNotIn(forbidden, text)
        self.assertIn('uses: ./.github/actions/provider-release-build', WARM)
        self.assertIn('provider-signing-validation.py stage', WARM)
        self.assertIn('provider-signing-validation.py unpack', WARM)

    def test_release_cache_scheduled_gate_fails_open_ignores_skipped_runs_and_respects_cache_ttl(self):
        import datetime, json, os, subprocess, tempfile
        gate_body = job(WARM, 'gate')
        raw_lines = gate_body.split('        run: |\n', 1)[1].splitlines()
        script_lines = []
        for line in raw_lines:
            if line and not line.startswith('          '):
                break
            script_lines.append(line[10:] if line.startswith('          ') else '')
        script = '\n'.join(script_lines) + '\n'
        now = datetime.datetime.now(datetime.timezone.utc)
        recent = (now - datetime.timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
        stale = (now - datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')

        def run_gate(responses, head_sha='bbbb', event_name='schedule'):
            with tempfile.TemporaryDirectory() as tmp:
                bin_dir = Path(tmp) / 'bin'
                bin_dir.mkdir()
                out = Path(tmp) / 'out'
                out.write_text('', encoding='utf-8')
                resp_file = Path(tmp) / 'responses.json'
                resp_file.write_text(json.dumps(responses), encoding='utf-8')
                stub = bin_dir / 'gh'
                stub.write_text(
                    '#!/usr/bin/env python3\n'
                    'import json, os, sys\n'
                    'responses = json.load(open(os.environ["GH_RESPONSES"]))\n'
                    'path = sys.argv[2]\n'
                    'entry = responses.get(path)\n'
                    'if entry is None or entry == "__FAIL__":\n'
                    '    sys.exit(1)\n'
                    'print(entry if isinstance(entry, str) else json.dumps(entry))\n',
                    encoding='utf-8',
                )
                stub.chmod(0o755)
                env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'GH_RESPONSES': str(resp_file),
                       'GITHUB_OUTPUT': str(out), 'EVENT_NAME': event_name, 'GH_TOKEN': 'tok',
                       'REPOSITORY': 'Layr-Labs/d-inference', 'HEAD_SHA': head_sha}
                proc = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                parsed = dict(line.split('=', 1) for line in out.read_text(encoding='utf-8').splitlines())
                return parsed['run']

        runs_url = 'repos/Layr-Labs/d-inference/actions/workflows/provider-release-cache.yml/runs?branch=master&status=success&per_page=10'
        ok_jobs = {'jobs': [{'name': 'SDK 27 release', 'conclusion': 'success'},
                            {'name': 'SDK 27 qualification', 'conclusion': 'success'}]}
        skipped_jobs = {'jobs': [{'name': 'SDK 27 release', 'conclusion': 'skipped'},
                                 {'name': 'SDK 27 qualification', 'conclusion': 'skipped'}]}

        # 1. Transient API failure fails open (run=true).
        self.assertEqual(run_gate({runs_url: '__FAIL__'}), 'true')
        # 2. Skipped daily run at HEAD does NOT poison last_green; falls back to earlier real warm.
        self.assertEqual(run_gate({
            runs_url: {'workflow_runs': [
                {'id': 20, 'event': 'schedule', 'head_sha': 'bbbb', 'created_at': recent},
                {'id': 10, 'event': 'schedule', 'head_sha': 'aaaa', 'created_at': recent},
            ]},
            'repos/Layr-Labs/d-inference/actions/runs/20/jobs?per_page=20': skipped_jobs,
            'repos/Layr-Labs/d-inference/actions/runs/10/jobs?per_page=20': ok_jobs,
            'repos/Layr-Labs/d-inference/compare/aaaa...bbbb': {'status': 'ahead', 'files': [{'filename': 'provider-swift/Sources/a.swift'}]},
        }), 'true')
        # 3. Real warm older than 6 days forces a fresh warm to prevent 7-day cache TTL expiry.
        self.assertEqual(run_gate({
            runs_url: {'workflow_runs': [
                {'id': 10, 'event': 'schedule', 'head_sha': 'bbbb', 'created_at': stale},
            ]},
            'repos/Layr-Labs/d-inference/actions/runs/10/jobs?per_page=20': ok_jobs,
        }), 'true')
        # 4. Recent real warm at HEAD skips (run=false).
        self.assertEqual(run_gate({
            runs_url: {'workflow_runs': [
                {'id': 10, 'event': 'schedule', 'head_sha': 'bbbb', 'created_at': recent},
            ]},
            'repos/Layr-Labs/d-inference/actions/runs/10/jobs?per_page=20': ok_jobs,
        }), 'false')
        # 5. Recent real warm with only docs/scripts changed skips; diverged or malformed compare fails open.
        for compare_resp, expected in (
            ({'status': 'ahead', 'files': [{'filename': 'scripts/unrelated.py'}]}, 'false'),
            ({'status': 'diverged', 'files': []}, 'true'),
            ('{malformed', 'true'),
        ):
            with self.subTest(compare_resp=compare_resp):
                self.assertEqual(run_gate({
                    runs_url: {'workflow_runs': [
                        {'id': 10, 'event': 'schedule', 'head_sha': 'aaaa', 'created_at': recent},
                    ]},
                    'repos/Layr-Labs/d-inference/actions/runs/10/jobs?per_page=20': ok_jobs,
                    'repos/Layr-Labs/d-inference/compare/aaaa...bbbb': compare_resp,
                }), expected)

    def test_final_app_meets_the_self_updater_designated_requirement(self):
        # The provider self-updater (DarkbloomCodeSignature, policy
        # .darkbloomProduction) accepts only this requirement, so every
        # environment's final archived app must meet it before upload.
        sign = job(RELEASE, 'build-and-release')
        swift = (ROOT / 'provider-swift/Sources/ProviderCore/Update/DarkbloomCodeSignature.swift').read_text()
        identity = (ROOT / 'provider-swift/Sources/DarkbloomSigningIdentity/'
                    'DarkbloomSigningIdentity.swift').read_text()
        self.assertIn('public static let teamID = "SLDQ2GJ6TL"', identity)
        self.assertIn('static let bundleIdentifier = "io.darkbloom.provider"', swift)
        self.assertIn("APPLE_TEAM_ID: 'SLDQ2GJ6TL'", RELEASE)
        # DarkbloomCodeSignature.designatedRequirement is the shared requirement
        # for the bundle identifier; test-signing-certificate-pins.py checks the
        # format and the certificate list behind SIGNING_CERTIFICATE_REQUIREMENT.
        self.assertIn('static let designatedRequirement =\n'
                      '        DarkbloomSigningIdentity.requirement(identifier: bundleIdentifier)', swift)
        certificate = re.search(r"^  SIGNING_CERTIFICATE_REQUIREMENT: '(.+)'$", RELEASE, re.M).group(1)
        swift_requirement = ('anchor apple generic and identifier "io.darkbloom.provider" '
                             'and certificate leaf[subject.OU] = "SLDQ2GJ6TL" '
                             'and certificate leaf = H"95b67556e04653f56ba5411d20d33dd263ef6e2a"')
        requirement = ('APP_REQUIREMENT="anchor apple generic and identifier \\"io.darkbloom.provider\\" '
                       'and certificate leaf[subject.OU] = \\"$APPLE_TEAM_ID\\" '
                       'and $SIGNING_CERTIFICATE_REQUIREMENT"')
        self.assertIn(requirement, sign)
        verify = sign.split(requirement, 1)[1]
        self.assertIn('codesign --verify --deep --strict --verbose=2 \\\n'
                      '            "-R=$APP_REQUIREMENT" "$SMOKE_ROOT/$APP_NAME"', verify)
        self.assertLess(sign.index('tar xzf /tmp/darkbloom-bundle-macos-arm64.tar.gz -C "$SMOKE_ROOT"'),
                        sign.index(requirement))
        # The shell value, after the shell removes its escapes and expands the
        # team and the certificates, is the Swift requirement byte for byte.
        shell_value = requirement.split('APP_REQUIREMENT="', 1)[1][:-1]
        self.assertEqual(shell_value.replace('\\"', '"').replace('$APPLE_TEAM_ID', 'SLDQ2GJ6TL')
                         .replace('$SIGNING_CERTIFICATE_REQUIREMENT', certificate),
                         swift_requirement)

    def test_source_gate_receives_the_lane_environment(self):
        # master's gate admits a dev push for environment dev only, so the trust
        # step must see the lane's environment; it still runs master's scripts.
        resolve = job(RELEASE, 'resolve-env')
        trust = resolve.split('- name: Verify reviewed workflow source before any release credentials\n', 1)[1] \
            .split('\n      - ', 1)[0]
        self.assertIn('RELEASE_ENVIRONMENT: ${{ inputs.environment }}', trust)
        self.assertIn('run: python3 scripts/provider-release-resume.py verify-source', trust)
        self.assertLess(resolve.index('ref: master'), resolve.index('verify-source'))

    def test_signing_and_runtime_qualification_are_retained(self):
        for expected in ['app-attest-callback-runtime-smoke: ok',
                         'qwen4-metal-resources-runtime-smoke: ok',
                         'gemma-optimizations-runtime-smoke: ok',
                         'codesign --verify --deep --strict', 'xcrun notarytool submit',
                         'BINARY_HASH=$(shasum -a 256',
                         'Register release with coordinator']:
            self.assertIn(expected, RELEASE)

    def test_audio_native_inference_is_required_in_release_qualification(self):
        fixture = ACTION.split('- name: Prepare selected MiMo audio fixture\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn("if: inputs.lane == 'qualification'", fixture)
        self.assertIn("prepare-mimo-audio-fixtures.py", fixture)
        gate = ACTION.split('- name: Qualify authenticated native MiMo PCM8 audio inference\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn("if: inputs.lane == 'qualification'", gate)
        self.assertIn("run-nested-suite.sh testNativeAudioRelease --no-parallel", gate)
        self.assertNotIn("cache-hit", gate)
        self.assertNotIn("continue-on-error:", gate)
        # Exactly one job runs it: the last shard, or an unsharded qualification.
        for content in (fixture, gate):
            self.assertIn("steps.lane.outputs.last == 'true'", content)

    def test_image_http_fixtures_reach_the_full_sdk_test_process(self):
        marker = '- name: Prepare MiMo image HTTP fixtures\n'
        self.assertIn(marker, ACTION)
        fixture = ACTION.split(marker, 1)[1].split('\n    - name:', 1)[0]
        self.assertIn("if: inputs.lane == 'qualification'", fixture)
        self.assertIn('python3 scripts/prepare-mimo-image-http-fixtures.py', fixture)
        self.assertIn('--github-env "$GITHUB_ENV"', fixture)
        self.assertNotIn('cache-hit', fixture)
        self.assertNotIn('continue-on-error:', fixture)
        self.assertLess(ACTION.index(marker), ACTION.index('- name: Test provider with release SDK\n'))
        # GitHub applies this environment file to the following step, not its writer.
        test = ACTION.split('- name: Test provider with release SDK\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn('-- ../scripts/run-provider-tests.sh', test)
        self.assertNotIn('MiMoImageHTTPIngressTests', test)

    def test_qwen_resource_regression_runs_without_a_cache_hit_bypass(self):
        step = ACTION.split('- name: Test Qwen resources in a relocated app\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn('python3 scripts/test-qwen4-packaged-resources.py', step)
        self.assertNotIn('if:', step)

    def test_every_environment_signs_with_the_real_developer_id_not_self_signed(self):
        # dev, staging and prod share one signing job with no per-environment
        # branch: all sign with the Developer ID, including the dev-branch lane
        # that release-dev-branch.yml calls. Nothing signs ad-hoc.
        sign = job(RELEASE, 'build-and-release')
        self.assertEqual(sign.count('--sign "$DEVELOPER_ID"'), 5)
        for adhoc in ('--sign -', 'codesign -s -', 'self-sign', 'ad-hoc', 'adhoc',
                      'runtime-codesign.sh', 'acknowledge_install_signature_gate'):
            self.assertNotIn(adhoc, sign)
        # The signing identity does not switch on the resolved environment.
        self.assertNotIn('DEVELOPER_ID_STAGING', RELEASE)
        self.assertNotIn("ENV_PREFIX == 'staging'", sign)
        self.assertIn("DEVELOPER_ID: 'Developer ID Application: Eigen Labs, Inc. (SLDQ2GJ6TL)'", RELEASE)

    def test_prod_signing_identity_is_only_reachable_through_a_tag(self):
        # Three independent gates keep a push off the prod signing identity:
        # the caller never routes a branch push to prod, resolve refuses prod on
        # a non-tag trigger, and signing requires a successful resolve-env.
        prod = CALLER.split('\n  prod:\n', 1)[1]
        self.assertNotIn("github.ref_type == 'branch'", prod)
        resolver = (ROOT / 'scripts/resolve-provider-release.sh').read_text()
        self.assertIn("Production publication requires a source-matching release tag", resolver)
        self.assertIn('Master pushes publish staging only', resolver)
        sign = job(RELEASE, 'build-and-release')
        self.assertIn("needs.resolve-env.result == 'success'", sign)

    def test_dev_and_staging_artifacts_avoid_collision_but_prod_stays_unqualified(self):
        # dev and staging unsigned and publication artifact names carry the
        # environment, so two lanes in one run never collide; prod
        # keeps the bare names the resume provenance reconstructs unchanged.
        build = job(RELEASE, 'build-provider')
        self.assertIn('ARTIFACT_NAME="unsigned-provider-${GITHUB_SHA}-${GITHUB_RUN_ATTEMPT}"', build)
        self.assertIn('if [ "$ENV_PREFIX" != prod ]; then', build)
        self.assertIn('ARTIFACT_NAME="unsigned-provider-${ENV_PREFIX}-${GITHUB_SHA}-${GITHUB_RUN_ATTEMPT}"', build)
        sign = job(RELEASE, 'build-and-release')
        self.assertIn('PUBLICATION_NAME="provider-publication-${RELEASE_SOURCE_SHA}-${GITHUB_RUN_ATTEMPT}"', sign)
        self.assertIn('PUBLICATION_NAME="provider-publication-${ENV_PREFIX}-${RELEASE_SOURCE_SHA}-${GITHUB_RUN_ATTEMPT}"', sign)
        # Both SDK lanes pass the environment so retained diagnostics never clash.
        self.assertIn('environment: ${{ needs.resolve-env.outputs.environment }}', job(RELEASE, 'build-provider'))
        self.assertIn('environment: ${{ inputs.environment }}', job(QUALIFY, 'qualify-sdk-shard'))
        # Release lanes add an -<environment>- infix; a caller passing no
        # environment (the warm lane) keeps the historical name with no empty
        # double dash.
        self.assertIn("provider-sdk-test-diagnostics${{ inputs.environment != '' && format('-{0}', inputs.environment) || '' }}-", ACTION)
        self.assertNotIn('provider-sdk-test-diagnostics--', ACTION)
        self.assertNotRegex(WARM, r'(?m)^\s+environment:')

    def test_qualification_shards_run_the_ci_plan_and_one_audited_job_gates_signing(self):
        shards = job(QUALIFY, 'qualify-sdk-shard')
        self.assertIn('    name: Qualify provider with SDK 27 (shard ${{ matrix.shard }})\n', shards)
        # The callers skip the whole call on a resume.
        self.assertNotRegex(shards, r'(?m)^    if:')
        self.assertIn('      fail-fast: false\n', shards)
        self.assertIn('        shard: [1, 2, 3, 4, 5]\n', shards)
        self.assertIn('          shard: ${{ matrix.shard }}/${{ strategy.job-total }}\n', shards)
        # One job carries the qualification result that signing needs and that
        # recovery binds by name; a shard's name never matches it.
        identity = (ROOT / 'scripts/provider_release_resume/identity.py').read_text()
        self.assertIn('QUALIFY_JOB = "Qualify provider with SDK 27"', identity)
        gate = job(QUALIFY, 'qualify-sdk')
        self.assertIn('    name: Qualify provider with SDK 27\n', gate)
        self.assertFalse(shards.split('    name: ', 1)[1].split('\n', 1)[0].endswith('Qualify provider with SDK 27'))
        self.assertRegex(gate, r'(?m)^    needs: qualify-sdk-shard$')
        self.assertIn('    runs-on: ubuntu-24.04\n', gate)
        # The implicit success() condition: a failed or skipped shard skips the gate.
        self.assertNotRegex(gate, r'(?m)^    if:')
        self.assertNotIn('secrets.', gate)
        self.assertIn('contents: read', gate)
        self.assertNotIn('continue-on-error', gate)
        # The gate audits what every shard executed against the full suite list.
        self.assertIn('pattern: provider-sdk-qualification-${{ inputs.environment }}-'
                      '${{ github.sha }}-shard-*\n', gate)
        self.assertIn('python3 scripts/provider-test-shards.py audit "${lists[0]}" "$RUNNER_TEMP/provider-sdk-shards"', gate)
        self.assertLess(gate.index('diff <('), gate.index('provider-test-shards.py audit'))
        # Each shard uploads its counts and suite list under that pattern.
        # No attempt in the name: a rerun of failed shards overwrites only theirs.
        retain = ACTION.split('- name: Retain shard counts for the audit\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn("name: provider-sdk-qualification${{ inputs.environment != '' && format('-{0}', inputs.environment) || '' }}"
                      "-${{ github.sha }}-shard-${{ steps.lane.outputs.index }}\n", retain)
        self.assertIn('overwrite: true\n', retain)
        listing = ACTION.split('- name: List the provider suite for the shard audit\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn('swift test list --skip-build > "$RUNNER_TEMP/provider-sdk-shard/provider-tests.txt"', listing)
        test = ACTION.split('- name: Test provider with release SDK\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn('export PROVIDER_TEST_SHARD="$QUALIFICATION_SHARD"', test)
        self.assertIn('export PROVIDER_TEST_REPORT_DIR="$RUNNER_TEMP/provider-sdk-shard"', test)
        # Prompt Parity runs once, against the test build, and reports both suites.
        build = ACTION.index('- name: Build SDK test products and stage Metal library\n')
        for name, script, suite, label in (('Verify public prompt golden vectors', 'verify-prompt-parity.sh',
                                            'ProductionPromptParityTests', 'prompt'),
                                           ('Verify pinned Nemotron prompts', 'verify-nemotron-prompt-parity.sh',
                                            'NemotronTemplateParityLiveTests', 'nemotron')):
            with self.subTest(step=name):
                self.assertLess(build, ACTION.index('- name: ' + name + '\n'))
                parity = ACTION.split('- name: ' + name + '\n', 1)[1].split('\n    - name:', 1)[0]
                self.assertIn("if: inputs.lane == 'qualification' && steps.lane.outputs.parity == 'true'", parity)
                # The count comes from the run's xUnit report and stdout, never
                # the merged console a SwiftPM warning can split.
                self.assertIn(f'NESTED_SUITE_REPORT="$report/parity-{label}" ./scripts/{script}\n', parity)
                self.assertNotIn('2>&1', parity)
                self.assertIn(f'provider-test-shards.py counts parity {suite} \\\n'
                              f'          "$report/parity-{label}-swift-testing.xml" "$report/parity-{label}.log" ',
                              parity)
        self.assertIn("PROMPT_PARITY_SKIP_BUILD: '1'", ACTION)
        # A shard applies to qualification only; the release lane builds whole.
        lane = ACTION.split('- name: Validate lane\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn('if [ "$LANE" != qualification ]', lane)
        self.assertIn('^([1-9][0-9]*)/([1-9][0-9]*)$', lane)
        self.assertNotIn('shard:', job(RELEASE, 'build-provider'))
        self.assertNotIn('shard:', WARM)

    def test_every_signing_staging_and_publishing_input_is_pinned_by_id_and_digest(self):
        # Any job of a run (a qualification shard on a Darkbloom Sandbox too)
        # can replace an artifact of a name. So every job that signs,
        # notarizes, stages, publishes or smoke-tests signed bytes downloads
        # the producing Blacksmith job's upload by ID, and the downloader
        # refuses a zip whose SHA-256 differs from that upload's digest.
        pins = {
            'build-and-release': ('build-provider', 'artifact'),
            'stage-release': ('build-and-release', 'publication_artifact'),
            'publish-release': ('build-and-release', 'publication_artifact'),
            'validate-older-macos': ('build-and-release', 'validation_artifact'),
            'provider-build-list': ('build-and-release', 'publication_artifact'),
        }
        producers = {('build-provider', 'artifact'): 'unsigned_retention',
                     ('build-and-release', 'publication_artifact'): 'publication_retention',
                     ('build-and-release', 'validation_artifact'): 'validation_retention'}
        for name in re.findall(r'(?m)^  ([a-z][a-z0-9-]*):\n', RELEASE.split('\njobs:\n', 1)[1]):
            with self.subTest(job=name):
                self.assertNotRegex(job(RELEASE, name), BY_NAME)
                if 'secrets.' in job(RELEASE, name) or 'codesign' in job(RELEASE, name):
                    self.assertIn(name, pins)
        for name, (producer, output) in pins.items():
            content = job(RELEASE, name)
            with self.subTest(job=name):
                self.assertIn(producer, content.split('    steps:', 1)[0])
                # The signer of a resume takes resolve-env's retained build first.
                self.assertIn('needs.%s.outputs.%s_id }}' % (producer, output), content)
                self.assertIn('needs.%s.outputs.%s_digest }}' % (producer, output), content)
                self.assertIn('python3 ' + DOWNLOADER + ' \\\n', content)
                self.assertRegex(content, r'--artifact-id "\$[A-Z_]+" --artifact-digest "\$[A-Z_]+"')
                self.assertRegex(content, r'--run-id "\$[A-Z_]+"')
        for (producer, output), step_id in producers.items():
            with self.subTest(output=output):
                produced = job(RELEASE, producer)
                self.assertIn('      %s_id: ${{ steps.%s.outputs.artifact-id }}\n' % (output, step_id), produced)
                self.assertIn('      %s_digest: ${{ steps.%s.outputs.artifact-digest }}\n' % (output, step_id), produced)
                self.assertRegex(produced, r'(?m)^        id: %s\n(?:        if: .+\n)?        uses: '
                                           r'actions/upload-artifact@' % step_id)
        # The signer of a resume takes the retained build by ID and digest too.
        self.assertIn('python3 scripts/provider-release-resume.py download', job(RELEASE, 'build-and-release'))
        # The downloader: metadata by ID, then the zip by ID, hashed before extraction.
        downloader = (ROOT / 'scripts/provider_release_artifact.py').read_text()
        body = downloader.split('def download(', 1)[1].split('\ndef ', 1)[0]
        self.assertIn("api = f'repos/{repository}/actions/artifacts/{artifact_id}'", body)
        self.assertIn("metadata.get('digest') != artifact_digest", body)
        self.assertIn("str(metadata.get('workflow_run', {}).get('id')) != run_id", body)
        self.assertLess(body.index("if sha256(archive) != artifact_digest.removeprefix('sha256:'):"),
                        body.index('source.extractall(output)'))
        # Signing validation hands its unsigned input to signing the same way.
        build = job(SIGNING_VALIDATION, 'build')
        signing = job(SIGNING_VALIDATION, 'signing')
        self.assertNotRegex(SIGNING_VALIDATION, BY_NAME)
        self.assertIn('      unsigned_artifact_id: ${{ steps.unsigned_retention.outputs.artifact-id }}\n', build)
        self.assertIn('      unsigned_artifact_digest: ${{ steps.unsigned_retention.outputs.artifact-digest }}\n', build)
        self.assertRegex(build, r'(?m)^        id: unsigned_retention\n        uses: actions/upload-artifact@')
        self.assertIn('UNSIGNED_ARTIFACT_ID: ${{ needs.build.outputs.unsigned_artifact_id }}', signing)
        self.assertIn('UNSIGNED_ARTIFACT_DIGEST: ${{ needs.build.outputs.unsigned_artifact_digest }}', signing)
        self.assertIn('python3 tooling/' + DOWNLOADER + ' \\\n', signing)
        self.assertIn('--run-id "$GITHUB_RUN_ID"', signing)
        self.assertRegex(job(SIGNING_VALIDATION, 'build'), r'(?m)^    runs-on: blacksmith-')

    def test_qualification_never_sits_in_the_credentialed_call(self):
        # The plane refuses a Darkbloom-routable job inside a call that passes
        # secrets. The shards and their gate live in release-qualify.yml,
        # which reads no secret; release-provider.yml routes nothing.
        code = re.sub(r'(?m)^\s*#.*$', '', QUALIFY)
        self.assertNotRegex(code, r'(?i)(?<![A-Za-z0-9_.])secrets(?![A-Za-z0-9_])')
        self.assertIn('\npermissions:\n  contents: read\n', QUALIFY)
        self.assertNotIn('needs.route', RELEASE)
        self.assertNotIn('darkbloom-route.yml', RELEASE)
        for runner in re.findall(r'(?m)^    runs-on: (.+)$', RELEASE):
            self.assertRegex(runner, r'^(blacksmith-[a-z0-9-]+|ubuntu-24\.04)$')
        self.assertEqual(set(re.findall(r'(?m)^  ([a-z][a-z0-9-]*):\n', QUALIFY.split('\njobs:\n', 1)[1])),
                         {'route', 'qualify-sdk-shard', 'qualify-sdk'})
        # Qualification builds and tests on the release toolchain, as before.
        self.assertIn("  DARKBLOOM_PROVIDER_TOOLCHAIN: release\n", QUALIFY)
        self.assertIn("  MLX_METALLIB_DEPLOYMENT_TARGET: '26.2'\n", QUALIFY)

    def test_no_release_job_restores_or_saves_an_actions_cache(self):
        # Any job of a run on a branch, a Darkbloom-routed one included, holds
        # the run's cache token and can write any key of the branch's scope;
        # GitHub cannot limit a key to Blacksmith jobs. So the release
        # workflows pin CI_ACTIONS_CACHE off at their top, nothing turns it
        # back on, and every cache step of the build action is gated on it.
        for name, text in (('release-provider.yml', RELEASE), ('release-qualify.yml', QUALIFY)):
            code = re.sub(r'(?m)^\s*#.*\n', '', text)
            with self.subTest(workflow=name):
                header = code.split('\njobs:\n', 1)[0]
                self.assertRegex(header, r"(?m)^env:\n(?:  \S.*\n)*?  CI_ACTIONS_CACHE: 'off'\n")
                self.assertEqual(code.count('CI_ACTIONS_CACHE'), 1)
                self.assertNotIn('actions/cache', code)
                self.assertNotRegex(code, r'(?m)^\s+cache(-dependency-path)?:')
                self.assertIn('uses: ./.github/actions/provider-release-build', code)
        steps = re.split(r'\n    - ', ACTION.split('\n  steps:\n', 1)[1])
        cache_steps = [step for step in steps if re.search(r'(?m)^\s+uses: actions/cache(/restore|/save)?@', step)]
        self.assertEqual(len(cache_steps), 6)
        for step in cache_steps:
            with self.subTest(step=step.split('\n', 1)[0]):
                self.assertRegex(step, r"(?m)^      if: env\.CI_ACTIONS_CACHE != 'off'( && |$)")
        # The action uses no other cache: no setup-* `cache:` input, no other
        # cache action, no nested local action, and nothing it runs turns the
        # switch back on (a `$GITHUB_ENV` write of CI_ACTIONS_CACHE).
        self.assertNotRegex(ACTION, r'(?m)^\s+cache(-dependency-path)?:')
        self.assertEqual(sorted(set(re.findall(r'(?m)^\s+uses: (\S+)', ACTION))), [
            'actions/cache/restore@1bd1e32a3bdc45362d1e726936510720a7c30a57',
            'actions/cache/save@1bd1e32a3bdc45362d1e726936510720a7c30a57',
            'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'])
        self.assertNotIn('CI_ACTIONS_CACHE=', ACTION)
        for script in sorted((ROOT / 'scripts').rglob('*')):
            if script.is_file() and script.suffix in ('.py', '.sh') and not script.name.startswith('test-'):
                self.assertNotIn('CI_ACTIONS_CACHE', script.read_text(errors='replace'), script.name)
        # setup-node v4.4.0 caches only with `cache:`. v5 and later also cache
        # on a packageManager field, so a bump must set package-manager-cache:
        # false; this pin makes the bump fail here first.
        desktop = (ROOT / '.github/workflows/release-desktop.yml').read_text()
        self.assertEqual(set(re.findall(r'uses: actions/setup-node@(\S+)', desktop)),
                         {'49933ea5288caeca8642d1e84afbd3f7d6820020'})
        # The other signing workflows restore no Actions cache either.
        for name in ('release-desktop.yml', 'provider-signing-validation.yml', 'release-swift.yml',
                     'release-dev-branch.yml'):
            code = re.sub(r'(?m)^\s*#.*\n', '', (ROOT / '.github/workflows' / name).read_text())
            with self.subTest(workflow=name):
                self.assertNotIn('actions/cache', code)
                self.assertNotRegex(code, r'(?m)^\s+cache(-dependency-path)?:')

    def test_cluster_helper_objects_share_the_release_swift_cache(self):
        # The native worker build reuses objects like the provider build; the
        # Metal library is never taken from a cache, and the helper checks
        # always run.
        worker = 'libs/darkbloom-cluster-worker/.build-native-worker'
        for name in ('Restore SDK-specific Swift build cache', 'Save SDK-specific Swift build cache'):
            cache = ACTION.split('- name: ' + name + '\n', 1)[1].split('\n    - name:', 1)[0]
            self.assertIn('          ' + worker + '\n', cache)
        restore = ACTION.split('- name: Restore unchanged source timestamps\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn('libs/mlx-swift-lm/.build ' + worker + '; do', restore)
        self.assertIn('-name mlx.metallib -delete', restore)
        helpers = ACTION.split('- name: Build cluster helpers (worker and placement tool)\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertNotIn('cache-hit', helpers)
        identity = (ROOT / 'scripts/provider_release_cache/identity.py').read_text()
        for recipe in ('"scripts/build-cluster-helpers.sh"', '"libs/darkbloom-cluster-worker/build-native-worker.sh"'):
            self.assertIn(recipe, identity)

    def test_cluster_runtime_facts_come_from_the_final_signed_app_without_secrets(self):
        sign = job(RELEASE, 'build-and-release')
        facts = step(sign, FACTS_STEP)
        # Every lane and every run: no condition of its own.
        self.assertNotIn('\n        if:', facts)
        # After signing, notarization, the final tar and its hashes; before the
        # payload is prepared and the keychain is cleaned up.
        self.assertLess(sign.index('xcrun notarytool submit'), sign.index(FACTS_STEP))
        self.assertLess(sign.index('echo "BUNDLE_HASH=$BUNDLE_HASH"'), sign.index(FACTS_STEP))
        for later in ('- name: Record signed validation identity', '- name: Prepare exact signed release identity',
                      '- name: Cleanup keychain'):
            self.assertLess(sign.index(FACTS_STEP), sign.index(later))
        # No secret: none referenced, the two secret-derived GITHUB_ENV values
        # removed and the signing keychain already gone before release code
        # runs, which then runs with an empty environment.
        self.assertNotIn('secrets.', facts)
        self.assertNotIn('\n        env:', facts)
        first_run = facts.index('scripts/provider-cluster-runtime-facts.sh "$FACTS_ROOT/app/$APP_NAME" "$CLI_NAME" '
                                '"$ENV_PREFIX" "$FACTS_ROOT/facts"')
        for removal in ('unset r2_public_url coordinator_url', 'test ! -e "$KEYCHAIN_PATH"'):
            self.assertLess(facts.index(removal), first_run)
        # The removal step deleted the keychain (test_no_release_code_runs_while_the_signing_key_exists);
        # a keychain still there fails this step.
        self.assertLess(sign.index(REMOVE_STEP), sign.index(FACTS_STEP))
        self.assertNotIn('|| true', facts)
        self.assertNotIn('2>/dev/null', facts)
        # The final archived bytes, extracted afresh after their hash is checked.
        self.assertLess(facts.index('= "$BUNDLE_HASH"'), facts.index('tar -xzf /tmp/darkbloom-bundle-macos-arm64.tar.gz'))
        self.assertLess(facts.index('tar -xzf /tmp/darkbloom-bundle-macos-arm64.tar.gz'), first_run)
        # A hang ends the step; with the block unsent its failure only warns.
        self.assertIn('timeout-minutes: 20\n', facts)
        # The shared script: the app's own CLI only ever runs with an empty
        # environment, and the metadata comes from the release's environment.
        self.assertTrue(FACTS_SCRIPT.startswith('#!/usr/bin/env bash\n') and 'set -euo pipefail\n' in FACTS_SCRIPT)
        self.assertEqual(FACTS_SCRIPT.count('/Contents/MacOS/'), 1)
        self.assertIn('  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$root/home" DARKBLOOM_NO_UPDATE_CHECK=1 \\\n'
                      '    "$app/Contents/MacOS/$cli" cluster runtime-facts "$@"\n', FACTS_SCRIPT)
        fetch = 'python3 "$scripts/provider-cluster-runtime-models.py" --environment "$environment"'
        self.assertLess(FACTS_SCRIPT.index('runtime_facts --list-release-models'), FACTS_SCRIPT.index(fetch))
        self.assertLess(FACTS_SCRIPT.index(fetch),
                        FACTS_SCRIPT.index('runtime_facts --app "$app" --release-candidates "$root/candidates"'))
        # Any failure fails the script: no swallowed status, no required list.
        for soft in ('|| status', '|| true', '--require-model', '2>'):
            self.assertNotIn(soft, FACTS_SCRIPT)

    def test_cluster_runtime_is_sent_only_when_the_environment_variable_is_true(self):
        sign = job(RELEASE, 'build-and-release')
        switch = sign.split('      CLUSTER_RUNTIME_SEND: >-\n', 1)[1].split('\n\n', 1)[0]
        self.assertEqual(' '.join(switch.split()),
                         "${{ needs.resolve-env.outputs.publish == 'true' && "
                         "((needs.resolve-env.outputs.environment == 'dev' && vars.DEV_CLUSTER_RUNTIME_ENABLED == 'true') || "
                         "(needs.resolve-env.outputs.environment == 'staging' && vars.STAGING_CLUSTER_RUNTIME_ENABLED == 'true') || "
                         "(needs.resolve-env.outputs.environment == 'prod' && vars.PROD_CLUSTER_RUNTIME_ENABLED == 'true')) }}")
        for variable in ('DEV', 'STAGING', 'PROD'):
            self.assertEqual(RELEASE.count(f'vars.{variable}_CLUSTER_RUNTIME_ENABLED'), 1)
        self.assertEqual(RELEASE.count('CLUSTER_RUNTIME_SEND: >-'), 1)
        # The facts step names the file for prepare only when the block is sent.
        self.assertEqual(RELEASE.count('CLUSTER_RUNTIME_FILE='), 1)
        self.assertIn('          if [ "$CLUSTER_RUNTIME_SEND" = true ]; then\n'
                      '            echo "CLUSTER_RUNTIME_FILE=$FACTS_ROOT/facts/cluster-runtime.json" >> "$GITHUB_ENV"\n'
                      '          fi\n', step(sign, FACTS_STEP))
        # Prepare: with the switch off, today's command byte for byte; with it
        # on, the facts are required and passed.
        prepare = step(sign, '- name: Prepare exact signed release identity\n')
        today = ('python3 scripts/provider-release-publication.py prepare \\\n'
                 '              --directory "$RUNNER_TEMP/provider-publication" --bundle /tmp/darkbloom-bundle-macos-arm64.tar.gz\n')
        on, off = prepare.split('          if [ "$CLUSTER_RUNTIME_SEND" = true ]; then\n', 1)[1].split('          else\n', 1)
        off = off.split('          fi\n', 1)[0]
        self.assertEqual(off, '            ' + today)
        self.assertIn('test -s "${CLUSTER_RUNTIME_FILE:-}"\n', on)
        self.assertLess(on.index('test -s'), on.index('prepare'))
        self.assertIn('--cluster-runtime "$CLUSTER_RUNTIME_FILE"\n', on)
        self.assertEqual(RELEASE.count('--cluster-runtime'), 1)

    def test_cluster_runtime_facts_are_always_shown_and_retained(self):
        sign = job(RELEASE, 'build-and-release')
        for name in (SHOW_STEP, RETAIN_STEP):
            with self.subTest(step=name):
                content = step(sign, name)
                # They also run when the facts step failed, and never fail the job.
                self.assertIn("if: ${{ !cancelled() && (steps.cluster_runtime.outcome == 'success' || "
                              "steps.cluster_runtime.outcome == 'failure') }}\n", content)
                self.assertNotIn('secrets.', content)
                self.assertLess(sign.index(FACTS_STEP), sign.index(name))
                self.assertLess(sign.index(name), sign.index('- name: Prepare exact signed release identity'))
        self.assertIn('        id: cluster_runtime\n', step(sign, FACTS_STEP))
        show = step(sign, SHOW_STEP)
        self.assertIn('>> "$GITHUB_STEP_SUMMARY"', show)
        self.assertIn('python3 -m json.tool --sort-keys "$FACTS/cluster-runtime.json"', show)
        self.assertIn('cat "$FACTS/skipped.md"', show)
        retain = step(sign, RETAIN_STEP)
        self.assertIn('uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a', retain)
        # Lanes of one run never collide.
        self.assertIn('name: cluster-runtime-${{ needs.resolve-env.outputs.environment }}-'
                      '${{ needs.resolve-env.outputs.source_sha }}-${{ github.run_attempt }}\n', retain)
        self.assertIn('${{ runner.temp }}/cluster-runtime/facts/cluster-runtime.json\n', retain)
        self.assertIn('if-no-files-found: warn\n', retain)

    def test_the_cluster_runtime_scripts_start_the_release_lanes(self):
        # The facts script runs the fetch script; a change to either starts
        # both release lanes, like every other script a release runs.
        for script in ('scripts/provider-cluster-runtime-models.py', 'scripts/provider-cluster-runtime-facts.sh'):
            self.assertIn(f"      - '{script}'\n", CALLER)
            self.assertIn(f"'{script}'", DEV_CALLER)

    def test_shipped_products_link_a_fixed_main_thread_stack(self):
        """Every product build of a shipped executable links the 8 MiB main-thread stack and checks it."""
        self.assertIn(f'expected={0x800000}', STACK_CHECK.read_text())
        products = ACTION.split('- name: Build optimized provider products\n', 1)[1].split('\n    - name:', 1)[0]
        for workflow, text in [('provider-release-build', products), ('provider-signing-validation', SIGNING_VALIDATION)]:
            builds = [line for line in text.splitlines() if 'swift build -c release' in line and '--product' in line]
            self.assertEqual(len(builds), 3, workflow)
            self.assertIn(f'stack=({FIXED_STACK})', text, workflow)
            for line in builds:
                self.assertTrue(line.rstrip().endswith('"${stack[@]}"'), f'{workflow}: {line.strip()}')
            self.assertIn('check-fixed-stack.sh', text, workflow)
        # Signing validation also checks the cluster helpers it builds.
        self.assertIn('check-fixed-stack.sh \\\n            "$RUNNER_TEMP/cluster-helpers/darkbloom-cluster-worker" '
                      '"$RUNNER_TEMP/cluster-helpers/darkbloom-cluster-plan"', SIGNING_VALIDATION)
        build = next(line for line in NATIVE_WORKER_BUILD.splitlines() if line.strip().startswith('-Xcc -target'))
        self.assertIn(FIXED_STACK, build)
        self.assertIn('scripts/check-fixed-stack.sh" "$binary"', NATIVE_WORKER_BUILD)

    @unittest.skipUnless(shutil.which('xcrun') and Path('/usr/bin/otool').exists(), 'needs the Xcode command line tools')
    def test_main_thread_stack_check_tells_the_fixed_stack_from_the_default(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'main.c'
            source.write_text('int main(void) { return 0; }\n')
            fixed, default = Path(directory) / 'fixed', Path(directory) / 'default'
            subprocess.run(['xcrun', 'clang', '-o', str(fixed), str(source), *FIXED_STACK.split()], check=True)
            subprocess.run(['xcrun', 'clang', '-o', str(default), str(source)], check=True)
            self.assertEqual(subprocess.run(['bash', str(STACK_CHECK), str(fixed)], capture_output=True).returncode, 0)
            refused = subprocess.run(['bash', str(STACK_CHECK), str(fixed), str(default)], capture_output=True, text=True)
            self.assertEqual(refused.returncode, 1)
            self.assertIn(f'{default} does not link the fixed main-thread stack', refused.stderr)
            # Exactly 8 MiB: a size that merely starts with the same digits (80 MiB) is refused too.
            larger = Path(directory) / 'larger'
            subprocess.run(['xcrun', 'clang', '-o', str(larger), str(source), '-Wl,-stack_size,0x5000000'], check=True)
            refused = subprocess.run(['bash', str(STACK_CHECK), str(larger)], capture_output=True, text=True)
            self.assertEqual(refused.returncode, 1)
            self.assertIn(f'{larger} does not link the fixed main-thread stack', refused.stderr)

    def test_no_release_code_runs_while_the_signing_key_exists(self):
        sign = job(RELEASE, 'build-and-release')
        steps = named_steps(sign)
        names = [name for name, _ in steps]
        body = dict(steps)
        imported = names.index('Import Developer ID certificate')
        removed = names.index('Remove the signing keychain')
        # The key exists for two steps: its import and the codesign calls.
        self.assertEqual(names[imported:removed + 1],
                         ['Import Developer ID certificate', 'Sign bundle', 'Remove the signing keychain'])
        # Every run of the provider this release built, in order: the unsigned
        # smoke before the key exists, the rest after it is deleted.
        runs = [name for name, content in steps if runs_release_code(content)]
        self.assertEqual(runs, ['Stage bundle and smoke it before signing',
                                'Verify the signed bundle and prepare the notarization input',
                                'Staple and verify the final artifact',
                                'Compute cluster runtime facts from the final signed app'])
        self.assertLess(names.index(runs[0]), imported)
        for name in runs[1:]:
            self.assertGreater(names.index(name), removed, name)
        # The four direct runs (two runtime smokes, the evaluator help, the
        # version) are the only ones; a fifth must be placed on purpose.
        self.assertEqual(len(PROVIDER_RUN.findall(sign)), 4)
        for marker, owner in (('PRE_SIGN_SMOKE_OUTPUT=$(', runs[0]), ('SIGNED_BENCHMARK_HELP=$(', runs[1]),
                              ('FINAL_SMOKE_OUTPUT=$(', runs[2]), ('REPORTED=$(', runs[2])):
            self.assertIn(marker, body[owner])
            self.assertEqual(sign.count(marker), 1)
        # Every signature is made inside the signing step, through the keychain.
        signing = body['Sign bundle']
        self.assertEqual(signing.count('--sign "$DEVELOPER_ID"'), sign.count('--sign "$DEVELOPER_ID"'))
        self.assertIn('./scripts/sign-cluster-helpers.sh "$APP" "$KEYCHAIN_PATH" "$DEVELOPER_ID"', signing)
        self.assertEqual([name for name, content in steps if '--keychain "$KEYCHAIN_PATH"' in content], ['Sign bundle'])
        # The removal fails the job when the key or its identity is still there.
        self.assertEqual(body['Remove the signing keychain'].strip(),
                         'run: ./scripts/remove-signing-keychain.sh "$KEYCHAIN_PATH" "$DEVELOPER_ID"')
        # A run that failed in between still loses its keychain.
        self.assertEqual(names[-1], 'Cleanup keychain')
        self.assertIn('        if: always()\n', body['Cleanup keychain'])
        self.assertIn('security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true', body['Cleanup keychain'])

    def test_signing_key_is_imported_only_through_the_shared_script(self):
        sign = job(RELEASE, 'build-and-release')
        imported = dict(named_steps(sign))['Import Developer ID certificate']
        self.assertIn('          KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"\n'
                      '          echo "KEYCHAIN_PATH=$KEYCHAIN_PATH" >> "$GITHUB_ENV"\n'
                      '          ./scripts/import-signing-certificate.sh "$KEYCHAIN_PATH"\n', imported)
        # The certificate secrets reach that one step and no other.
        for secret in ('APPLE_CERTIFICATE_P12', 'APPLE_CERTIFICATE_PASSWORD'):
            self.assertEqual(RELEASE.count('secrets.' + secret), 1)
            self.assertIn('${{ secrets.' + secret + ' }}', imported)
        # No workflow that signs keeps keychain handling of its own: a fixed
        # password, an extractable key or a certificate outside RUNNER_TEMP
        # cannot come back beside the script
        # (scripts/test-signing-keychain.py runs it).
        workflows = {path.name: path.read_text() for path in sorted((ROOT / '.github/workflows').glob('*.yml'))}
        signing = [name for name, text in workflows.items() if 'secrets.APPLE_CERTIFICATE_P12' in text]
        self.assertEqual(signing, ['provider-signing-validation.yml', 'release-desktop.yml', 'release-provider.yml'])
        for name in signing:
            with self.subTest(workflow=name):
                self.assertIn('scripts/import-signing-certificate.sh', workflows[name])
                self.assertIn('scripts/remove-signing-keychain.sh', workflows[name])
                for inline in ('security create-keychain', 'security import', 'security unlock-keychain',
                               'set-key-partition-list', '-p "build"', '/tmp/cert.p12', 'productsign'):
                    self.assertNotIn(inline, workflows[name])
        script = (ROOT / 'scripts/import-signing-certificate.sh').read_text()
        for rule in ('umask 077\n', 'keychain_password=$(openssl rand -hex 24)\n',
                     'certificate=$(mktemp "$RUNNER_TEMP/signing-certificate.XXXXXX")\n',
                     "trap 'rm -f \"$certificate\"' EXIT\n", '  -T /usr/bin/codesign -f pkcs12 -x\n'):
            self.assertIn(rule, script)
        self.assertNotIn('/tmp/', script)

    def test_notarization_credentials_reach_only_the_notarytool_step(self):
        sign = job(RELEASE, 'build-and-release')
        steps = named_steps(sign)
        names = [name for name, _ in steps]
        body = dict(steps)
        for secret in ('APPLE_ID', 'APPLE_APP_PASSWORD'):
            self.assertEqual([name for name, content in steps if 'secrets.' + secret in content], ['Notarize bundle'])
            self.assertEqual(RELEASE.count('secrets.' + secret), 1)
        notarize = body['Notarize bundle']
        # The step submits, and reads Apple's log when refused; it runs nothing
        # the release built, and stapling and the final checks follow without
        # the credentials.
        self.assertEqual(re.findall(r'xcrun (\S+) (\S+)', notarize), [('notarytool', 'submit'), ('notarytool', 'log')])
        self.assertFalse(runs_release_code(notarize))
        for later in ('stapler', 'spctl', 'runtime-smoke', 'tar czf', 'codesign'):
            self.assertNotIn(later, notarize)
        self.assertLess(names.index('Remove the signing keychain'), names.index('Notarize bundle'))
        final = names[names.index('Notarize bundle') + 1]
        self.assertEqual(final, 'Staple and verify the final artifact')
        self.assertNotIn('secrets.', body[final])
        self.assertNotIn('APPLE_APP_PASSWORD', body[final])
        self.assertIn('xcrun stapler staple "$APP"', body[final])

    def test_publication_tools_are_hash_pinned_and_installed_before_any_credential(self):
        for name in ('stage-release', 'publish-release'):
            with self.subTest(job=name):
                steps = named_steps(job(RELEASE, name))
                names = [step_name for step_name, _ in steps]
                self.assertLess(names.index('Install publication tools'), names.index('Resolve env-specific secrets'))
                install = dict(steps)['Install publication tools']
                self.assertIn('/bin/pip" install --require-hashes --only-binary :all: \\\n'
                              '            -r scripts/provider-release-publication-requirements.txt\n', install)
                self.assertNotIn('secrets.', install)
        self.assertEqual(RELEASE.count('pip" install'), 2)
        self.assertNotRegex(RELEASE, r'pip3? install')
        # Every requirement is one exact version with at least one SHA-256.
        text = REQUIREMENTS.read_text()
        requirements = [line for line in text.replace('\\\n', '').splitlines() if line and not line.startswith('#')]
        packages = []
        for requirement in requirements:
            with self.subTest(requirement=requirement.split()[0]):
                match = re.fullmatch(r'([A-Za-z0-9_.-]+)==[0-9][A-Za-z0-9_.]*((?:\s+--hash=sha256:[0-9a-f]{64})+)', requirement)
                self.assertIsNotNone(match, requirement)
                packages.append(match.group(1).lower())
        self.assertIn('awscli', packages)
        self.assertEqual(len(packages), len(set(packages)))
        # A change to the pins starts both release lanes, like the scripts.
        self.assertIn("      - 'scripts/provider-release-publication-requirements.txt'\n", CALLER)
        self.assertIn("'scripts/provider-release-publication-requirements.txt'", DEV_CALLER)

    def test_only_the_publication_job_can_write_repository_contents(self):
        header = RELEASE.split('\njobs:\n', 1)[0]
        self.assertIn('\npermissions:\n  contents: read\n  actions: read', header)
        self.assertEqual(RELEASE.count('contents: write'), 1)
        self.assertIn('    permissions:\n      contents: write', job(RELEASE, 'publish-release'))
        self.assertIn('gh release create', (ROOT / 'scripts/provider_release_github.py').read_text() + RELEASE)
        for name in ('resolve-env', 'build-provider', 'build-and-release',
                     'stage-release', 'validate-older-macos', 'provider-build-list'):
            with self.subTest(job=name):
                self.assertIn('    permissions:\n      contents: read\n', job(RELEASE, name))
        for name in ('qualify-sdk-shard', 'qualify-sdk'):
            with self.subTest(job=name):
                self.assertIn('    permissions:\n      contents: read\n', job(QUALIFY, name))

    def test_the_provider_build_list_is_prepared_after_publication_without_credentials(self):
        # The next signed provider build list adds this release's build, read
        # from the publication artifact by ID and digest. It holds no secret,
        # no environment and no write permission, starts only after a
        # production publication succeeded, and cannot fail the release. Until
        # a signing key is configured it signs only with the RFC 8032 test key
        # and publishes nothing (scripts/test-provider-release-build-list.py).
        content = job(RELEASE, 'provider-build-list')
        self.assertIn('    needs: [resolve-env, build-and-release, publish-release]\n', content)
        self.assertEqual(condition(content), "!cancelled() && needs.publish-release.result == 'success' && "
                                             "needs.resolve-env.outputs.environment == 'prod'")
        self.assertIn('    runs-on: ubuntu-24.04\n', content)
        self.assertIn('    permissions:\n      contents: read\n      actions: read\n    # ', content)
        for forbidden in ('secrets.', 'id-token', 'contents: write', 'APPLE_', 'RELEASE_KEY', 'aws s3'):
            self.assertNotIn(forbidden, content)
        self.assertNotRegex(content, r'(?m)^    environment:')
        self.assertEqual(re.findall(r'--signer (\S+)', content), ['test'])
        steps = named_steps(content)
        names = [name for name, _ in steps]
        self.assertEqual(names, ["Download this run's exact signed publication artifact",
                                 "Prepare the next list with this release's build",
                                 'Sign it with the test key and show the publication plan (dry run)',
                                 'Retain the prepared list'])
        body = dict(steps)
        self.assertIn('provider-release-build-list.py prepare release', body[names[1]])
        dry_run = body[names[2]]
        self.assertEqual(dry_run.count('--dry-run'), 2)
        self.assertIn('provider-release-build-list.py sign release', dry_run)
        self.assertIn('provider-release-build-list.py publish release', dry_run)
        self.assertNotIn('gh release', content)
        self.assertIn('group: provider-build-list-publication\n      cancel-in-progress: false', content)

    def test_every_job_that_reads_a_secret_names_the_lanes_environment(self):
        jobs = re.findall(r'(?m)^  ([A-Za-z0-9_-]+):\n', RELEASE.split('\njobs:\n', 1)[1])
        with_secrets = [name for name in jobs if 'secrets.' in job(RELEASE, name)]
        self.assertEqual(with_secrets, ['build-and-release', 'stage-release', 'publish-release'])
        # Exactly those jobs name an environment, so its branch and tag policy
        # and its reviewers apply before any of them can read a secret; the
        # lane's environment is resolved once and used nowhere else.
        # Signing and staging use the lane's build environment (prod-build for
        # a production release: no reviewers); publication, which registers
        # the release with every provider, uses the deployment environment.
        build = "    environment: ${{ needs.resolve-env.outputs.build_environment || 'prod' }}\n"
        deployment = "    environment: ${{ needs.resolve-env.outputs.deployment || 'prod' }}\n"
        environment_line = {'build-and-release': build, 'stage-release': build, 'publish-release': deployment}
        for name in jobs:
            with self.subTest(job=name):
                named = re.findall(r'(?m)^    environment:.*\n', job(RELEASE, name))
                self.assertEqual(named, [environment_line[name]] if name in with_secrets else [])
        self.assertEqual(RELEASE.count('needs.resolve-env.outputs.deployment'), 1)
        self.assertEqual(RELEASE.count('needs.resolve-env.outputs.build_environment'), 2)
        resolver = job(RELEASE, 'resolve-env')

        def folded(key):
            # The output's folded value: the lines indented below its key.
            lines = resolver.split(f'      {key}: >-\n', 1)[1].split('\n')
            end = next(index for index, line in enumerate(lines) if not line.startswith('        '))
            return ' '.join(' '.join(lines[:end]).split())

        def evaluate(expression, environment_name, publish):
            # GitHub's && and || return an operand, as Python's and and or do.
            python = expression.removeprefix('${{ ').removesuffix(' }}') \
                .replace('steps.pick.outputs.environment', 'environment') \
                .replace('steps.pick.outputs.publish', 'publish').replace('&&', 'and').replace('||', 'or')
            return eval(python, {'__builtins__': {}}, {'environment': environment_name, 'publish': publish})

        # dev for a dev-branch release, staging for staging, and prod for a
        # production release, the validation build and anything unexpected.
        expression = folded('deployment')
        self.assertEqual(expression,
                         "${{ (steps.pick.outputs.environment == 'dev' && steps.pick.outputs.publish == 'true' && 'dev') || "
                         "(steps.pick.outputs.environment == 'staging' && 'staging') || 'prod' }}")
        table = {('dev', 'true'): 'dev', ('dev', 'false'): 'prod', ('staging', 'true'): 'staging',
                 ('staging', 'false'): 'staging', ('prod', 'true'): 'prod', ('prod', 'false'): 'prod',
                 ('', ''): 'prod', ('other', 'true'): 'prod', ('dev', ''): 'prod'}
        for (environment_name, publish), expected in table.items():
            with self.subTest(environment=environment_name, publish=publish):
                self.assertEqual(evaluate(expression, environment_name, publish), expected)
        # The build environment: prod-build only for a publishing production
        # lane; dev, staging, the validation build and anything unexpected as
        # their deployment environment.
        build_expression = folded('build_environment')
        table = {('dev', 'true'): 'dev', ('dev', 'false'): 'prod', ('staging', 'true'): 'staging',
                 ('staging', 'false'): 'staging', ('prod', 'true'): 'prod-build', ('prod', 'false'): 'prod',
                 ('', ''): 'prod', ('other', 'true'): 'prod', ('dev', ''): 'prod', ('prod', ''): 'prod'}
        for (environment_name, publish), expected in table.items():
            with self.subTest(build_environment=environment_name, publish=publish):
                self.assertEqual(evaluate(build_expression, environment_name, publish), expected)
        # The callers pass their secrets through and name no environment of a job.
        for caller in (CALLER, DEV_CALLER):
            self.assertNotRegex(caller, r'(?m)^    environment:')


if __name__ == '__main__':
    unittest.main()
