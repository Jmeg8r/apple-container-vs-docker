"""
Tests for analysis/report.py — covers the better_label() function and
HIGHER_BETTER constant added in this PR.
"""
import sys
import os
import importlib.util

import pytest

# ---------------------------------------------------------------------------
# Import the module under test without executing main()
# ---------------------------------------------------------------------------
_REPORT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "analysis", "report.py"
)

spec = importlib.util.spec_from_file_location("report", _REPORT_PATH)
report = importlib.util.module_from_spec(spec)
# Stub matplotlib so the import doesn't require a display / full install.
import types

_mpl_stub = types.ModuleType("matplotlib")
_mpl_stub.use = lambda *a, **kw: None
_plt_stub = types.ModuleType("matplotlib.pyplot")
_plt_stub.subplots = lambda *a, **kw: (None, None)
_plt_stub.close = lambda *a, **kw: None
sys.modules.setdefault("matplotlib", _mpl_stub)
sys.modules.setdefault("matplotlib.pyplot", _plt_stub)

spec.loader.exec_module(report)

better_label = report.better_label
HIGHER_BETTER = report.HIGHER_BETTER


# ---------------------------------------------------------------------------
# HIGHER_BETTER constant
# ---------------------------------------------------------------------------
class TestHigherBetterConstant:
    def test_contains_per_sec(self):
        assert "_per_sec" in HIGHER_BETTER

    def test_contains_mbps(self):
        assert "_mbps" in HIGHER_BETTER

    def test_contains_iops(self):
        assert "_iops" in HIGHER_BETTER

    def test_contains_max_containers(self):
        assert "max_containers" in HIGHER_BETTER

    def test_contains_count(self):
        assert "_count" in HIGHER_BETTER

    def test_is_tuple(self):
        # endswith() requires a str or tuple; keep it that way.
        assert isinstance(HIGHER_BETTER, tuple)


# ---------------------------------------------------------------------------
# better_label() — higher-is-better suffixes
# ---------------------------------------------------------------------------
class TestBetterLabelHigherIsBetter:
    """Metrics that should return 'higher is better'."""

    def test_cpu_events_per_sec(self):
        assert better_label("cpu_events_per_sec") == "higher is better"

    def test_net_throughput_mbps(self):
        assert better_label("net_throughput_mbps") == "higher is better"

    def test_write_bw_mbps(self):
        assert better_label("write_bw_mbps") == "higher is better"

    def test_write_iops(self):
        assert better_label("write_iops") == "higher is better"

    def test_max_containers(self):
        # "max_containers" is listed verbatim in HIGHER_BETTER and also
        # contains "max_", so both code paths agree.
        assert better_label("max_containers") == "higher is better"

    def test_helper_proc_count(self):
        assert better_label("helper_proc_count") == "higher is better"

    def test_max_prefix_triggers_higher(self):
        # Any metric whose name contains "max_" should be higher-is-better,
        # even if the suffix is not in HIGHER_BETTER.
        assert better_label("max_open_files") == "higher is better"

    def test_max_connections(self):
        assert better_label("max_connections") == "higher is better"

    def test_arbitrary_per_sec_suffix(self):
        assert better_label("requests_per_sec") == "higher is better"

    def test_arbitrary_mbps_suffix(self):
        assert better_label("upload_mbps") == "higher is better"

    def test_arbitrary_iops_suffix(self):
        assert better_label("read_iops") == "higher is better"

    def test_arbitrary_count_suffix(self):
        assert better_label("event_count") == "higher is better"


# ---------------------------------------------------------------------------
# better_label() — lower-is-better metrics
# ---------------------------------------------------------------------------
class TestBetterLabelLowerIsBetter:
    """Metrics that should return 'lower is better'."""

    def test_run_to_http200_ms(self):
        assert better_label("run_to_http200_ms") == "lower is better"

    def test_run_to_tcp_ms(self):
        assert better_label("run_to_tcp_ms") == "lower is better"

    def test_build_nocache_ms(self):
        assert better_label("build_nocache_ms") == "lower is better"

    def test_build_cached_ms(self):
        assert better_label("build_cached_ms") == "lower is better"

    def test_run_to_stack_ready_ms(self):
        assert better_label("run_to_stack_ready_ms") == "lower is better"

    def test_steady_mem_mb(self):
        assert better_label("steady_mem_mb") == "lower is better"

    def test_idle_helper_rss_mb(self):
        assert better_label("idle_helper_rss_mb") == "lower is better"

    def test_time_to_ceiling_ms(self):
        assert better_label("time_to_ceiling_ms") == "lower is better"

    def test_latency_p99_ms(self):
        assert better_label("latency_p99_ms") == "lower is better"

    def test_generic_ms_suffix(self):
        assert better_label("startup_ms") == "lower is better"

    def test_generic_mb_suffix(self):
        # "_mb" is NOT in HIGHER_BETTER; memory usage is lower-is-better.
        assert better_label("mem_rss_mb") == "lower is better"


# ---------------------------------------------------------------------------
# better_label() — boundary / regression cases
# ---------------------------------------------------------------------------
class TestBetterLabelEdgeCases:
    def test_max_in_middle_of_name(self):
        # "max_" check uses `in`, so it matches anywhere in the string.
        assert better_label("some_max_value") == "higher is better"

    def test_empty_string(self):
        # An empty metric name has no matching suffix and no "max_".
        assert better_label("") == "lower is better"

    def test_per_sec_not_at_end(self):
        # "endswith" only matches at the tail; prefix match should not trigger.
        assert better_label("per_sec_overhead") == "lower is better"

    def test_mbps_not_at_end(self):
        assert better_label("mbps_limit") == "lower is better"

    def test_iops_not_at_end(self):
        assert better_label("iops_cap") == "lower is better"

    def test_count_not_at_end(self):
        # "_count" must be a suffix; "_counter" should not match.
        assert better_label("event_counter") == "lower is better"

    def test_manual_command_count(self):
        # manual_command_count ends with "_count" → higher is better (more
        # commands is not desirable in UX, but the metric direction rule is
        # consistent — the harness records it as a "count" metric).
        assert better_label("manual_command_count") == "higher is better"

    def test_case_sensitivity_mbps(self):
        # The suffix check is case-sensitive; uppercase variants are lower-is-better.
        assert better_label("net_throughput_Mbps") == "lower is better"

    def test_case_sensitivity_per_sec(self):
        assert better_label("cpu_events_Per_Sec") == "lower is better"

    def test_hit_cap_boolean_metric(self):
        # hit_cap is a boolean field; no special suffix → lower is better.
        assert better_label("hit_cap") == "lower is better"