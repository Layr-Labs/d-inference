#!/usr/bin/env python3
"""Pin release safety/DAG boundaries without credentials, runners or downloads."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
RELEASE = (ROOT / '.github/workflows/release-swift.yml').read_text()
WARM = (ROOT / '.github/workflows/provider-release-cache.yml').read_text()
ACTION = (ROOT / '.github/actions/provider-release-build/action.yml').read_text()


def job(workflow, name):
    match = re.search(r'^  ' + re.escape(name) + r':\n(.*?)(?=^  [a-zA-Z0-9_-]+:|\Z)',
                      workflow.split('\njobs:\n', 1)[1], re.M | re.S)
    if match is None:
        raise AssertionError('Missing job: ' + name)
    return match.group(1)


def needs_of(content):
    """Return the raw `needs:` block of a job, single-line list or YAML `- item` form."""
    match = re.search(r'(?m)^    needs:(?:[ \t]*\[[^\]]*\]|(?:\n      -[^\n]*)+)', content)
    if match is None:
        raise AssertionError('Missing needs: block')
    return match.group(0)


class ReleasePipelineTests(unittest.TestCase):
    maxDiff = 1000
    def test_parallel_lanes_use_sdk27_without_signing_secrets(self):
        for name, lane in [('build-provider', 'release'), ('qualify-sdk', 'qualification')]:
            content = job(RELEASE, name)
            self.assertRegex(content, r'(?m)^    needs: resolve-env$')
            self.assertIn('runs-on: xcode-27-xlarge', content)
            self.assertIn('lane: ' + lane, content)
            self.assertIn('contents: read', content)
            self.assertNotIn('secrets.', content)
            self.assertNotRegex(content, r'(?m)^    environment:')

    def test_publication_requires_both_lanes_and_production_approval(self):
        content = job(RELEASE, 'build-and-release')
        self.assertIn('needs: [resolve-env, build-provider, qualify-sdk]', content)
        self.assertIn('environment: ${{ needs.resolve-env.outputs.environment }}', content)
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
        publish_needs = needs_of(publish)
        for dependency in ['resolve-env', 'build-and-release', 'stage-release']:
            self.assertIn(dependency, publish_needs)
        for content in [stage, publish]:
            self.assertIn('environment: ${{ needs.resolve-env.outputs.environment }}', content)
            self.assertIn('needs.build-and-release.outputs.publication_artifact', content)
            self.assertIn('gh run download "$SOURCE_RUN_ID"', content)
            self.assertIn('needs.resolve-env.outputs.source_run_id', content)
            self.assertNotIn('GITHUB_RUN_ATTEMPT', content)
            self.assertNotIn('notarytool', content)
            self.assertNotIn('APPLE_', content)
            self.assertNotIn('provider-release-build', content)
            self.assertIn("if: needs.resolve-env.outputs.publish == 'true'", content)
            self.assertNotRegex(content, r'(?m)^    if:.*always')
        self.assertIn('cancel-in-progress: false', publish)

    def test_artifact_handoff_is_same_run_and_source_bound(self):
        build = job(RELEASE, 'build-provider');sign = job(RELEASE, 'build-and-release')
        self.assertIn('provider-signing-validation.py stage', build)
        self.assertIn('unsigned-provider-${GITHUB_SHA}-${GITHUB_RUN_ATTEMPT}', build)
        self.assertIn('gh run download "$GITHUB_RUN_ID"', sign)
        self.assertIn('EXPECTED_SOURCE: ${{ github.sha }}', sign)
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
        for name in ['Verify production prompt parity', 'Test provider with release SDK',
                     'Build optimized provider products', 'Build or validate source-matched metallib']:
            step = ACTION.split('- name: ' + name + '\n', 1)[1].split('\n    - name:', 1)[0]
            self.assertNotIn('cache-hit', step)
        self.assertIn('-- ../scripts/run-provider-tests.sh', ACTION)
        self.assertIn('steps.test-build.outcome == \'success\'', ACTION)
        self.assertIn('snapshot-mtimes', ACTION)
        self.assertIn('steps.keys.outputs.swift-prefix', ACTION)
        self.assertNotIn('spm-v3-', ACTION)

    def test_independent_cache_generations_cannot_reuse_stale_rust_outputs(self):
        step = ACTION.split('- name: Invalidate workspace Rust outputs\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn("if: inputs.lane == 'qualification'", step)
        self.assertNotIn('cache-hit', step)
        self.assertIn('cargo +1.88.0 clean --manifest-path coordinator/promptsidecar/Cargo.toml -p promptsidecar', step)
        self.assertLess(ACTION.index('- name: Invalidate workspace Rust outputs'),
                        ACTION.index('- name: Verify production prompt parity'))

    def test_warming_cannot_publish_or_seed_default_branch_from_pr(self):
        self.assertIn('branches: [master]', WARM)
        self.assertIn("github.event_name == 'pull_request' || github.ref == 'refs/heads/master'", WARM)
        self.assertIn('lane: [release, qualification]', WARM)
        self.assertIn('max-parallel: 2', WARM)
        self.assertIn('runs-on: xcode-27-xlarge', WARM)
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

    def test_qwen_resource_regression_runs_without_a_cache_hit_bypass(self):
        step = ACTION.split('- name: Test Qwen resources in a relocated app\n', 1)[1].split('\n    - name:', 1)[0]
        self.assertIn('python3 scripts/test-qwen4-packaged-resources.py', step)
        self.assertNotIn('if:', step)

    # -- #1177 C5: qualification gate before registration (W1-W5) --------------

    def test_publish_awaits_independent_qualification_before_registering(self):
        """W1: await runs before registration, the job timeout covers the wait
        window, and publish-release cannot proceed without both macOS lanes."""
        content = job(RELEASE, 'publish-release')
        self.assertIn('Await independent build qualification', content)
        self.assertIn('provider-release-publication.py await', content)
        self.assertIn('Register release with coordinator and publish aliases', content)
        self.assertLess(
            content.index('Await independent build qualification'),
            content.index('Register release with coordinator and publish aliases'),
            'qualification must be awaited before registration')
        timeout = re.search(r'(?m)^    timeout-minutes:\s*(\d+)\s*$', content)
        self.assertIsNotNone(timeout, 'publish-release must declare a job timeout-minutes')
        self.assertGreaterEqual(
            int(timeout.group(1)), 75,
            'timeout-minutes must cover the default 60-minute wait window plus 15')
        needs = needs_of(content)
        self.assertIn('validate-older-macos', needs)
        self.assertIn('validate-macos-27', needs)

    def test_stage_release_writes_pending_summary_and_holds_no_release_key(self):
        """W2: stage writes the pending-qualification summary after staging and
        never handles a release key (only publish-release approves/registers)."""
        content = job(RELEASE, 'stage-release')
        self.assertIn('provider-release-publication.py stage', content)
        self.assertIn('provider-release-publication.py summary', content)
        self.assertLess(
            content.index('provider-release-publication.py stage'),
            content.index('provider-release-publication.py summary'),
            'summary must run after stage')
        self.assertNotIn('RELEASE_KEY', content)

    def test_validation_lanes_qualify_the_retained_publication_artifact(self):
        """W3: both macOS lanes validate the retained publication artifact on
        publish runs (not a re-signed validation artifact), each uploading its
        own result JSON, neither touching signing secrets."""
        older = job(RELEASE, 'validate-older-macos')
        macos27 = job(RELEASE, 'validate-macos-27')
        self.assertIn('runs-on: xcode-27', macos27)
        cases = [
            ('older-macos', older, 'qualification-result-older-macos.json'),
            ('macos-27', macos27, 'qualification-result-macos-27.json'),
        ]
        for lane, content, result_file in cases:
            self.assertIn('scripts/provider-release-qualify.py', content)
            self.assertIn('--lane ' + lane, content)
            self.assertIn('--level static,smoke', content)
            self.assertIn(result_file, content)
            self.assertIn(
                'provider-qualification-' + lane + '-', content,
                'uploaded artifact must be named provider-qualification-<lane>-<source_sha>-<run_attempt>')
            self.assertIn(
                'publication_artifact', content,
                'must download the retained publication artifact, not a re-signed one')
            self.assertIn(
                'SOURCE_RUN_ID', content,
                'download must target the source run id, not always this run')
            for secret in ['APPLE_CERTIFICATE_P12', 'APPLE_APP_PASSWORD', 'PROVISIONING_PROFILE']:
                self.assertNotIn(secret, content, lane + ' lane must not touch signing secrets')
        self.assertNotRegex(
            older, r"(?m)^    if: needs\.resolve-env\.outputs\.publish == 'false'\s*$",
            'validate-older-macos must also run against publish runs, not only validation-only runs')

    def test_resume_run_skips_build_jobs_and_binds_to_the_source_run(self):
        """W4: workflow_dispatch exposes resume_run_id, resolve-env resolves the
        source run via resume-source, build/sign jobs are skipped on resume, and
        downstream jobs pull from the source run id rather than this run."""
        self.assertIn('resume_run_id', RELEASE)
        resolve = job(RELEASE, 'resolve-env')
        self.assertIn('inputs.resume_run_id', resolve)
        self.assertIn('provider-release-publication.py resume-source', resolve)
        for output in ['resume', 'source_run_id', 'source_sha', 'publication_artifact']:
            self.assertRegex(
                resolve, r'(?m)^      ' + re.escape(output) + r':',
                'resolve-env must expose output ' + output)
        for name in ['build-provider', 'qualify-sdk', 'build-and-release']:
            content = job(RELEASE, name)
            if_line = re.search(r'(?m)^    if:.*$', content)
            self.assertIsNotNone(if_line, name + ' needs a job-level if to skip on resume runs')
            self.assertIn('resume', if_line.group(0))
            self.assertTrue(
                "!= 'true'" in if_line.group(0) or "== 'false'" in if_line.group(0),
                name + " if must exclude resume runs, got: " + if_line.group(0))
        for name in ['stage-release', 'publish-release']:
            content = job(RELEASE, name)
            self.assertIn('SOURCE_RUN_ID', content)
            self.assertIn('SOURCE_SHA', content)
            self.assertNotRegex(
                content, r'gh run download "\$GITHUB_RUN_ID"',
                name + ' must download from the resolved source run, not always this run')

    def test_verify_release_runs_after_publish(self):
        """W5: a verify-release job exists, needs publish-release, and proves
        every public surface via the verify operation."""
        content = job(RELEASE, 'verify-release')
        needs = needs_of(content)
        self.assertIn('publish-release', needs)
        self.assertIn('provider-release-publication.py verify', content)
        self.assertIn('SOURCE_RUN_ID', content)

    def test_only_signing_job_touches_apple_secrets(self):
        """No job other than build-and-release references the Apple signing
        secrets, including the two new C5 jobs."""
        all_jobs = [
            'resolve-env', 'build-provider', 'qualify-sdk', 'build-and-release',
            'stage-release', 'publish-release', 'validate-older-macos',
            'validate-macos-27', 'verify-release',
        ]
        forbidden = ['APPLE_CERTIFICATE_P12', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_APP_PASSWORD']
        for name in all_jobs:
            if name == 'build-and-release':
                continue
            content = job(RELEASE, name)
            for secret in forbidden:
                self.assertNotIn(secret, content, name + ' must not reference ' + secret)


if __name__ == '__main__':
    unittest.main()
