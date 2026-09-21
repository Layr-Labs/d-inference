#!/usr/bin/env python3
"""Mutation tests for regressions that would expose credentials on Tenki."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('policy', Path(__file__).with_name('check-ci-runner-policy.py'))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class RunnerPolicyTests(unittest.TestCase):
    def setUp(self):
        self.workflow = {'permissions': {'contents': 'read'}, 'jobs': {'test': {
            'runs-on': 'tenki-standard-medium-4c-8g', 'steps': [
                {'uses': 'actions/checkout@pinned', 'with': {'persist-credentials': 'false'}}]}}}
        self.job = self.workflow['jobs']['test']

    def errors(self, filename='fixture.yml', root=policy.ROOT):
        return policy.check({filename: self.workflow}, root)

    def test_read_only_job_passes(self):
        self.assertEqual(self.errors(), [])

    def test_repository_workflows_pass(self):
        workflows = {p.name: policy.load(p) for p in (policy.ROOT / '.github/workflows').glob('*.yml')}
        self.assertEqual(policy.check(workflows), [])

    def test_inherited_and_job_write_tokens_are_rejected(self):
        for permissions in [None, 'write-all', {'contents': 'write'}, {'id-token': 'write'}]:
            with self.subTest(permissions=permissions):
                self.workflow['permissions'] = permissions
                self.assertTrue(self.errors())
                self.job['permissions'] = {'contents': 'read'}
                self.assertEqual(self.errors(), [])
                del self.job['permissions']

    def test_workflow_env_and_step_secret_references_are_rejected(self):
        for expression in ['${{ secrets.KEY }}', "${{ secrets['KEY'] }}", '${{ toJSON(secrets) }}']:
            with self.subTest(expression=expression):
                self.workflow['env'] = {'KEY': expression}
                self.assertTrue(self.errors())
                del self.workflow['env']
                self.job['steps'].append({'env': {'KEY': expression}, 'run': 'true'})
                self.assertTrue(self.errors())
                self.job['steps'].pop()

    def test_environment_and_inherited_secrets_are_rejected(self):
        for key, value in [('environment', 'prod'), ('secrets', 'inherit')]:
            self.job[key] = value
            self.assertTrue(self.errors())
            del self.job[key]

    def test_checkout_cannot_keep_credentials(self):
        del self.job['steps'][0]['with']['persist-credentials']
        self.assertTrue(self.errors())

    def test_dynamic_and_unapproved_runners_are_rejected(self):
        for runner in ['${{ inputs.runner }}', ['self-hosted'], 'blacksmith-4vcpu-ubuntu-2404']:
            self.job['runs-on'] = runner
            self.assertTrue(self.errors())

    def test_privileged_job_cannot_move_to_tenki_even_without_secret_expression(self):
        self.workflow['jobs'] = {'register': self.job}
        self.assertTrue(self.errors('register-model.yml'))
        self.job['runs-on'] = 'ubuntu-24.04'
        self.assertEqual(self.errors('register-model.yml'), [])

    def test_secrets_in_local_composite_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            action = root / '.github/actions/test'
            action.mkdir(parents=True)
            (action / 'action.yml').write_text('runs:\n  using: composite\n  steps:\n    - run: echo hi\n      env:\n        KEY: "${{ secrets.KEY }}"\n')
            self.job['steps'] = [{'uses': './.github/actions/test'}]
            self.assertTrue(self.errors(root=root))

    def test_mac_requires_explicit_xcode(self):
        self.job['runs-on'] = 'tenki-macos-26-large'
        self.assertTrue(self.errors())
        self.job['env'] = {'DEVELOPER_DIR': '/Applications/Xcode_27.0.app/Contents/Developer'}
        self.assertEqual(self.errors(), [])


if __name__ == '__main__':
    unittest.main()
