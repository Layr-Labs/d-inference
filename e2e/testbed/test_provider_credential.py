"""CPU-only credential-retirement ordering, using synthetic host observations."""
from pathlib import Path
import json
import tempfile
import unittest
from unittest.mock import patch
import provider_host as host


class CredentialRetirement(unittest.TestCase):
    def fixture(self, root, group=True):
        token=root/'auth_token';token.write_bytes(b'private-fixture-token');token.chmod(0o600)
        record={'pid':123,'provider_started':True,'group_cleanup_complete':group,'failure':None,'exit_code':-15,'stop_requested':True}
        observation={'unexpected_processes':[],'owned_processes':[],'gpu_temperature_c':30,'load1':1}
        return token,record,observation

    def test_foreign_process_failure_does_not_retain_owned_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);token,record,observation=self.fixture(root);observation['unexpected_processes']=[14340];events=[]
            with patch.object(host,'digest',return_value='bound'),patch.object(host,'observe',return_value=observation):
                with self.assertRaisesRegex(ValueError,'process leftovers'):
                    host.finish_owner({'target':{'canonical_config_sha256':'bound'}},{'root':root},record,events.append)
            self.assertFalse(token.exists());self.assertTrue(events[0]['auth_token_retired'])
            self.assertEqual(events[0]['observation']['unexpected_processes'],[14340])
            self.assertTrue(json.loads((root/'credential-retirement.json').read_text())['auth_token_retired'])

    def test_observation_failure_still_leaves_separate_retirement_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);token,record,_=self.fixture(root)
            with patch.object(host,'digest',return_value='bound'),patch.object(host,'observe',side_effect=TimeoutError('telemetry unavailable')):
                with self.assertRaises(TimeoutError):host.finish_owner({'target':{'canonical_config_sha256':'bound'}},{'root':root},record)
            self.assertFalse(token.exists());self.assertTrue(json.loads((root/'credential-retirement.json').read_text())['auth_token_retired'])

    def test_unconfirmed_own_group_keeps_credential_and_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);token,record,observation=self.fixture(root,False);events=[]
            with patch.object(host,'digest',return_value='bound'),patch.object(host,'observe',return_value=observation):
                with self.assertRaisesRegex(RuntimeError,'group retirement is unconfirmed'):
                    host.finish_owner({'target':{'canonical_config_sha256':'bound'}},{'root':root},record,events.append)
            self.assertTrue(token.exists());self.assertFalse(events[0]['auth_token_retired'])

    def test_symlink_is_not_followed_or_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);token,record,_=self.fixture(root);outside=root/'other';outside.write_bytes(b'other');token.unlink();token.symlink_to(outside)
            result=host.retire_owned_credential(root,record)
            self.assertFalse(result['auth_token_retired']);self.assertTrue(token.is_symlink());self.assertEqual(outside.read_bytes(),b'other')

    def test_prelaunch_without_root_has_no_credential_to_retain(self):
        result=host.retire_owned_credential(None,{'group_cleanup_complete':True,'pid':None})
        self.assertTrue(result['auth_token_retired'])

if __name__=='__main__':unittest.main()
