#!/usr/bin/env python3
"""Offline release recovery provenance, artifact and DAG regressions."""
import base64
import copy
import hashlib
import itertools
import os
from pathlib import Path
import re
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from provider_release_resume.identity import select, BUILD_JOB, QUALIFY_JOB, SIGN_JOB
from provider_release_resume.artifact import extract_transport
from provider_release_resume import main
from provider_release_resume.api import (tag_source, verify_desktop_source, verify_validation_source,
                                         verify_workflow_source)

ROOT = Path(__file__).resolve().parent.parent
SHA = "a" * 40


class FakeAPI:
    repository = "owner/repo"
    def __init__(self):
        self.run = {"repository":{"full_name":self.repository},"head_repository":{"full_name":self.repository},
                    "path":".github/workflows/release-swift.yml","event":"push","status":"completed",
                    "conclusion":"failure","run_attempt":1,"head_sha":SHA,"head_branch":"v0.9.13"}
        self.tag = {"verification":{"verified":True},"object":{"type":"commit","sha":SHA}}
        self.commit = {"commit":{"verification":{"verified":True}}}
        self.jobs = [{"name":name,"status":"completed","conclusion":"success"} for name in [BUILD_JOB,QUALIFY_JOB]]
        self.jobs.append({"name":SIGN_JOB,"status":"completed","conclusion":"failure"})
        self.artifacts = [{"id":10,"name":f"unsigned-provider-{SHA}-1","expired":False,"size_in_bytes":100,
                          "digest":"sha256:" + "b"*64,"workflow_run":{"id":123,"head_sha":SHA}}]
        self.provider_version = "0.9.13"
        self.provider_source = None
        self.content_requests = []
        self.comparison = {"status": "ahead", "merge_base_commit": {"sha": SHA}}
        self.dev_comparison = {"status": "ahead", "merge_base_commit": {"sha": SHA}}
    def get(self,path):
        if path == "actions/runs/123":return self.run
        if path == "git/ref/tags/v0.9.13":return {"object":{"type":"tag","sha":"c"*40}}
        if path == "git/tags/" + "c"*40:return self.tag
        if path == "commits/" + SHA:return self.commit
        if path == "commits/" + "d"*40:return self.commit
        if path == "commits/" + "f"*40:return self.commit
        if path == "git/ref/heads/master":return {"object":{"sha":"d"*40}}
        if path == f"compare/{SHA}..." + "d"*40:return self.comparison
        if path == "git/ref/heads/dev":return {"object":{"sha":"f"*40}}
        if path == f"compare/{SHA}..." + "f"*40:return self.dev_comparison
        if path == "compare/" + "f"*40 + "..." + "f"*40:
            return {"status":"identical","merge_base_commit":{"sha":"f"*40}}
        if path == "compare/" + "d"*40 + "..." + "d"*40:
            return {"status":"identical","merge_base_commit":{"sha":"d"*40}}
        if path.startswith("contents/"):
            self.content_requests.append(path)
            if path != f"contents/provider-swift/Sources/ProviderCore/ProviderCore.swift?ref={SHA}":
                raise AssertionError("Release recovery read a non-provider version source: " + path)
            source = self.provider_source if self.provider_source is not None else 'public static let version = "'+self.provider_version+'"'
            return {"content":base64.b64encode(source.encode()).decode()}
        raise AssertionError(path)
    def pages(self,path,key):
        if path == "actions/runs/123/attempts/1/jobs" and key == "jobs":return self.jobs
        if path == "actions/runs/123/artifacts" and key == "artifacts":return self.artifacts
        raise AssertionError(path)


class RecoveryTests(unittest.TestCase):
    def test_missing_or_malformed_source_response_is_rejected(self):
        for response in ({}, {"content": None}, {"content": "not-valid-base64!"}):
            with self.subTest(response=response):
                api = FakeAPI()
                get = api.get
                with patch.object(api, "get", side_effect=lambda path: response if path.startswith("contents/") else get(path)):
                    with self.assertRaises(ValueError):
                        select(api, "123", "1")

    def test_missing_malformed_or_ambiguous_provider_source_is_rejected(self):
        for source in ("", 'public static let version = "invalid"',
                       'public static let version = "0.9.13"\npublic static let version = "0.9.13"'):
            with self.subTest(source=source):
                api = FakeAPI()
                api.provider_source = source
                with self.assertRaises(ValueError):
                    select(api, "123", "1")

    def test_signed_tag_requires_verified_source_on_master_ancestry(self):
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "tag",
               "GITHUB_REF_NAME": "v0.9.13", "GITHUB_REF": "refs/tags/v0.9.13", "GITHUB_SHA": SHA}
        self.assertEqual(verify_workflow_source(FakeAPI(), env), SHA)
        for mutate in [lambda api: api.tag["verification"].update(verified=False),
                       lambda api: api.tag["object"].update(type="tag"),
                       lambda api: api.tag["object"].update(sha="e"*40),
                       lambda api: api.commit["commit"]["verification"].update(verified=False),
                       lambda api: api.comparison.update(status="diverged"),
                       lambda api: api.comparison.update(status="behind"),
                       lambda api: api.comparison["merge_base_commit"].update(sha="e"*40)]:
            api = FakeAPI()
            mutate(api)
            with self.assertRaises(ValueError):
                verify_workflow_source(api, env)
        api = FakeAPI()
        get = api.get
        with patch.object(api, 'get', side_effect=lambda path: {"object": {"type": "commit", "sha": SHA}}
                          if path.startswith('git/ref/tags/') else get(path)):
            with self.assertRaisesRegex(ValueError, 'signed annotated'):
                verify_workflow_source(api, env)

    def test_dev_validation_and_resume_source_must_be_current_reviewed_master(self):
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_TYPE": "branch",
               "GITHUB_REF_NAME": "master", "GITHUB_REF": "refs/heads/master", "GITHUB_SHA": "d"*40}
        self.assertEqual(verify_workflow_source(FakeAPI(), env), "d"*40)
        for key, value in [("GITHUB_REF", "refs/heads/candidate"), ("GITHUB_SHA", SHA),
                           ("GITHUB_REF", "refs/tags/v0.9.13"), ("GITHUB_EVENT_NAME", "pull_request"),
                           ("GITHUB_EVENT_NAME", "pull_request_target"), ("GITHUB_EVENT_NAME", "workflow_run")]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                verify_workflow_source(FakeAPI(), dict(env, **{key: value}))

    def test_master_push_source_must_be_verified_master_ancestry(self):
        # Master may advance before the job starts; ancestry is the boundary.
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "branch",
               "GITHUB_REF_NAME": "master", "GITHUB_REF": "refs/heads/master", "GITHUB_SHA": SHA}
        self.assertEqual(verify_workflow_source(FakeAPI(), env), SHA)
        for key, value in [("GITHUB_REF", "refs/heads/candidate"), ("GITHUB_REF", "refs/tags/v0.9.13"),
                           ("GITHUB_REF", ""), ("GITHUB_REF_TYPE", "")]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                verify_workflow_source(FakeAPI(), dict(env, **{key: value}))
        for mutate in [lambda api: api.commit["commit"]["verification"].update(verified=False),
                       lambda api: api.comparison.update(status="diverged"),
                       lambda api: api.comparison["merge_base_commit"].update(sha="e"*40)]:
            api = FakeAPI()
            mutate(api)
            with self.assertRaises(ValueError):
                verify_workflow_source(api, env)

    def test_dev_push_source_must_be_verified_dev_ancestry_for_dev_only(self):
        # master's gate admits a dev push for environment dev only. The commit
        # must be GitHub-verified and on dev ancestry; dev may advance first.
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "branch", "GITHUB_REF_NAME": "dev",
               "GITHUB_REF": "refs/heads/dev", "GITHUB_SHA": SHA, "RELEASE_ENVIRONMENT": "dev"}
        self.assertEqual(verify_workflow_source(FakeAPI(), env), SHA)
        # Prod or staging from a dev push, or no environment, is refused.
        for environment in ("prod", "staging", ""):
            with self.subTest(environment=environment), \
                    self.assertRaisesRegex(ValueError, "require environment dev"):
                verify_workflow_source(FakeAPI(), dict(env, RELEASE_ENVIRONMENT=environment))
        without = dict(env)
        del without["RELEASE_ENVIRONMENT"]
        with self.assertRaisesRegex(ValueError, "require environment dev"):
            verify_workflow_source(FakeAPI(), without)
        # An unverified commit, or one that dev does not contain, is refused.
        for mutate, message in [
                (lambda api: api.commit["commit"]["verification"].update(verified=False), "not verified"),
                (lambda api: api.dev_comparison.update(status="diverged"), "not on dev ancestry"),
                (lambda api: api.dev_comparison.update(status="behind"), "not on dev ancestry"),
                (lambda api: api.dev_comparison["merge_base_commit"].update(sha="e"*40), "not on dev ancestry")]:
            api = FakeAPI()
            mutate(api)
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                verify_workflow_source(api, env)
        # A dev-branch workflow_dispatch is admitted ONLY for environment dev
        # and ONLY at the current dev HEAD commit.
        dev_dispatch = dict(env, GITHUB_EVENT_NAME="workflow_dispatch")
        dev_dispatch_head = dict(dev_dispatch, GITHUB_SHA="f" * 40)
        self.assertEqual(verify_workflow_source(FakeAPI(), dev_dispatch_head), "f" * 40)
        with self.assertRaisesRegex(ValueError, "current dev commit"):
            verify_workflow_source(FakeAPI(), dev_dispatch)
        for environment in ("prod", "staging", ""):
            with self.subTest(dispatch_env=environment), \
                    self.assertRaisesRegex(ValueError, "require environment dev"):
                verify_workflow_source(FakeAPI(), dict(dev_dispatch_head, RELEASE_ENVIRONMENT=environment))
        # Dev from any other branch or trigger is refused: another branch push,
        # schedule directly calling release-provider, and a pull request.
        for key, value, message in [("GITHUB_REF", "refs/heads/candidate", "require master or dev"),
                                    ("GITHUB_REF", "refs/heads/devx", "require master or dev"),
                                    ("GITHUB_EVENT_NAME", "schedule", "trusted tag push"),
                                    ("GITHUB_EVENT_NAME", "pull_request", "trusted tag push")]:
            with self.subTest(key=key, value=value), self.assertRaisesRegex(ValueError, message):
                verify_workflow_source(FakeAPI(), dict(env, **{key: value}))
        # Dev ancestry never stands in for master ancestry on a master route.
        api = FakeAPI()
        api.comparison.update(status="diverged")
        master_push = dict(env, GITHUB_REF_NAME="master", GITHUB_REF="refs/heads/master")
        with self.assertRaisesRegex(ValueError, "not on reviewed master ancestry"):
            verify_workflow_source(api, master_push)

    def test_signing_validation_requires_master_tooling_and_a_master_source(self):
        master = "d" * 40
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/master", "GITHUB_SHA": master}
        # The current master and an earlier commit on its ancestry both pass.
        self.assertEqual(verify_validation_source(FakeAPI(), env, SHA), SHA)
        self.assertEqual(verify_validation_source(FakeAPI(), env, master), master)
        # Dispatched anywhere else, or started by another event, it stops
        # before any commit is looked up.
        for key, value in [("GITHUB_REF", "refs/heads/dev"), ("GITHUB_REF", "refs/heads/candidate"),
                           ("GITHUB_REF", "refs/tags/v0.9.13"), ("GITHUB_EVENT_NAME", "push"),
                           ("GITHUB_EVENT_NAME", "pull_request")]:
            api = FakeAPI()
            with self.subTest(key=key, value=value), patch.object(api, "get", side_effect=AssertionError("read")), \
                    self.assertRaisesRegex(ValueError, "dispatched on master"):
                verify_validation_source(api, dict(env, **{key: value}), SHA)
        # A verified commit that is not on master's ancestry is refused: a
        # branch commit, and one that master has diverged from.
        for status in ("diverged", "behind"):
            api = FakeAPI()
            api.comparison.update(status=status)
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "not on reviewed master ancestry"):
                verify_validation_source(api, env, SHA)
        api = FakeAPI()
        api.comparison.update(merge_base_commit={"sha": "e" * 40})
        with self.assertRaisesRegex(ValueError, "not on reviewed master ancestry"):
            verify_validation_source(api, env, SHA)
        # An unverified commit, and anything but a full SHA, are refused.
        api = FakeAPI()
        api.commit = {"commit": {"verification": {"verified": False}}}
        with self.assertRaisesRegex(ValueError, "not verified"):
            verify_validation_source(api, env, SHA)
        for source in ("master", SHA[:12], SHA.upper(), ""):
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, "Invalid release source commit"):
                verify_validation_source(FakeAPI(), env, source)

    def test_signing_validation_command_requires_a_source_and_writes_no_output(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            env = {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_OUTPUT": str(output),
                   "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/master", "GITHUB_SHA": "d" * 40}
            with patch.dict(os.environ, env, clear=True), patch("provider_release_resume.GitHub", return_value=FakeAPI()):
                with patch("sys.argv", ["resume", "verify-validation-source", "--source", SHA]):
                    main()
                with patch("sys.argv", ["resume", "verify-validation-source"]), self.assertRaises(SystemExit):
                    main()
                with patch.dict(os.environ, {"GITHUB_REF": "refs/heads/candidate"}), \
                        patch("sys.argv", ["resume", "verify-validation-source", "--source", SHA]), \
                        self.assertRaises(ValueError):
                    main()
            self.assertFalse(output.exists())

    def desktop_api(self, tag="desktop-v0.2.0", lightweight=False):
        """FakeAPI with one more tag, named `tag`, on the same commit: annotated unless `lightweight`."""
        api = FakeAPI()
        get = api.get
        ref = {"type": "commit", "sha": SHA} if lightweight else {"type": "tag", "sha": "c" * 40}
        api.get = lambda path: {"object": ref} if path == "git/ref/tags/" + tag else get(path)
        return api

    def test_desktop_release_requires_a_signed_annotated_desktop_tag_on_master(self):
        env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "desktop-v0.2.0",
               "GITHUB_REF": "refs/tags/desktop-v0.2.0", "GITHUB_SHA": SHA}
        self.assertEqual(verify_desktop_source(self.desktop_api(), env), (SHA, True))
        # A lightweight tag, an unsigned tag and a tag on another object are refused.
        with self.assertRaisesRegex(ValueError, "signed annotated tag"):
            verify_desktop_source(self.desktop_api(lightweight=True), env)
        for mutate, message in [
                (lambda api: api.tag.update(verification={"verified": False}), "signature or commit target"),
                (lambda api: api.tag.update(object={"type": "tree", "sha": SHA}), "signature or commit target"),
                (lambda api: api.tag.update(object={"type": "commit", "sha": "e" * 40}), "does not identify the workflow commit")]:
            api = self.desktop_api()
            mutate(api)
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                verify_desktop_source(api, env)
        # The tagged commit must be verified and on master's ancestry.
        api = self.desktop_api()
        api.comparison.update(status="diverged")
        with self.assertRaisesRegex(ValueError, "not on reviewed master ancestry"):
            verify_desktop_source(api, env)
        api = self.desktop_api()
        api.commit = {"commit": {"verification": {"verified": False}}}
        with self.assertRaisesRegex(ValueError, "not verified"):
            verify_desktop_source(api, env)
        # Only desktop-vX.Y.Z names a desktop release; a provider tag does not.
        for tag in ("desktop-v0.2", "desktop-v0.2.0-rc1", "desktop-latest", "desktop-v0.2.0.1", "v0.9.13", "xdesktop-v0.2.0"):
            named = dict(env, GITHUB_REF_NAME=tag, GITHUB_REF="refs/tags/" + tag)
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "stable production release tag"):
                verify_desktop_source(self.desktop_api(tag), named)
        with self.assertRaisesRegex(ValueError, "ref mismatch"):
            verify_desktop_source(self.desktop_api(), dict(env, GITHUB_REF="refs/tags/desktop-v0.2.1"))
        # And a desktop tag never names a provider release.
        with self.assertRaisesRegex(ValueError, "stable production release tag"):
            tag_source(self.desktop_api(), "desktop-v0.2.0")

    def test_desktop_dry_run_requires_a_dispatch_on_the_current_master_commit(self):
        master = "d" * 40
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_TYPE": "branch", "GITHUB_REF": "refs/heads/master",
               "GITHUB_SHA": master}
        self.assertEqual(verify_desktop_source(FakeAPI(), env), (master, False))
        # Another branch, or an older master commit, signs nothing.
        for changed in ({"GITHUB_REF": "refs/heads/dev"}, {"GITHUB_REF": "refs/heads/candidate"}, {"GITHUB_SHA": SHA}):
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, "current reviewed master commit"):
                verify_desktop_source(FakeAPI(), dict(env, **changed))
        # No other event starts a desktop run, on a branch or on a tag.
        for changed in ({"GITHUB_EVENT_NAME": "push"}, {"GITHUB_EVENT_NAME": "pull_request"},
                        {"GITHUB_EVENT_NAME": "schedule"}, {"GITHUB_EVENT_NAME": "create", "GITHUB_REF_TYPE": "tag"}):
            with self.subTest(changed=changed), self.assertRaisesRegex(ValueError, "signed desktop-v tag on master"):
                verify_desktop_source(FakeAPI(), dict(env, **changed))

    def test_desktop_source_command_writes_the_source_and_whether_it_publishes(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            env = {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_OUTPUT": str(output), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "desktop-v0.2.0", "GITHUB_REF": "refs/tags/desktop-v0.2.0",
                   "GITHUB_SHA": SHA}
            with patch.dict(os.environ, env, clear=True), patch("sys.argv", ["resume", "verify-desktop-source"]):
                with patch("provider_release_resume.GitHub", return_value=self.desktop_api()):
                    main()
                self.assertEqual(output.read_text(), f"source_sha={SHA}\npublish=true\n")
                output.unlink()
                dispatch = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_TYPE": "branch",
                            "GITHUB_REF": "refs/heads/master", "GITHUB_SHA": "d" * 40}
                with patch.dict(os.environ, dispatch), patch("provider_release_resume.GitHub", return_value=FakeAPI()):
                    main()
                self.assertEqual(output.read_text(), "source_sha=" + "d" * 40 + "\npublish=false\n")
                output.unlink()
                # A refused source writes nothing for later jobs to read.
                with patch.dict(os.environ, {"GITHUB_REF": "refs/tags/other"}), \
                        patch("provider_release_resume.GitHub", return_value=self.desktop_api()), self.assertRaises(ValueError):
                    main()
            self.assertFalse(output.exists())

    def test_failed_source_verification_emits_no_trusted_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            env = {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_OUTPUT": str(output),
                   "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/candidate", "GITHUB_SHA": SHA}
            with patch.dict(os.environ, env, clear=True), patch("sys.argv", ["resume", "verify-source"]), \
                    patch("provider_release_resume.GitHub", return_value=FakeAPI()), self.assertRaises(ValueError):
                main()
            self.assertFalse(output.exists())

    def test_success_binds_original_source_attempt_and_immutable_artifact(self):
        api = FakeAPI()
        value=select(api,"123","1")
        self.assertEqual(value["source_sha"],SHA)
        self.assertEqual(value["build_run_id"],"123")
        self.assertEqual(value["unsigned_artifact_id"],"10")
        self.assertEqual(value["release_tag"],"v0.9.13")
        self.assertEqual(api.content_requests,
                         [f"contents/provider-swift/Sources/ProviderCore/ProviderCore.swift?ref={SHA}"])

    def test_untrusted_incomplete_expired_or_replaced_inputs_fail(self):
        mutations = [
            lambda x:x.run.update(event="pull_request"),
            lambda x:x.run.update(head_repository={"full_name":"fork/repo"}),
            lambda x:x.run.update(path=".github/workflows/other.yml"),
            lambda x:x.run.update(status="in_progress"),
            lambda x:x.run.update(conclusion="success"),
            lambda x:x.tag["object"].update(sha="e"*40),
            lambda x:x.tag["verification"].update(verified=False),
            lambda x:x.commit["commit"]["verification"].update(verified=False),
            lambda x:x.comparison.update(status="diverged"),
            lambda x:x.comparison["merge_base_commit"].update(sha="e"*40),
            lambda x:setattr(x,"provider_version","0.9.14"),
            lambda x:x.jobs[0].update(conclusion="failure"),
            lambda x:x.jobs[1].update(conclusion="skipped"),
            lambda x:x.jobs.append(copy.deepcopy(x.jobs[0])),
            lambda x:x.jobs[2].update(conclusion="success"),
            lambda x:x.artifacts[0].update(expired=True),
            lambda x:x.artifacts[0]["workflow_run"].update(id=124),
            lambda x:x.artifacts[0]["workflow_run"].update(head_sha="f"*40),
            lambda x:x.artifacts[0].update(digest="bad"),
            lambda x:x.artifacts.append(copy.deepcopy(x.artifacts[0])),
            lambda x:x.artifacts.append({"name":f"provider-publication-{SHA}-1","expired":True}),
        ]
        for index,mutate in enumerate(mutations):
            with self.subTest(index=index):
                api=FakeAPI();mutate(api)
                with self.assertRaises(ValueError):select(api,"123","1")
        for run,attempt in [("123\nsource_sha=bad","1"),("123","0"),("123","2")]:
            with self.assertRaises(ValueError):select(FakeAPI(),run,attempt)

    def test_resolve_requires_explicit_current_master_prod_dispatch(self):
        env={"GITHUB_REPOSITORY":"owner/repo","GITHUB_EVENT_NAME":"workflow_dispatch",
             "GITHUB_REF":"refs/heads/master","GITHUB_SHA":"d"*40,"RELEASE_ENVIRONMENT":"prod",
             "RELEASE_VALIDATION_ONLY":"false","RELEASE_RESUME_RUN_ID":"123","RELEASE_RESUME_RUN_ATTEMPT":"1"}
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp)/"output"
            with patch.dict(os.environ,dict(env,GITHUB_OUTPUT=str(output)),clear=True),patch("sys.argv",["resume","resolve"]),patch("provider_release_resume.GitHub",return_value=FakeAPI()):
                main()
            values=dict(line.split("=",1) for line in output.read_text().splitlines())
            self.assertEqual(values["resume"],"true")
            self.assertEqual(values["source_sha"],SHA)
            for key,value in [("GITHUB_REF","refs/heads/unreviewed"),("GITHUB_SHA","e"*40),
                              ("RELEASE_ENVIRONMENT","dev"),("RELEASE_VALIDATION_ONLY","true"),
                              ("RELEASE_VERSION_OVERRIDE","0.9.14")]:
                with self.subTest(key=key),patch.dict(os.environ,dict(env,**{key:value}),clear=True),patch("sys.argv",["resume","resolve"]),patch("provider_release_resume.GitHub",return_value=FakeAPI()):
                    with self.assertRaises(ValueError):main()

    def test_transport_checksum_and_single_regular_archive_are_required(self):
        for kind in ["valid","wrong-digest","traversal","extra","symlink"]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temp:
                root=Path(temp);archive=root/"artifact.zip"
                with zipfile.ZipFile(archive,"w") as zipped:
                    name="../unsigned-provider.tar.gz" if kind=="traversal" else "unsigned-provider.tar.gz"
                    info=zipfile.ZipInfo(name)
                    if kind=="symlink":info.external_attr=(stat.S_IFLNK|0o777)<<16
                    zipped.writestr(info,b"unchanged tar bytes")
                    if kind=="extra":zipped.writestr("other",b"bad")
                digest="sha256:"+hashlib.sha256(archive.read_bytes()).hexdigest()
                if kind=="wrong-digest":digest="sha256:"+"0"*64
                if kind=="valid":
                    extract_transport(archive,digest,root/"out")
                    self.assertEqual((root/"out/unsigned-provider.tar.gz").read_bytes(),b"unchanged tar bytes")
                else:
                    with self.assertRaises(ValueError):extract_transport(archive,digest,root/"out")

    def test_nested_reusable_workflow_job_names_still_bind_recovery(self):
        # release-swift.yml calls the reusable release-provider.yml, so the
        # Actions API reports each job as "<caller-job-id> / <job-name>". Recovery
        # must bind the nested prod jobs, and still reject a run that lacks the
        # one build, qualification and signing job.
        api=FakeAPI()
        api.jobs=[{"name":"prod / "+name,"status":"completed","conclusion":"success"}
                  for name in (BUILD_JOB,QUALIFY_JOB)]
        api.jobs.append({"name":"prod / "+SIGN_JOB,"status":"completed","conclusion":"failure"})
        self.assertEqual(select(api,"123","1")["source_sha"],SHA)
        for mutate in [lambda x:x.jobs[0].update(name="prod / Unrelated job"),
                       lambda x:x.jobs[2].update(name="prod / Unrelated job")]:
            nested=FakeAPI()
            nested.jobs=[{"name":"prod / "+name,"status":"completed","conclusion":"success"}
                         for name in (BUILD_JOB,QUALIFY_JOB)]
            nested.jobs.append({"name":"prod / "+SIGN_JOB,"status":"completed","conclusion":"failure"})
            mutate(nested)
            with self.assertRaises(ValueError):select(nested,"123","1")

    def test_workflow_success_guard_truth_table(self):
        source=(ROOT/".github/workflows/release-provider.yml").read_text()
        resolver=source.split("  resolve-env:\n",1)[1].split("  build-provider:\n",1)[0]
        self.assertIn("      actions: read",resolver)
        self.assertNotIn("secrets.",resolver)
        sign=source.split("  build-and-release:\n",1)[1].split("    #",1)[0]
        expression=sign.split("${{",1)[1].split("}}",1)[0]
        variables={"needs.resolve-env.result":"resolve", "needs.resolve-env.outputs.resume":"resume",
                   "needs.build-provider.result":"build"}
        for old,new in variables.items():expression=expression.replace(old,new)
        expression=expression.replace("!cancelled()","not cancelled").replace("&&","and").replace("||","or")
        expression=" ".join(expression.split())
        for cancelled,resolve,resume,build in itertools.product([False,True],["success","failure"],["true","false","bad"],["success","failure","skipped"]):
            actual=eval(expression,{"__builtins__":{}},locals())
            expected=not cancelled and resolve=="success" and ((resume=="true" and build=="skipped") or (resume=="false" and build=="success"))
            self.assertEqual(actual,expected)
        body=source.split("  build-provider:\n",1)[1].split("    runs-on:",1)[0]
        self.assertIn("if: needs.resolve-env.outputs.resume != 'true'",body)
        # Qualification (release-qualify.yml) runs before this workflow; the
        # caller skips it only for a resume, whose retained run passed it.
        caller=(ROOT/".github/workflows/release-swift.yml").read_text()
        qualify=caller.split("\n  qualify:\n",1)[1].split("\n  dev:\n",1)[0]
        self.assertIn("${{ !inputs.resume_run_id &&",qualify)
        self.assertNotIn("qualify-sdk",source)


if __name__=="__main__":unittest.main()
