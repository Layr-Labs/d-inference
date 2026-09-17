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


class ReleasePipelineTests(unittest.TestCase):
    maxDiff = 1000
    def test_parallel_lanes_use_sdk27_without_signing_secrets(self):
        for name, lane in [('build-provider', 'release'), ('qualify-sdk', 'qualification')]:
            content = job(RELEASE, name)
            self.assertRegex(content, r'(?m)^    needs: resolve-env$')
            self.assertIn('runs-on: xcode-27', content)
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
        self.assertNotRegex(WARM, r'(?m)^  (pull_request_target|workflow_run):')
        for text in [WARM, ACTION]:
            for forbidden in ['secrets.', 'contents: write', 'gh release create', 'aws s3', 'notarytool']:
                self.assertNotIn(forbidden, text)
        self.assertIn('uses: ./.github/actions/provider-release-build', WARM)
        self.assertIn('provider-signing-validation.py stage', WARM)
        self.assertIn('provider-signing-validation.py unpack', WARM)

    def test_signing_and_runtime_qualification_are_retained(self):
        for expected in ['app-attest-callback-runtime-smoke: ok',
                         'gemma-optimizations-runtime-smoke: ok',
                         'codesign --verify --deep --strict', 'xcrun notarytool submit',
                         'BINARY_HASH=$(shasum -a 256',
                         'Register release with coordinator']:
            self.assertIn(expected, RELEASE)


if __name__ == '__main__':
    unittest.main()
