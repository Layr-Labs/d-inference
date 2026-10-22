#!/usr/bin/env python3
"""Run the compiled CPU fixture, never the native/model worker."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile


def main(binary, fixtures):
    binary, fixtures = pathlib.Path(binary).resolve(strict=True), pathlib.Path(fixtures).resolve(strict=True)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    names = ["registered-qwen35-9b.configuration.json", "registered-qwen35-9b.manifest.json"]
    originals = [(fixtures / name).read_bytes() for name in names]
    cases = []
    with tempfile.TemporaryDirectory(prefix="capability-command-") as temporary:
        directory = pathlib.Path(temporary)
        config, manifest = directory / "config.json", directory / "manifest.json"
        config.write_bytes(originals[0]); manifest.write_bytes(originals[1])
        link = directory / "config-link"; link.symlink_to(config)
        argv = [str(binary), "--describe-runtime", "--config", str(config), "--manifest", str(manifest),
                "--expected-executable-sha256", digest]

        def case(name, args, success, contains=None):
            result = subprocess.run(args, capture_output=True, timeout=20)
            assert (result.returncode == 0) is success, (name, result.returncode, result.stderr)
            if success:
                assert result.stderr == b""
                value = json.loads(result.stdout)
                assert value["runtimeBinarySHA256"] == digest
                assert value["profile"]["maximumOutputTokens"] == 32768 and value["profile"]["maximumPromptTokens"] == 32768
                assert [p["stages"][0]["sourceLayerEnd"] for p in value["partitions"]] == [4, 8, 12, 16]
                assert result.stdout == (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
            else:
                assert result.stdout == b"", name
                assert contains in result.stderr, (name, result.stderr)
            cases.append(name)

        case("actual-fixture-executable-binding", argv, True)
        wrong = list(argv); wrong[-1] = "0" * 64; wrong[3] = str(directory / "does-not-exist")
        case("binary-refusal-precedes-metadata-open", wrong, False, b"Installed executable bytes differ")
        symlink = list(argv); symlink[3] = str(link)
        case("symlink-input-refused", symlink, False, b"Cannot open metadata input")
        case("extra-option-refused", argv + ["--mtp"], False, b"Expected --describe-runtime")
        config.write_bytes(config.read_bytes() + b" ")
        case("changed-config-refused", argv, False, b"exact registered 9B")
    mimo_names = ["registered-mimo-v26-flash-mopd.configuration.json", "registered-mimo-v26-flash-mopd.manifest.json"]
    mimo_argv = [str(binary), "--describe-runtime", "--config", str(fixtures / mimo_names[0]),
                 "--manifest", str(fixtures / mimo_names[1]), "--expected-executable-sha256", digest]
    candidate_id = "registered_mimo_v26_flash_mopd_greedy_generation_v1_image_draft_v1"
    old = subprocess.run(mimo_argv, capture_output=True, timeout=20)
    candidate = subprocess.run(mimo_argv + ["--runtime-profile", candidate_id], capture_output=True, timeout=20)
    assert old.returncode == candidate.returncode == 0 and old.stderr == candidate.stderr == b""
    text, image = json.loads(old.stdout), json.loads(candidate.stdout)
    golden_media = json.loads((fixtures / "mimo-image-candidate.media.json").read_bytes())
    assert text["modality"] == "text" and "media" not in text
    assert image["media"] == golden_media and image["modality"] == "text_image_candidate"
    assert image["adapterID"] == "mimo-v26-rank0-image-candidate" and image["profile"]["id"] == candidate_id
    assert image["runtimeBinarySHA256"] == digest and image["artifactSHA256"] == text["artifactSHA256"]
    assert image["configurationSHA256"] == text["configurationSHA256"] and image["manifestSHA256"] == text["manifestSHA256"]
    assert len(image["partitions"]) == 47
    assert set(p["planSHA256"] for p in image["partitions"]).isdisjoint(p["planSHA256"] for p in text["partitions"])
    assert image["supportedGenerationModes"] == ["pipeline_v1","pipeline_compact_decode_v1","pipeline_mtp_v1"]
    assert not any(k in image for k in ["ready","requestCapacityBytes","servingGrant","approved"])
    assert candidate.stdout == (json.dumps(image, sort_keys=True, separators=(",", ":")) + "\n").encode()
    foreign_argv = [str(binary), "--describe-runtime", "--config", str(fixtures / names[0]),
                    "--manifest", str(fixtures / names[1]), "--expected-executable-sha256", digest]
    wrong_model = subprocess.run(foreign_argv + ["--runtime-profile", candidate_id], capture_output=True, timeout=20)
    assert wrong_model.returncode != 0 and wrong_model.stdout == b""
    unknown = subprocess.run(mimo_argv + ["--runtime-profile", "unregistered"], capture_output=True, timeout=20)
    assert unknown.returncode != 0 and unknown.stdout == b""
    cases += ["actual-cpu-child-private-image-canonical-golden", "text-capability-unchanged-without-profile",
              "candidate-profile-refuses-foreign-artifact", "unknown-private-profile-refused"]
    assert [(fixtures / name).read_bytes() for name in names] == originals
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
    print(json.dumps({"passed": True, "actualCPUChildren": len(cases), "cases": cases,
                      "nativeWorkerExecuted": False, "modelOrGPUExecution": False}, sort_keys=True))


if __name__ == "__main__":
    main(*sys.argv[1:])
