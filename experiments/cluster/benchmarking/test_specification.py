"""Fabricated CPU cases for the fixed paired-study contract and ordering."""

from copy import deepcopy
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from . import specification
from .specification import make_schedule, read_study


def study_document():
    return dict(schema="cluster_prefill_study_v1", study_id="example", seed=7,
                artifact_sha256="a" * 64, configuration_sha256="b" * 64,
                numerical_policy="native-bfloat16", tokenizer_sha256="c" * 64,
                chunk_size=512,
                prompts=[dict(id="p" + str(i), prompt_sha256=format(i + 1, "064x"),
                              origin_sha256=format(i + 11, "064x")) for i in range(10)],
                conditions=[dict(id="single", role="solo", runtime_identity_sha256="d" * 64,
                                 device_ids=["machine-a"]),
                            dict(id="split", role="distributed", runtime_identity_sha256="e" * 64,
                                 device_ids=["machine-a", "machine-b"])])


class SpecificationTests(unittest.TestCase):
    def test_normalization_detaches_all_mutable_metadata(self):
        source = study_document(); result = read_study(source)
        source["prompts"][0]["id"] = "changed"
        source["conditions"][0]["device_ids"][0] = "changed"
        self.assertEqual(result["prompts"][0]["id"], "p0")
        self.assertEqual(result["conditions"][0]["device_ids"], ["machine-a"])
        result["conditions"][1]["device_ids"].append("untrusted")
        self.assertEqual(len(source["conditions"][1]["device_ids"]), 2)
        self.assertEqual({key: result[key] for key in
                          ("token_count", "batch_size", "warmup_count", "measured_runs")},
                         dict(token_count=8192, batch_size=1, warmup_count=1, measured_runs=3))

    def test_closed_top_level_and_nested_fields(self):
        source = study_document()
        for key in source:
            value = deepcopy(source); value.pop(key)
            with self.subTest(missing=key), self.assertRaises(ValueError):
                read_study(value)
        for key in ("token_count", "batch_size", "warmup_count", "measured_runs", "hardware_attested"):
            value = deepcopy(source); value[key] = 1
            with self.subTest(extra=key), self.assertRaises(ValueError):
                read_study(value)
        for collection in ("prompts", "conditions"):
            row = source[collection][0]
            for key in row:
                value = deepcopy(source); value[collection][0].pop(key)
                with self.subTest(collection=collection, missing=key), self.assertRaises(ValueError):
                    read_study(value)
            value = deepcopy(source); value[collection][0]["extra"] = True
            with self.subTest(collection=collection, extra=True), self.assertRaises(ValueError):
                read_study(value)

    def test_schema_and_json_container_types(self):
        for value in (None, [], "{}", 1):
            with self.subTest(document=value), self.assertRaises(ValueError):
                read_study(value)
        for key, value in (("schema", "cluster_prefill_study_v2"), ("schema", True),
                           ("prompts", {}), ("prompts", ()), ("conditions", {}),
                           ("conditions", ()), ("prompts", [None] * 10)):
            source = study_document(); source[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                read_study(source)

    def test_integer_bounds_reject_boolean_float_string_and_overflow(self):
        for key, invalid in (("seed", (True, False, -1, 2**63, 7.0, "7")),
                             ("chunk_size", (True, False, 0, 8193, 512.0, "512"))):
            for value in invalid:
                source = study_document(); source[key] = value
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    read_study(source)
        for seed in (0, 2**63 - 1):
            for chunk in (1, 8192):
                source = study_document(); source.update(seed=seed, chunk_size=chunk)
                self.assertEqual(read_study(source)["chunk_size"], chunk)

    def test_labels_are_bounded_ascii_and_cannot_collide_with_id_separators(self):
        for invalid in ("", "x" * 65, "a:b", "a/b", "a b", "a\n", "é", True):
            for target in ("study", "prompt", "condition", "device"):
                source = study_document()
                if target == "study": source["study_id"] = invalid
                elif target == "prompt": source["prompts"][0]["id"] = invalid
                elif target == "condition": source["conditions"][0]["id"] = invalid
                else: source["conditions"][1]["device_ids"][1] = invalid
                with self.subTest(target=target, value=invalid), self.assertRaises(ValueError):
                    read_study(source)
        source = study_document(); source["study_id"] = "A_0-." + "x" * 59
        self.assertEqual(len(read_study(source)["study_id"]), 64)

    def test_policy_and_all_hash_fields_are_strict(self):
        for value in ("", " ", "x" * 129, "native\n", "nátive", True):
            source = study_document(); source["numerical_policy"] = value
            with self.subTest(policy=value), self.assertRaises(ValueError):
                read_study(source)
        for where, key in (("top", "artifact_sha256"), ("top", "configuration_sha256"),
                           ("top", "tokenizer_sha256"), ("prompt", "prompt_sha256"),
                           ("prompt", "origin_sha256"), ("condition", "runtime_identity_sha256")):
            for value in ("a" * 63, "a" * 65, "A" * 64, "g" * 64, True, None):
                source = study_document()
                row = source if where == "top" else source[where + "s"][0]
                row[key] = value
                with self.subTest(where=where, key=key, value=value), self.assertRaises(ValueError):
                    read_study(source)

    def test_prompt_count_ids_and_raw_pins_are_independently_unique(self):
        for count in (0, 9, 11):
            source = study_document(); source["prompts"] = (source["prompts"] * 2)[:count]
            with self.subTest(count=count), self.assertRaises(ValueError):
                read_study(source)
        for key in ("id", "prompt_sha256"):
            source = study_document(); source["prompts"][1][key] = source["prompts"][0][key]
            with self.subTest(duplicate=key), self.assertRaises(ValueError):
                read_study(source)
        source = study_document(); source["prompts"][1]["origin_sha256"] = source["prompts"][0]["origin_sha256"]
        self.assertEqual(len(read_study(source)["prompts"]), 10)

    def test_condition_roles_counts_and_comparison_device_membership(self):
        sources = []
        for count in (0, 1, 3):
            value = study_document(); value["conditions"] = (value["conditions"] * 2)[:count]; sources.append(value)
        for role in ("other", None, True, "solo"):
            value = study_document(); value["conditions"][1]["role"] = role; sources.append(value)
        value = study_document(); value["conditions"][1].update(role="solo", device_ids=["machine-b"]); sources.append(value)
        value = study_document(); value["conditions"][0] = deepcopy(value["conditions"][1]); value["conditions"][0]["id"] = "second"; sources.append(value)
        value = study_document(); value["conditions"][1]["id"] = "single"; sources.append(value)
        for index, devices in ((0, []), (0, ["machine-a", "machine-b"]),
                               (1, ["machine-a"]), (1, ["machine-a"] * 2),
                               (1, ["machine-a", "machine-b", "machine-c"]),
                               (1, ("machine-a", "machine-b")), (0, ["machine-c"])):
            value = study_document(); value["conditions"][index]["device_ids"] = devices; sources.append(value)
        for index, value in enumerate(sources):
            with self.subTest(case=index), self.assertRaises(ValueError):
                read_study(value)
        value = study_document(); value["conditions"][0]["device_ids"] = ["machine-b"]
        self.assertEqual(read_study(value)["conditions"][0]["device_ids"], ["machine-b"])

    def test_known_seed_order_and_input_permutation_invariance(self):
        source = study_document(); result = make_schedule(source)
        self.assertEqual([row["prompt_id"] for row in result[::2]],
                         ["p8", "p4", "p5", "p7", "p9", "p2", "p6", "p3", "p0", "p1"])
        source["prompts"].reverse(); source["conditions"].reverse()
        self.assertEqual(make_schedule(source), result)
        self.assertEqual(make_schedule(read_study(source)), result)
        source["seed"] = 0
        self.assertNotEqual(make_schedule(source), result)

    def test_hash_collision_tie_breaks_by_prompt_id(self):
        source = study_document(); source["prompts"].reverse()
        with patch.object(specification.hashlib, "sha256", return_value=SimpleNamespace(digest=lambda: b"\0" * 32)):
            result = make_schedule(source)
        self.assertEqual([row["prompt_id"] for row in result[::2]], ["p" + str(i) for i in range(10)])

    def test_schedule_is_balanced_and_covers_eighty_unique_requests(self):
        source = study_document(); schedule = make_schedule(source)
        self.assertEqual(len(schedule), 20)
        self.assertEqual(len({row["cohort_id"] for row in schedule}), 20)
        orders = []; request_ids = []; phases = []
        for index in range(10):
            pair = schedule[index * 2:index * 2 + 2]
            self.assertEqual(pair[0]["prompt_id"], pair[1]["prompt_id"])
            self.assertEqual(pair[0]["prompt_sha256"], pair[1]["prompt_sha256"])
            orders.append(tuple(row["condition_id"] for row in pair))
        self.assertEqual(orders, [("single", "split"), ("split", "single")] * 5)
        pins = {row["id"]: row["prompt_sha256"] for row in source["prompts"]}
        for row in schedule:
            self.assertEqual(set(row), {"cohort_id", "prompt_id", "condition_id", "prompt_sha256", "requests"})
            self.assertEqual(row["prompt_sha256"], pins[row["prompt_id"]])
            cohort = row["prompt_id"] + ":" + row["condition_id"]
            self.assertEqual(row["cohort_id"], cohort)
            self.assertEqual([(request["phase"], request["iteration"]) for request in row["requests"]],
                             [("warmup", 0), ("measured", 0), ("measured", 1), ("measured", 2)])
            for request in row["requests"]:
                self.assertEqual(set(request), {"request_id", "phase", "iteration"})
                self.assertEqual(request["request_id"], cohort + ":" + request["phase"] + ":" + str(request["iteration"]))
                request_ids.append(request["request_id"]); phases.append(request["phase"])
        self.assertEqual(len(set(request_ids)), 80)
        self.assertEqual(phases.count("warmup"), 20); self.assertEqual(phases.count("measured"), 60)

    def test_make_schedule_revalidates_normalized_metadata_and_fixed_counts(self):
        normalized = read_study(study_document())
        with self.assertRaises(ValueError): read_study(normalized)
        for key in ("token_count", "batch_size", "warmup_count", "measured_runs"):
            for value in (True, normalized[key] + 1):
                bad = deepcopy(normalized); bad[key] = value
                with self.subTest(key=key, value=value), self.assertRaises(ValueError): make_schedule(bad)
            bad = deepcopy(normalized); bad.pop(key)
            with self.subTest(missing=key), self.assertRaises(ValueError): make_schedule(bad)
        bad = deepcopy(normalized); bad["conditions"][1]["device_ids"][1] = "machine-a"
        with self.assertRaises(ValueError): make_schedule(bad)
        bad = deepcopy(normalized); bad["prompts"][0]["prompt_sha256"] = "invalid"
        with self.assertRaises(ValueError): make_schedule(bad)

    def test_returned_schedules_are_detached_from_study_and_each_other(self):
        study = read_study(study_document()); original = deepcopy(study)
        first = make_schedule(study); second = make_schedule(study)
        first[0]["requests"][0]["phase"] = "changed"
        first[1]["prompt_id"] = "changed"
        self.assertEqual(study, original)
        self.assertEqual(second, make_schedule(study))
        self.assertEqual(first[1]["requests"][0]["phase"], "warmup")


if __name__ == "__main__":
    unittest.main()
