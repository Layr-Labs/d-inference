from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import benchmark_provenance as provenance
import host_capture
import model_capture


class SerializationTests(unittest.TestCase):
    def test_canonical_and_pretty_serialization_are_stable(self) -> None:
        left = {"z": [3, 2], "a": {"β": True, "n": None}}
        right = {"a": {"n": None, "β": True}, "z": [3, 2]}

        self.assertEqual(
            provenance.canonical_json_bytes(left),
            provenance.canonical_json_bytes(right),
        )
        self.assertEqual(
            provenance.canonical_json_bytes(left),
            '{"a":{"n":null,"β":true},"z":[3,2]}'.encode(),
        )
        self.assertEqual(provenance.pretty_json(left), provenance.pretty_json(right))
        self.assertTrue(provenance.pretty_json(left).endswith("\n"))

    def test_configuration_hash_ignores_mapping_insertion_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "provider.toml"
            config.write_text("kv_backend = \"contiguous\"\n", encoding="utf-8")
            settings_a = {
                "batch": {"redacted": False, "value": "4"},
                "prompt": {"redacted": False, "value": "8192"},
            }
            settings_b = {
                "prompt": {"redacted": False, "value": "8192"},
                "batch": {"redacted": False, "value": "4"},
            }
            env_a = {
                "MLX_B": {"redacted": False, "value": "2"},
                "MLX_A": {"redacted": False, "value": "1"},
            }
            env_b = {
                "MLX_A": {"redacted": False, "value": "1"},
                "MLX_B": {"redacted": False, "value": "2"},
            }

            first = provenance.capture_configuration([config], settings_a, env_a)
            second = provenance.capture_configuration([config], settings_b, env_b)

            self.assertEqual(first["sha256"], second["sha256"])


class SecretSafetyTests(unittest.TestCase):
    def test_environment_is_allowlisted_and_secrets_are_redacted(self) -> None:
        environment = provenance.capture_environment(
            {
                "DARKBLOOM_API_KEY": "must-not-appear",
                "DARKBLOOM_COORDINATOR_URL": (
                    "https://user:password@example.test/ws/provider?token=secret"
                ),
                "HF_TOKEN": "also-must-not-appear",
                "MLX_COMMIT": "a" * 40,
                "MLX_GATHER_QMM_EXPERT_SLICES": "trust",
                "UNRELATED_SECRET": "not-selected",
            }
        )

        serialized = provenance.pretty_json(environment)
        self.assertNotIn("must-not-appear", serialized)
        self.assertNotIn("also-must-not-appear", serialized)
        self.assertNotIn("not-selected", serialized)
        self.assertEqual(
            environment["DARKBLOOM_API_KEY"]["value"], "<redacted>"
        )
        self.assertEqual(
            environment["DARKBLOOM_COORDINATOR_URL"]["value"],
            "https://example.test/ws/provider",
        )
        self.assertTrue(
            environment["DARKBLOOM_COORDINATOR_URL"]["redacted"]
        )
        self.assertEqual(environment["MLX_COMMIT"]["value"], "a" * 40)

    def test_settings_reject_duplicates_and_redact_secret_keys(self) -> None:
        settings = provenance.parse_settings(
            ["batch=4", "provider_token=must-not-appear"]
        )
        self.assertEqual(settings["batch"]["value"], "4")
        self.assertEqual(settings["provider_token"]["value"], "<redacted>")
        with self.assertRaises(provenance.ProvenanceError):
            provenance.parse_settings(["batch=2", "batch=4"])

    def test_gpu_capture_drops_serial_and_display_identifiers(self) -> None:
        profiler_output = """
        Apple M3 Max:
          Chipset Model: Apple M3 Max
          Total Number of Cores: 40
          Metal Support: Metal 4
          Displays:
            Serial Number: must-not-appear
            Display Serial Number: also-must-not-appear
        """
        command_result = {
            "argv": ["system_profiler", "SPDisplaysDataType"],
            "available": True,
            "exit_code": 0,
            "stderr": "",
            "stdout": profiler_output,
        }
        with mock.patch.object(
            host_capture, "run_command", return_value=command_result
        ):
            result = host_capture._capture_gpu_summary()

        serialized = provenance.pretty_json(result)
        self.assertNotIn("must-not-appear", serialized)
        self.assertEqual(
            result["adapters"],
            [
                {
                    "chipset_model": "Apple M3 Max",
                    "core_count": "40",
                    "metal_support": "Metal 4",
                }
            ],
        )


class GitProvenanceTests(unittest.TestCase):
    def test_recursive_submodule_status_preserves_state_and_sha(self) -> None:
        clean_sha = "1" * 40
        changed_sha = "2" * 40
        records = provenance.parse_submodule_status(
            f" {clean_sha} libs/clean (heads/main)\n"
            f"+{changed_sha} libs/changed (v1.0-2-g{changed_sha[:7]})\n"
        )

        self.assertEqual(
            records,
            [
                {
                    "description": "heads/main",
                    "path": "libs/clean",
                    "sha": clean_sha,
                    "state": "clean",
                },
                {
                    "description": f"v1.0-2-g{changed_sha[:7]}",
                    "path": "libs/changed",
                    "sha": changed_sha,
                    "state": "checked_out_sha_differs",
                },
            ],
        )

    def test_malformed_submodule_status_fails_closed(self) -> None:
        with self.assertRaises(provenance.ProvenanceError):
            provenance.parse_submodule_status("not a submodule status line")


class ModelIdentityTests(unittest.TestCase):
    @staticmethod
    def _aggregate(entries: list[dict[str, object]]) -> str:
        ordered = sorted(entries, key=lambda entry: str(entry["path"]))
        payload = b"".join(bytes.fromhex(str(entry["sha256"])) for entry in ordered)
        return hashlib.sha256(payload).hexdigest()

    def test_registry_manifest_pins_identity_without_reading_weight_payloads(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model = root / "local"
            model.mkdir()
            config = b'{"model_type":"qwen3_5_moe"}\n'
            index = b'{"weight_map":{"x":"model-00001-of-00001.safetensors"}}\n'
            weight = b"not read by provenance"
            (model / "config.json").write_bytes(config)
            (model / "model.safetensors.index.json").write_bytes(index)
            (model / "model-00001-of-00001.safetensors").write_bytes(weight)

            files: list[dict[str, object]] = []
            for name, payload, role in (
                ("config.json", config, "config"),
                ("model.safetensors.index.json", index, "config"),
                ("model-00001-of-00001.safetensors", weight, "weight"),
            ):
                files.append(
                    {
                        "path": name,
                        "role": role,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size_bytes": len(payload),
                    }
                )
            manifest = {
                "aggregate_sha256": self._aggregate(files),
                "file_count": len(files),
                "files": files,
                "model_id": "qwen-test",
                "schema_version": 1,
                "total_size_bytes": sum(int(item["size_bytes"]) for item in files),
                "version": "immutable-test",
            }
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with mock.patch.object(
                model_capture,
                "file_record",
                wraps=model_capture.file_record,
            ) as record_spy:
                result = provenance.capture_model(
                    model, registry_manifest_path=manifest_path
                )

            recorded_paths = [call.args[0] for call in record_spy.call_args_list]
            self.assertFalse(
                any(path.suffix == ".safetensors" for path in recorded_paths)
            )
            self.assertTrue(result["identity"]["complete"])
            self.assertEqual(
                result["identity"]["source"],
                "registry_manifest_aggregate_sha256",
            )
            self.assertFalse(result["safetensors"]["weight_bytes_rehashed"])
            self.assertEqual(result["registry_manifest"]["issues"], [])

    def test_content_addressed_hugging_face_symlink_is_exact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            blob_digest = "a" * 64
            blob = root / "blobs" / blob_digest
            blob.parent.mkdir()
            blob.write_bytes(b"weight")
            model = root / "snapshots" / "local"
            model.mkdir(parents=True)
            os.symlink(blob, model / "model.safetensors")
            (model / "config.json").write_text("{}\n", encoding="utf-8")

            result = provenance.capture_model(model)

            self.assertTrue(result["identity"]["complete"])
            self.assertEqual(
                result["identity"]["source"],
                "content_addressed_safetensor_symlinks",
            )
            self.assertEqual(
                result["safetensors"]["files"][0]["content_sha256"], blob_digest
            )

    def test_plain_local_alias_is_explicitly_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "local"
            model.mkdir()
            (model / "config.json").write_text("{}\n", encoding="utf-8")
            (model / "model.safetensors").write_bytes(b"weight")

            result = provenance.capture_model(model)

            self.assertFalse(result["identity"]["complete"])
            self.assertEqual(result["identity"]["source"], "incomplete")
            self.assertIsNone(
                result["safetensors"]["files"][0]["content_sha256"]
            )

    def test_snapshot_id_must_be_immutable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "local"
            model.mkdir()
            (model / "config.json").write_text("{}\n", encoding="utf-8")
            (model / "model.safetensors").write_bytes(b"weight")
            with self.assertRaises(provenance.ProvenanceError):
                provenance.capture_model(model, snapshot_id="moving-main")


if __name__ == "__main__":
    unittest.main()
