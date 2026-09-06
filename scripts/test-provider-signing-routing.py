#!/usr/bin/env python3
"""CPU-only parsed workflow preservation, routing and mutation tests."""
import copy
import unittest

from provider_signing_workflow_graph import (
    ROOT, CALL_JOB, CALL_PATH, SIGNING_SECRETS, load_contract, validate,
    expanded_ci_graph, preserved_files,
)


class SigningWorkflowRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ci, cls.signing, cls.baseline = load_contract()

    def test_all_eight_normal_jobs_keep_every_definition_and_existing_condition(self):
        validate(self.ci, self.signing, self.baseline)
        self.assertEqual(len(self.baseline["ci"]["jobs"]), 8)
        preserved_files(ROOT, self.baseline)

    def test_push_and_pr_keep_their_original_job_sets(self):
        original = set(self.baseline["ci"]["jobs"])
        self.assertEqual(set(expanded_ci_graph(self.ci, self.signing, self.baseline, "push")), original)
        self.assertEqual(set(expanded_ci_graph(self.ci, self.signing, self.baseline, "pull_request")),
                         original - {"cache-swift"})
        self.assertEqual(expanded_ci_graph(self.ci, self.signing, self.baseline, "workflow_run"), {})

    def test_manual_graph_is_only_unsigned_build_then_signer(self):
        graph = expanded_ci_graph(self.ci, self.signing, self.baseline, "workflow_dispatch")
        self.assertEqual(set(graph), {CALL_JOB + "/build", CALL_JOB + "/signing"})
        self.assertNotIn("needs", graph[CALL_JOB + "/build"])
        self.assertEqual(graph[CALL_JOB + "/signing"]["needs"], [CALL_JOB + "/build"])
        self.assertEqual(self.ci["jobs"][CALL_JOB]["uses"], CALL_PATH)
        self.assertNotIn("@", CALL_PATH)
        self.assertTrue(all("environment" not in node for node in graph.values()))

    def test_reusable_contract_and_standalone_manual_inputs_match_exactly(self):
        call = self.signing["on"]["workflow_call"]
        self.assertEqual(call["inputs"], self.signing["on"]["workflow_dispatch"]["inputs"])
        self.assertEqual(set(call["inputs"]), {"source_sha", "version"})
        self.assertTrue(all(v == {"required": True} for v in call["secrets"].values()))
        self.assertEqual(set(call["secrets"]), set(SIGNING_SECRETS))
        self.assertEqual(self.ci["jobs"][CALL_JOB]["permissions"], {"contents": "read", "actions": "read"})

    def test_guard_removal_or_runner_command_drift_is_rejected(self):
        for change in ("guard", "runner", "provider-isolation", "cache-condition", "extra-job"):
            ci = copy.deepcopy(self.ci)
            if change == "guard": del ci["jobs"]["test-provider"]["if"]
            elif change == "runner": ci["jobs"]["test-provider"]["runs-on"] = "self-hosted"
            elif change == "provider-isolation":
                step = next(s for s in ci["jobs"]["test-provider"]["steps"] if "run-provider-tests.sh" in s.get("run", ""))
                step["run"] = "swift test"
            elif change == "cache-condition": ci["jobs"]["cache-swift"]["if"] = ci["jobs"]["docs"]["if"]
            else: ci["jobs"]["extra-model"] = {"runs-on": "self-hosted", "steps": []}
            with self.subTest(change=change), self.assertRaises(ValueError): validate(ci, self.signing, self.baseline)

    def test_inherit_all_extra_missing_or_wrong_secret_mapping_is_rejected(self):
        for change in ("inherit", "extra", "missing", "wrong"):
            ci = copy.deepcopy(self.ci)
            if change == "inherit": ci["jobs"][CALL_JOB]["secrets"] = "inherit"
            elif change == "extra": ci["jobs"][CALL_JOB]["secrets"]["DEV_RELEASE_KEY"] = "${{ secrets.DEV_RELEASE_KEY }}"
            elif change == "missing": del ci["jobs"][CALL_JOB]["secrets"][SIGNING_SECRETS[0]]
            else: ci["jobs"][CALL_JOB]["secrets"][SIGNING_SECRETS[0]] = "${{ secrets.DEV_RELEASE_KEY }}"
            with self.subTest(change=change), self.assertRaises(ValueError): validate(ci, self.signing, self.baseline)

    def test_wrong_ref_write_permission_or_environment_caller_is_rejected(self):
        for key, value in (("uses", CALL_PATH + "@master"), ("permissions", {"contents": "write"}),
                           ("environment", "dev"), ("if", "${{ always() }}")):
            ci = copy.deepcopy(self.ci); ci["jobs"][CALL_JOB][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): validate(ci, self.signing, self.baseline)

    def test_inputs_cannot_be_optional_defaulted_or_redirected(self):
        for change in ("optional", "default", "redirect", "selector"):
            ci = copy.deepcopy(self.ci)
            if change == "optional": ci["on"]["workflow_dispatch"]["inputs"]["source_sha"]["required"] = False
            elif change == "default": ci["on"]["workflow_dispatch"]["inputs"]["version"]["default"] = "0.9.0"
            elif change == "redirect": ci["jobs"][CALL_JOB]["with"]["source_sha"] = "${{ github.sha }}"
            else: ci["on"]["workflow_dispatch"]["inputs"]["environment"] = {"type": "string"}
            with self.subTest(change=change), self.assertRaises(ValueError): validate(ci, self.signing, self.baseline)

    def test_signing_jobs_cannot_gain_candidate_execution_or_lose_cleanup(self):
        for change in ("execute", "cleanup", "secret-in-build", "new-trigger", "extra-secret"):
            signing = copy.deepcopy(self.signing)
            if change == "execute": signing["jobs"]["signing"]["steps"].append({"run": "candidate/darkbloom --version"})
            elif change == "cleanup":
                step = next(s for s in signing["jobs"]["signing"]["steps"] if s.get("name") == "Remove temporary signing material")
                step["if"] = "success()"
            elif change == "secret-in-build": signing["jobs"]["build"]["env"] = {"KEY": "${{ secrets.APPLE_CERTIFICATE_P12 }}"}
            elif change == "new-trigger": signing["on"]["push"] = None
            else: signing["on"]["workflow_call"]["secrets"]["DEV_RELEASE_KEY"] = {"required": True}
            with self.subTest(change=change), self.assertRaises(ValueError): validate(self.ci, signing, self.baseline)


if __name__ == "__main__":
    unittest.main(verbosity=2)
