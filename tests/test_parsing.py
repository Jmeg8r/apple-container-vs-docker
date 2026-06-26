"""
Tests for the inline Python parsing snippets embedded in shell scripts added
by this PR. Each snippet is extracted verbatim and tested as a pure function
so we can verify correctness without running Docker/container runtimes.

Covered snippets:
  • mem_mb (bench/lib/util.sh)          — parses "12.3MiB / 7.6GiB" strings
  • fio metrics (bench/scenarios/04_fio_bindmount.sh) — parses fio JSON output
  • iperf3 mbps (bench/scenarios/05_iperf3.sh) — parses iperf3 -J JSON output
  • idle_footprint JSON builder (bench/idle_footprint.sh)
"""

import json
import re
import math
import pytest


# ===========================================================================
# Helpers extracted from util.sh → mem_mb inline Python
# ===========================================================================

def _mem_mb_parse(raw: str) -> str:
    """
    Verbatim logic from bench/lib/util.sh mem_mb().
    Returns the integer MB as a string, or '' on failure.
    """
    m = re.search(r'([\d.]+)\s*([KMG]i?B)', raw)
    if not m:
        return ''
    v = float(m.group(1))
    u = m.group(2)[0]
    mb = {'K': v / 1024, 'M': v, 'G': v * 1024}.get(u, v)
    return str(int(round(mb)))


class TestMemMbParsing:
    # ---- MiB inputs --------------------------------------------------------
    def test_mib_simple(self):
        assert _mem_mb_parse("12.3MiB / 7.6GiB") == "12"

    def test_mib_whole_number(self):
        assert _mem_mb_parse("256MiB / 7.6GiB") == "256"

    def test_mib_fractional_rounds_up(self):
        # 12.6 → round → 13
        assert _mem_mb_parse("12.6MiB / 7.6GiB") == "13"

    def test_mib_fractional_rounds_down(self):
        # 12.4 → round → 12
        assert _mem_mb_parse("12.4MiB / 7.6GiB") == "12"

    def test_mib_at_0_5_boundary(self):
        # Python round() uses banker's rounding; 0.5MiB = 512KiB → 1
        assert _mem_mb_parse("0.5MiB / 8GiB") == "0"  # banker's rounds to 0

    # ---- GiB inputs --------------------------------------------------------
    def test_gib_one(self):
        # 1GiB = 1024 MB
        assert _mem_mb_parse("1GiB / 7.6GiB") == "1024"

    def test_gib_fractional(self):
        # 1.5GiB = 1536 MB
        assert _mem_mb_parse("1.5GiB / 7.6GiB") == "1536"

    def test_gib_large(self):
        # 7.6GiB = 7782.4 → rounds to 7782
        assert _mem_mb_parse("7.6GiB / 7.6GiB") == "7782"

    # ---- KiB inputs --------------------------------------------------------
    def test_kib_exact(self):
        # 1024KiB = 1MB
        assert _mem_mb_parse("1024KiB / 8GiB") == "1"

    def test_kib_less_than_mb(self):
        # 512KiB = 0.5MB → rounds to 0
        assert _mem_mb_parse("512KiB / 8GiB") == "0"

    # ---- Non-'i' variants (KB, MB, GB) ------------------------------------
    def test_mb_without_i(self):
        # "MB" → unit char 'M' → same conversion
        assert _mem_mb_parse("64MB / 8GB") == "64"

    def test_gb_without_i(self):
        # "GB" → unit char 'G' → *1024
        assert _mem_mb_parse("2GB / 8GB") == "2048"

    def test_kb_without_i(self):
        assert _mem_mb_parse("2048KB / 8GB") == "2"

    # ---- Failure / empty cases --------------------------------------------
    def test_empty_string(self):
        assert _mem_mb_parse("") == ""

    def test_no_unit(self):
        assert _mem_mb_parse("12345") == ""

    def test_garbage_input(self):
        assert _mem_mb_parse("N/A") == ""

    def test_only_slash_separator(self):
        # " / 7.6GiB" still contains a valid "7.6GiB" token; the regex will
        # match it and return the GiB value converted to MB (≈7782).
        # The "only slash" case does NOT produce empty output — it matches the
        # denominator.  Use a truly unit-free string to test the empty path.
        assert _mem_mb_parse("N/A / unknown") == ""

    # ---- Only first match used (the "used" half before the slash) ---------
    def test_first_match_wins(self):
        # "12.3MiB / 7.6GiB" — regex finds 12.3MiB first.
        result = _mem_mb_parse("12.3MiB / 7.6GiB")
        assert result == "12"

    # ---- Regression: zero usage -------------------------------------------
    def test_zero_mib(self):
        assert _mem_mb_parse("0MiB / 8GiB") == "0"


# ===========================================================================
# fio JSON parsing (bench/scenarios/04_fio_bindmount.sh)
# ===========================================================================

def _parse_fio_metrics(fio_json: dict) -> dict | str:
    """
    Verbatim logic from 04_fio_bindmount.sh.
    Returns a dict with write_iops and write_bw_mbps, or '' on failure.
    """
    try:
        d = fio_json
        w = d["jobs"][0]["write"]
        return {"write_iops": round(w["iops"], 1),
                "write_bw_mbps": round(w["bw"] / 1024, 1)}
    except Exception:
        return ""


def _make_fio_json(iops: float, bw_kb: float) -> dict:
    """Minimal fio JSON structure with the fields the parser needs."""
    return {"jobs": [{"write": {"iops": iops, "bw": bw_kb}}]}


class TestFioMetricsParsing:
    def test_basic_iops_and_bw(self):
        result = _parse_fio_metrics(_make_fio_json(iops=1234.5, bw_kb=5120.0))
        assert result == {"write_iops": 1234.5, "write_bw_mbps": 5.0}

    def test_bw_conversion_kb_to_mb(self):
        # 1024 KB/s → 1.0 MB/s
        result = _parse_fio_metrics(_make_fio_json(iops=100.0, bw_kb=1024.0))
        assert result["write_bw_mbps"] == 1.0

    def test_bw_fractional_rounding(self):
        # 1500 KB/s → 1.465… → rounds to 1.5
        result = _parse_fio_metrics(_make_fio_json(iops=500.0, bw_kb=1500.0))
        assert result["write_bw_mbps"] == 1.5

    def test_large_values(self):
        # 800 MB/s = 819200 KB/s
        result = _parse_fio_metrics(_make_fio_json(iops=200000.0, bw_kb=819200.0))
        assert result["write_bw_mbps"] == 800.0

    def test_iops_rounding(self):
        result = _parse_fio_metrics(_make_fio_json(iops=9999.567, bw_kb=4096.0))
        assert result["write_iops"] == 9999.6

    def test_zero_values(self):
        result = _parse_fio_metrics(_make_fio_json(iops=0.0, bw_kb=0.0))
        assert result == {"write_iops": 0.0, "write_bw_mbps": 0.0}

    def test_missing_jobs_key(self):
        assert _parse_fio_metrics({}) == ""

    def test_empty_jobs_list(self):
        assert _parse_fio_metrics({"jobs": []}) == ""

    def test_missing_write_key(self):
        assert _parse_fio_metrics({"jobs": [{"read": {}}]}) == ""

    def test_missing_iops_key(self):
        data = {"jobs": [{"write": {"bw": 1024.0}}]}
        assert _parse_fio_metrics(data) == ""

    def test_non_dict_input(self):
        assert _parse_fio_metrics("not a dict") == ""  # type: ignore[arg-type]

    def test_multiple_jobs_uses_first(self):
        # Parser takes jobs[0] — verify it ignores jobs[1].
        data = {
            "jobs": [
                {"write": {"iops": 100.0, "bw": 1024.0}},
                {"write": {"iops": 999.0, "bw": 9999.0}},
            ]
        }
        result = _parse_fio_metrics(data)
        assert result == {"write_iops": 100.0, "write_bw_mbps": 1.0}


# ===========================================================================
# iperf3 JSON parsing (bench/scenarios/05_iperf3.sh)
# ===========================================================================

def _parse_iperf3_mbps(iperf_json: dict) -> str:
    """
    Verbatim logic from 05_iperf3.sh.
    Returns rounded Mbps as a string, or '' on failure.
    """
    try:
        d = iperf_json
        return str(round(d["end"]["sum_received"]["bits_per_second"] / 1e6, 1))
    except Exception:
        return ""


def _make_iperf3_json(bits_per_second: float) -> dict:
    return {"end": {"sum_received": {"bits_per_second": bits_per_second}}}


class TestIperf3Parsing:
    def test_basic_gigabit(self):
        # 1 Gbps = 1000 Mbps
        result = _parse_iperf3_mbps(_make_iperf3_json(1e9))
        assert result == "1000.0"

    def test_typical_container_throughput(self):
        # Smoke run reported ~91,546 Mbps. iperf3 stores bits_per_second, so
        # 91546 Mbps = 91546 * 1e6 bps; dividing by 1e6 gives 91546.0.
        result = _parse_iperf3_mbps(_make_iperf3_json(91546.0 * 1e6))
        assert result == "91546.0"

    def test_fractional_rounding(self):
        # 1234567890 bps → 1234.6 Mbps
        result = _parse_iperf3_mbps(_make_iperf3_json(1_234_567_890.0))
        assert result == "1234.6"

    def test_small_value(self):
        # 10 Mbps
        result = _parse_iperf3_mbps(_make_iperf3_json(10e6))
        assert result == "10.0"

    def test_zero_bps(self):
        result = _parse_iperf3_mbps(_make_iperf3_json(0.0))
        assert result == "0.0"

    def test_missing_end_key(self):
        assert _parse_iperf3_mbps({}) == ""

    def test_missing_sum_received(self):
        assert _parse_iperf3_mbps({"end": {}}) == ""

    def test_missing_bits_per_second(self):
        assert _parse_iperf3_mbps({"end": {"sum_received": {}}}) == ""

    def test_non_dict_input(self):
        assert _parse_iperf3_mbps("not json") == ""  # type: ignore[arg-type]

    def test_10_gbps_value(self):
        # 10 Gbps = 10000 Mbps
        result = _parse_iperf3_mbps(_make_iperf3_json(10e9))
        assert result == "10000.0"


# ===========================================================================
# idle_footprint.sh — JSON output schema
# ===========================================================================

def _build_idle_footprint_record(runtime: str, mb: int, procs: int, env: dict) -> dict:
    """
    Verbatim logic from bench/idle_footprint.sh inline Python block.
    """
    return {
        "scenario": "idle_footprint",
        "runtime": runtime,
        "kind": "rep",
        "status": "ok",
        "metrics": {
            "idle_helper_rss_mb": int(mb),
            "helper_proc_count": int(procs),
        },
        "env": env,
    }


class TestIdleFootprintRecord:
    def _env(self, **overrides):
        base = {"host": "testhost", "os": "macOS 26.5"}
        base.update(overrides)
        return base

    def test_schema_apple_container(self):
        rec = _build_idle_footprint_record("apple-container", 154, 3, self._env())
        assert rec["scenario"] == "idle_footprint"
        assert rec["runtime"] == "apple-container"
        assert rec["kind"] == "rep"
        assert rec["status"] == "ok"
        assert rec["metrics"]["idle_helper_rss_mb"] == 154
        assert rec["metrics"]["helper_proc_count"] == 3

    def test_schema_docker_desktop(self):
        rec = _build_idle_footprint_record("docker-desktop", 1115, 12, self._env())
        assert rec["runtime"] == "docker-desktop"
        assert rec["metrics"]["idle_helper_rss_mb"] == 1115
        assert rec["metrics"]["helper_proc_count"] == 12

    def test_schema_orbstack(self):
        rec = _build_idle_footprint_record("orbstack", 1782, 8, self._env())
        assert rec["runtime"] == "orbstack"
        assert rec["metrics"]["idle_helper_rss_mb"] == 1782

    def test_env_passed_through(self):
        env = {"host": "m3ultra", "os": "macOS 26", "extra": "value"}
        rec = _build_idle_footprint_record("apple-container", 0, 0, env)
        assert rec["env"] == env

    def test_mb_zero(self):
        rec = _build_idle_footprint_record("apple-container", 0, 0, self._env())
        assert rec["metrics"]["idle_helper_rss_mb"] == 0
        assert rec["metrics"]["helper_proc_count"] == 0

    def test_mb_string_coerced_to_int(self):
        # The shell passes argv as strings; the script does int(mb).
        rec = _build_idle_footprint_record("orbstack", "1782", "8", self._env())  # type: ignore
        assert isinstance(rec["metrics"]["idle_helper_rss_mb"], int)
        assert rec["metrics"]["idle_helper_rss_mb"] == 1782

    def test_record_is_json_serializable(self):
        rec = _build_idle_footprint_record("docker-desktop", 500, 5, self._env())
        serialized = json.dumps(rec)
        restored = json.loads(serialized)
        assert restored["scenario"] == "idle_footprint"
        assert restored["metrics"]["idle_helper_rss_mb"] == 500

    def test_all_required_keys_present(self):
        rec = _build_idle_footprint_record("orbstack", 100, 2, self._env())
        required_top = {"scenario", "runtime", "kind", "status", "metrics", "env"}
        assert required_top <= set(rec.keys())
        required_metrics = {"idle_helper_rss_mb", "helper_proc_count"}
        assert required_metrics <= set(rec["metrics"].keys())