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
    def get(self,path):
        if path == "actions/runs/123":return self.run
        if path == "git/ref/tags/v0.9.13":return {"object":{"type":"tag","sha":"c"*40}}
        if path == "git/tags/" + "c"*40:return self.tag
        if path == "commits/" + SHA:return self.commit
        if path == "git/ref/heads/master":return {"object":{"sha":"d"*40}}
        if path.startswith("contents/"):
            source = ('public static let version = "'+self.provider_version+'"' if "ProviderCore.swift" in path
                      else 'var LatestProviderVersion = "0.9.13"')
            return {"content":base64.b64encode(source.encode()).decode()}
        raise AssertionError(path)
    def pages(self,path,key):
        if path == "actions/runs/123/attempts/1/jobs" and key == "jobs":return self.jobs
        if path == "actions/runs/123/artifacts" and key == "artifacts":return self.artifacts
        raise AssertionError(path)


class RecoveryTests(unittest.TestCase):
    def test_success_binds_original_source_attempt_and_immutable_artifact(self):
        value=select(FakeAPI(),"123","1")
        self.assertEqual(value["source_sha"],SHA)
        self.assertEqual(value["build_run_id"],"123")
        self.assertEqual(value["unsigned_artifact_id"],"10")
        self.assertEqual(value["release_tag"],"v0.9.13")

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

    def test_workflow_success_guard_truth_table(self):
        source=(ROOT/".github/workflows/release-swift.yml").read_text()
        resolver=source.split("  resolve-env:\n",1)[1].split("  build-provider:\n",1)[0]
        self.assertIn("      actions: read",resolver)
        self.assertNotIn("secrets.",resolver)
        sign=source.split("  build-and-release:\n",1)[1].split("    #",1)[0]
        expression=sign.split("${{",1)[1].split("}}",1)[0]
        variables={"needs.resolve-env.result":"resolve", "needs.resolve-env.outputs.resume":"resume",
                   "needs.build-provider.result":"build", "needs.qualify-sdk.result":"qualify"}
        for old,new in variables.items():expression=expression.replace(old,new)
        expression=expression.replace("!cancelled()","not cancelled").replace("&&","and").replace("||","or")
        expression=" ".join(expression.split())
        for cancelled,resolve,resume,build,qualify in itertools.product([False,True],["success","failure"],["true","false","bad"],["success","failure","skipped"],["success","failure","skipped"]):
            actual=eval(expression,{"__builtins__":{}},locals())
            expected=not cancelled and resolve=="success" and ((resume=="true" and build==qualify=="skipped") or (resume=="false" and build==qualify=="success"))
            self.assertEqual(actual,expected)
        for name in ["build-provider","qualify-sdk"]:
            body=source.split("  "+name+":\n",1)[1].split("    runs-on:",1)[0]
            self.assertIn("if: needs.resolve-env.outputs.resume != 'true'",body)


if __name__=="__main__":unittest.main()
