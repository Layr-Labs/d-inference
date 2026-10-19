#!/usr/bin/env python3
"""Pin release safety/DAG boundaries without credentials, runners or downloads."""
from fnmatch import fnmatchcase
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
# release-swift.yml is the thin caller that owns the triggers and routes each one
# to one or more environment lanes; release-provider.yml is the reusable workflow
# that holds the resolve -> build -> sign -> stage -> publish job chain.
CALLER = (ROOT / '.github/workflows/release-swift.yml').read_text()
RELEASE = (ROOT / '.github/workflows/release-provider.yml').read_text()
WARM = (ROOT / '.github/workflows/provider-release-cache.yml').read_text()
ACTION = (ROOT / '.github/actions/provider-release-build/action.yml').read_text()


def job(workflow, name):
    match = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [a-zA-Z0-9_-]+:|\Z)',
                      workflow.split('\njobs:\n', 1)[1], re.M | re.S)
    if match is None:
        raise AssertionError('Missing job: ' + name)
    return match.group(1)


class ReleasePipelineTests(unittest.TestCase):
    maxDiff = 1000
    def test_master_push_publishes_dev_and_tags_still_publish_production(self):
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
                    'scripts/provider_release_github.py', 'scripts/provider_release_cache/mtimes.py',
                    'scripts/stage-swiftpm-resource-bundles.sh'}
        for script in sorted(scripts):
            with self.subTest(script=script):
                self.assertTrue(any(fnmatchcase(script, pattern) for pattern in paths), script)
        self.assertNotIn('branches-ignore', trigger)
        self.assertNotIn('pull_request', trigger)

    def test_caller_routes_each_trigger_to_the_right_environment_lanes(self):
        # A master push runs dev and staging; a tag runs prod; dispatch runs the
        # chosen environment. Every lane calls the reusable workflow and inherits
        # the credentials it needs.
        lanes = {
            'dev': CALLER.split('\n  dev:\n', 1)[1].split('\n  staging:\n', 1)[0],
            'staging': CALLER.split('\n  staging:\n', 1)[1].split('\n  prod:\n', 1)[0],
            'prod': CALLER.split('\n  prod:\n', 1)[1],
        }
        push_branch = "(github.event_name == 'push' && github.ref_type == 'branch')"
        for name in ('dev', 'staging'):
            with self.subTest(lane=name):
                self.assertIn(push_branch, lanes[name])
                self.assertIn("(github.event_name == 'workflow_dispatch' && inputs.environment == '%s')" % name,
                              lanes[name])
                self.assertIn('uses: ./.github/workflows/release-provider.yml', lanes[name])
                self.assertIn('environment: ' + name, lanes[name])
                self.assertIn('secrets: inherit', lanes[name])
        # prod never runs on a branch push: it is tag-gated (or a recovery dispatch).
        self.assertIn("github.ref_type == 'tag'", lanes['prod'])
        self.assertIn("(github.event_name == 'workflow_dispatch' && inputs.environment == 'prod')",
                      lanes['prod'])
        self.assertNotIn(push_branch, lanes['prod'])
        self.assertIn('environment: prod', lanes['prod'])
        self.assertIn('secrets: inherit', lanes['prod'])
        # The caller holds no secrets, run steps or job chain of its own: it only
        # routes triggers to lanes. Every lane calls the one reusable workflow.
        self.assertNotIn('secrets.', CALLER)
        self.assertNotRegex(CALLER, r'(?m)^\s+run:')
        self.assertNotRegex(CALLER, r'(?m)^\s+steps:')
        for job in ('resolve-env:', 'build-and-release:', 'stage-release:', 'publish-release:'):
            self.assertNotIn('\n  ' + job, CALLER)
        self.assertEqual(CALLER.count('uses: ./.github/workflows/release-provider.yml'), 3)

    def test_staging_lane_is_gated_off_until_the_infra_var_is_set(self):
        # A master push builds and publishes dev unconditionally; staging only
        # when the STAGING_ENABLED repo variable is 'true' (set once the staging
        # stack and STAGING_* secrets exist), so a push never burns a second
        # build that would hard-fail at staging publication for want of secrets.
        dev = CALLER.split('\n  dev:\n', 1)[1].split('\n  staging:\n', 1)[0]
        staging = CALLER.split('\n  staging:\n', 1)[1].split('\n  prod:\n', 1)[0]
        prod = CALLER.split('\n  prod:\n', 1)[1]
        staging_if = staging.split('    if:', 1)[1].split('    concurrency:', 1)[0]
        self.assertIn("vars.STAGING_ENABLED == 'true'", staging_if)
        # The gate ANDs with the trigger routing, so disabling it drops staging
        # entirely while dev still matches the push.
        self.assertIn("(github.event_name == 'push' && github.ref_type == 'branch')", staging_if)
        self.assertNotIn("vars.STAGING_ENABLED", dev)
        self.assertNotIn("vars.STAGING_ENABLED", prod)
        self.assertEqual(CALLER.count("vars.STAGING_ENABLED"), 1)

    def test_reusable_workflow_takes_the_environment_as_a_called_input(self):
        header = RELEASE.split('\njobs:\n', 1)[0]
        self.assertIn('\non:\n  workflow_call:\n', header)
        inputs = header.split('    inputs:\n', 1)[1]
        self.assertIn('      environment:\n', inputs)
        self.assertRegex(inputs, r'environment:\n(?:.*\n)*?        required: true')
        # The reusable workflow carries no triggers of its own.
        self.assertNotIn('  push:', header)
        self.assertNotIn('workflow_dispatch:', header)

    def test_dev_and_staging_publication_are_serialized_and_never_cancelled(self):
        # Serialization moved from a single workflow-level group to one group per
        # caller lane, so dev and staging run in parallel in one master-push run
        # while each environment still publishes one at a time across runs.
        dev = CALLER.split('\n  dev:\n', 1)[1].split('\n  staging:\n', 1)[0]
        staging = CALLER.split('\n  staging:\n', 1)[1].split('\n  prod:\n', 1)[0]
        prod = CALLER.split('\n  prod:\n', 1)[1]
        dev_group = dev.split('    concurrency:\n', 1)[1].split('    uses:', 1)[0]
        self.assertIn("(github.event_name == 'workflow_dispatch' && inputs.validation_only)", dev_group)
        self.assertIn("|| 'release-dev'", dev_group)
        self.assertIn('cancel-in-progress: false', dev_group)
        self.assertIn('group: release-staging', staging)
        self.assertIn('cancel-in-progress: false',
                      staging.split('    concurrency:\n', 1)[1].split('    uses:', 1)[0])
        # prod keeps a unique per-run group, as before; it never joins release-dev.
        self.assertIn("group: ${{ format('release-swift-{0}', github.run_id) }}", prod)
        self.assertNotIn('release-dev', prod)
        self.assertIn("format('dev + staging provider release (master push -dev.{0}/-staging.{0})', github.run_number)",
                      CALLER)

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
        self.assertNotIn('version:', job(RELEASE, 'qualify-sdk').split('lane: qualification', 1)[1])
        stamp = ACTION.split('- name: Stamp dev release version\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertLess(ACTION.index('- name: Verify checked-out source'), ACTION.index('- name: Stamp dev release version'))
        self.assertLess(ACTION.index('- name: Stamp dev release version'), ACTION.index('- name: Build optimized provider products'))
        self.assertIn("if: inputs.lane == 'release' && inputs.version != ''", stamp)
        self.assertEqual(stamp.count('./scripts/check-release-version.sh "$VERSION"'), 2)
        self.assertIn('test "$(git diff --name-only)" = "$SOURCE"', stamp)
        self.assertNotIn('version:', WARM.split('uses: ./.github/actions/provider-release-build', 1)[1].split('\n      - ', 1)[0])

    def test_parallel_lanes_use_sdk27_without_signing_secrets(self):
        for name, lane in [('build-provider', 'release'), ('qualify-sdk', 'qualification')]:
            content = job(RELEASE, name)
            self.assertRegex(content, r'(?m)^    needs: resolve-env$')
            self.assertIn('runs-on: blacksmith-12vcpu-macos-27', content)
            self.assertIn('lane: ' + lane, content)
            self.assertIn('contents: read', content)
            self.assertNotIn('secrets.', content)
            self.assertNotRegex(content, r'(?m)^    environment:')

    def test_only_the_release_lane_compiles_the_release_environment(self):
        selector = 'DARKBLOOM_RELEASE_ENVIRONMENT: ${{ needs.resolve-env.outputs.environment }}'
        self.assertIn(selector, job(RELEASE, 'build-provider'))
        self.assertNotIn('DARKBLOOM_RELEASE_ENVIRONMENT', job(RELEASE, 'qualify-sdk'))
        signing = job(RELEASE, 'build-and-release')
        for output in ['PRE_SIGN_SMOKE_OUTPUT', 'FINAL_SMOKE_OUTPUT']:
            self.assertIn(f'printf \'%s\\n\' "${output}" \\\n'
                          '            | grep -Eq "^build-environment-runtime-smoke: ${ENV_PREFIX} cli=${CLI_NAME} "', signing)
        # The packaged names follow the version; the compiled names must agree.
        resolve = 'python3 scripts/provider_release_identity.py "$VERSION" >> "$GITHUB_ENV"'
        for name in ['build-and-release', 'validate-older-macos']:
            self.assertIn(resolve, job(RELEASE, name))

    def test_signing_requires_both_sdk_lanes_without_environment_approval(self):
        content = job(RELEASE, 'build-and-release')
        self.assertIn('needs: [resolve-env, build-provider, qualify-sdk]', content)
        self.assertNotRegex(content, r'(?m)^    environment:')
        self.assertNotRegex(content, r'(?m)^    if:.*always')
        self.assertNotIn('continue-on-error:', RELEASE)
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
            self.assertNotRegex(content, r'(?m)^    environment:')
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
        for name in ['build-provider', 'qualify-sdk', 'build-and-release',
                     'stage-release', 'publish-release', 'validate-older-macos']:
            content = job(RELEASE, name)
            self.assertIn('ref: ${{ needs.resolve-env.outputs.workflow_sha }}', content)
            self.assertIn('resolve-env', content.split('steps:', 1)[0])
            self.assertNotRegex(content, r'(?m)^    environment:')

    def test_no_separate_hardware_or_receipt_authority(self):
        for forbidden in ['qualify-release:', 'validate-signed-macos26:', 'validate-signed-macos27:',
                          'PLATFORM_QUALIFICATION', 'RELEASE_QUALIFICATION',
                          'provider-release-qualification', '/v1/releases/qualify', '/v1/admin/app-attest/builds']:
            self.assertNotIn(forbidden, RELEASE)

    def test_artifact_handoff_is_same_run_and_source_bound(self):
        build = job(RELEASE, 'build-provider');sign = job(RELEASE, 'build-and-release')
        self.assertIn('provider-signing-validation.py stage', build)
        self.assertIn('unsigned-provider-${GITHUB_SHA}-${GITHUB_RUN_ATTEMPT}', build)
        self.assertIn('gh run download "$GITHUB_RUN_ID"', sign)
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
                        signing.index('Stage and sign bundle'))

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
        self.assertIn('branches: [master]', WARM)
        self.assertIn("github.event_name == 'pull_request' || github.ref == 'refs/heads/master'", WARM)
        self.assertIn('lane: [release, qualification]', WARM)
        self.assertIn('max-parallel: 2', WARM)
        self.assertIn('runs-on: blacksmith-12vcpu-macos-27', WARM)
        self.assertNotRegex(WARM, r'(?m)^  (pull_request_target|workflow_run):')
        for text in [WARM, ACTION]:
            for forbidden in ['secrets.', 'contents: write', 'gh release create', 'aws s3', 'notarytool']:
                self.assertNotIn(forbidden, text)
        self.assertIn('uses: ./.github/actions/provider-release-build', WARM)
        self.assertIn('provider-signing-validation.py stage', WARM)
        self.assertIn('provider-signing-validation.py unpack', WARM)

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
        # branch: all sign with the Developer ID. Only the separate
        # release-dev-branch.yml lane ad-hoc self-signs; this lane never does.
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
        self.assertIn('Branch pushes publish dev or staging only', resolver)
        sign = job(RELEASE, 'build-and-release')
        self.assertIn("needs.resolve-env.result == 'success'", sign)

    def test_dev_and_staging_artifacts_avoid_collision_but_prod_stays_unqualified(self):
        # dev and staging share one GitHub run id on a master push, so their
        # unsigned and publication artifact names carry the environment; prod
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
        self.assertIn('environment: ${{ needs.resolve-env.outputs.environment }}', job(RELEASE, 'qualify-sdk'))
        # Release lanes add an -<environment>- infix; a caller passing no
        # environment (the warm lane) keeps the historical name with no empty
        # double dash.
        self.assertIn("provider-sdk-test-diagnostics${{ inputs.environment != '' && format('-{0}', inputs.environment) || '' }}-", ACTION)
        self.assertNotIn('provider-sdk-test-diagnostics--', ACTION)
        self.assertNotRegex(WARM, r'(?m)^\s+environment:')


if __name__ == '__main__':
    unittest.main()
