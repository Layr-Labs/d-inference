#!/usr/bin/env python3

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import summarize_physical as summary


TRACE_XML = """<?xml version="1.0"?>
<trace-query-result>
<node>
<schema>
<col><mnemonic>duration</mnemonic></col>
<col><mnemonic>gpu-performance-state</mnemonic></col>
<col><mnemonic>is-induced</mnemonic></col>
<col><mnemonic>narrative</mnemonic></col>
</schema>
<row>
<duration id="1">2000000000</duration>
<gpu-performance-state id="2" fmt="Maximum">Maximum</gpu-performance-state>
<boolean id="3" fmt="Yes">1</boolean>
<narrative id="4" fmt="Maximum GPU state due to active device conditions"/>
</row>
<row>
<duration>1000000000</duration>
<gpu-performance-state ref="2"/>
<boolean ref="3"/>
<narrative ref="4"/>
</row>
</node>
</trace-query-result>
"""

DEVICE_STATE_XML = """<?xml version="1.0"?>
<trace-query-result>
<node>
<schema>
<col><mnemonic>duration</mnemonic></col>
<col><mnemonic>state</mnemonic></col>
<col><mnemonic>desired-state</mnemonic></col>
</schema>
<row>
<duration>3000000000</duration>
<uint32>3</uint32>
<uint32>0</uint32>
</row>
</node>
</trace-query-result>
"""

COUNTER_XML = """<?xml version="1.0"?>
<trace-query-result>
<node>
<schema>
<col><mnemonic>name</mnemonic></col>
<col><mnemonic>max-value</mnemonic></col>
<col><mnemonic>description</mnemonic></col>
<col><mnemonic>type</mnemonic></col>
</schema>
<row>
<gpu-counter-name fmt="RT Unit Active">RT Unit Active</gpu-counter-name>
<uint64>100</uint64>
<string fmt="Percentage of active units">Percentage of active units</string>
<string fmt="Percentage">Percentage</string>
</row>
</node>
</trace-query-result>
"""

GPU_INTERVAL_XML = """<?xml version="1.0"?>
<trace-query-result>
<node>
<schema>
<col><mnemonic>start</mnemonic></col>
<col><mnemonic>duration</mnemonic></col>
<col><mnemonic>channel-name</mnemonic></col>
<col><mnemonic>start-latency</mnemonic></col>
<col><mnemonic>event-depth</mnemonic></col>
<col><mnemonic>event-label</mnemonic></col>
<col><mnemonic>state</mnemonic></col>
<col><mnemonic>process</mnemonic></col>
</schema>
<row>
<start-time>0</start-time>
<duration>1000000</duration>
<gpu-channel-name fmt="Compute">Compute</gpu-channel-name>
<duration>100000</duration>
<metal-nesting-level>0</metal-nesting-level>
<formatted-label id="1" fmt="GPU Execution ( darkbloom (42) )">
<process id="2" fmt="darkbloom (42)"><pid>42</pid></process>
</formatted-label>
<gpu-state fmt="Active">Active</gpu-state>
<process ref="2"/>
</row>
<row>
<start-time>1100000</start-time>
<duration>900000</duration>
<gpu-channel-name fmt="Compute">Compute</gpu-channel-name>
<duration>200000</duration>
<metal-nesting-level>0</metal-nesting-level>
<formatted-label ref="1"/>
<gpu-state fmt="Active">Active</gpu-state>
<process ref="2"/>
</row>
</node>
</trace-query-result>
"""


class PhysicalSummaryTests(unittest.TestCase):
    def write_trace(self, directory: Path, name: str, contents: str) -> Path:
        path = directory / name
        path.write_text(contents, encoding="utf-8")
        return path

    def test_performance_levels_resolve_references_and_weight_duration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_trace(
                Path(temporary),
                "performance.xml",
                TRACE_XML,
            )
            lines = list(
                summary.summarize_performance_levels(summary.TraceTable(path))
            )

        self.assertIn(
            "TRACE_PERFORMANCE_LEVEL state=Maximum"
            " duration_s=3.000000 fraction=1.000000",
            lines,
        )
        self.assertIn(
            "TRACE_PERFORMANCE_REASON"
            " reason=Maximum_GPU_state_due_to_active_device_conditions"
            " duration_s=3.000000 fraction=1.000000",
            lines,
        )
        self.assertIn(
            "TRACE_PERFORMANCE_LEVEL_SUMMARY"
            " rows=2 duration_s=3.000000 induced_s=3.000000",
            lines,
        )

    def test_device_state_is_not_mislabeled_as_frequency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_trace(
                Path(temporary),
                "device.xml",
                DEVICE_STATE_XML,
            )
            lines = list(
                summary.summarize_device_states(summary.TraceTable(path))
            )

        self.assertIn(
            "TRACE_DEVICE_STATE raw_state=3 raw_desired_state=0"
            " duration_s=3.000000 fraction=1.000000"
            " semantics=opaque_performance_level",
            lines,
        )
        self.assertTrue(all("frequency_hz" not in line for line in lines))

    def test_counter_catalog_reports_only_exposed_counter_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_trace(
                Path(temporary),
                "counter.xml",
                COUNTER_XML,
            )
            lines = list(
                summary.summarize_counter_info(summary.TraceTable(path))
            )

        self.assertEqual(lines[0], "TRACE_COUNTER_INFO status=available rows=1")
        self.assertEqual(
            lines[1],
            "TRACE_COUNTER name=RT_Unit_Active type=Percentage"
            " max_value=100 description=Percentage_of_active_units",
        )

    def test_missing_trace_table_is_distinct_from_empty_export(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lines = list(summary.summarize_counts(Path(temporary)))

        self.assertTrue(lines)
        self.assertTrue(all("status=not_exported" in line for line in lines))

    def test_gpu_intervals_measure_submission_gaps_and_latency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_trace(
                Path(temporary),
                "gpu-intervals.xml",
                GPU_INTERVAL_XML,
            )
            lines = list(
                summary.summarize_gpu_intervals(summary.TraceTable(path))
            )

        self.assertEqual(len(lines), 1)
        self.assertIn("process=darkbloom_(42)", lines[0])
        self.assertIn("rows=2 channels=Compute:2", lines[0])
        self.assertIn("span_s=0.002000 busy_s=0.001900", lines[0])
        self.assertIn("duty_fraction=0.950000 idle_gap_s=0.000100", lines[0])
        self.assertIn("gap_count=1 gap_median_us=100.000", lines[0])
        self.assertIn("gaps_over_1ms=0 gaps_over_1ms_s=0.000000", lines[0])
        self.assertIn("start_latency_median_us=150.000", lines[0])


if __name__ == "__main__":
    unittest.main()
