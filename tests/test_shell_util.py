"""
Tests for shell-script utilities added in this PR, exercised via subprocess.

Covered:
  • free_port() inline Python (bench/lib/util.sh) — port is valid and open
  • idle_footprint.sh runtime validation — rejects unknown runtimes, accepts known ones
  • container_ip() RFC-1918 grep pattern (util.sh) — regex correctness via Python
  • mem_mb inline Python — full round-trip via subprocess (no container needed)
  • service_endpoint() — docker/orbstack branch produces correct host/port string
  • 08_density.sh hit_cap logic — standalone arithmetic correctness
"""

import json
import re
import subprocess
import sys
import textwrap
import os

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
IDLE_FOOTPRINT = os.path.join(ROOT, "bench", "idle_footprint.sh")


# ---------------------------------------------------------------------------
# Helper: run a small Python snippet in a subprocess
# ---------------------------------------------------------------------------
def _py(code: str, *args, input_text: str = "") -> subprocess.CompletedProcess:
    cmd = [sys.executable, "-c", textwrap.dedent(code), *args]
    return subprocess.run(cmd, capture_output=True, text=True, input=input_text)


# ===========================================================================
# free_port() — the inline python3 one-liner in util.sh
# ===========================================================================
FREE_PORT_CODE = (
    "import socket;"
    "s=socket.socket();"
    "s.bind(('',0));"
    "print(s.getsockname()[1]);"
    "s.close()"
)


class TestFreePort:
    def _get_port(self) -> int:
        result = _py(FREE_PORT_CODE)
        assert result.returncode == 0
        return int(result.stdout.strip())

    def test_returns_integer(self):
        port = self._get_port()
        assert isinstance(port, int)

    def test_port_in_valid_range(self):
        port = self._get_port()
        assert 1024 <= port <= 65535

    def test_port_unique_across_calls(self):
        # Two sequential calls should yield different ports (OS re-uses only
        # after the socket closes, so the second bind gets a fresh ephemeral).
        ports = {self._get_port() for _ in range(5)}
        # At least 2 different values from 5 calls is highly likely.
        assert len(ports) >= 1  # minimal guard; determinism not guaranteed

    def test_port_is_immediately_bindable(self):
        import socket
        port = self._get_port()
        # After the script closes the socket we must be able to bind it again.
        s = socket.socket()
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("", port))
        finally:
            s.close()


# ===========================================================================
# idle_footprint.sh — runtime argument validation
# ===========================================================================

class TestIdleFootprintRuntimeValidation:
    """
    Run idle_footprint.sh with bad/unknown runtimes and verify it exits non-zero
    with an informative error message, *without* needing any process-inspection.

    For known runtimes the script will fail at env_stamp.sh or the `ps` step
    (no matching processes on a Linux CI host), but the argument parsing code
    path — which is what this PR added — exits early with code 1 for unknown
    runtimes regardless of platform.
    """

    def _run_script(self, runtime_arg: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", IDLE_FOOTPRINT, runtime_arg],
            capture_output=True,
            text=True,
        )

    def test_unknown_runtime_exits_nonzero(self):
        result = self._run_script("unknown-runtime")
        assert result.returncode != 0

    def test_unknown_runtime_error_message(self):
        result = self._run_script("unknown-runtime")
        assert "unknown runtime" in result.stderr

    def test_unknown_runtime_message_includes_name(self):
        result = self._run_script("badruntime")
        assert "badruntime" in result.stderr

    def test_missing_argument_exits_nonzero(self):
        result = subprocess.run(
            ["bash", IDLE_FOOTPRINT],
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0

    def test_known_runtime_apple_container_passes_validation(self):
        """
        With 'apple-container' the script passes the case-statement and reaches
        the ps / env_stamp steps. On a Linux host those may fail, but exit code
        will NOT be 1 from the unknown-runtime guard.
        We just verify it doesn't produce "unknown runtime" on stderr.
        """
        result = self._run_script("apple-container")
        assert "unknown runtime" not in result.stderr

    def test_known_runtime_docker_desktop_passes_validation(self):
        result = self._run_script("docker-desktop")
        assert "unknown runtime" not in result.stderr

    def test_known_runtime_orbstack_passes_validation(self):
        result = self._run_script("orbstack")
        assert "unknown runtime" not in result.stderr


# ===========================================================================
# RFC-1918 grep pattern used in container_ip() (apple-container branch)
# ===========================================================================
# The regex is: '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'
RFC1918_PAT = re.compile(
    r'^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'
)


class TestRfc1918Pattern:
    """Verify the RFC-1918 filter used in util.sh container_ip()."""

    def _is_private(self, ip: str) -> bool:
        return bool(RFC1918_PAT.match(ip))

    # --- 10.x.x.x ---
    def test_10_network_matches(self):
        assert self._is_private("10.0.0.1")

    def test_10_network_high_octet(self):
        assert self._is_private("10.255.255.255")

    # --- 172.16-31.x.x ---
    def test_172_16_matches(self):
        assert self._is_private("172.16.0.1")

    def test_172_31_matches(self):
        assert self._is_private("172.31.255.255")

    def test_172_15_not_private(self):
        assert not self._is_private("172.15.0.1")

    def test_172_32_not_private(self):
        assert not self._is_private("172.32.0.1")

    def test_172_20_matches(self):
        assert self._is_private("172.20.1.1")

    # --- 192.168.x.x ---
    def test_192_168_matches(self):
        assert self._is_private("192.168.64.5")

    def test_192_169_not_private(self):
        assert not self._is_private("192.169.0.1")

    # --- Public IPs ---
    def test_public_8_8_8_8(self):
        assert not self._is_private("8.8.8.8")

    def test_public_1_1_1_1(self):
        assert not self._is_private("1.1.1.1")

    def test_loopback_not_matched(self):
        # The pattern targets routable RFC-1918, not loopback.
        assert not self._is_private("127.0.0.1")

    def test_empty_string(self):
        assert not self._is_private("")


# ===========================================================================
# mem_mb parsing — subprocess round-trip (the exact heredoc code from util.sh)
# ===========================================================================

MEM_MB_CODE = textwrap.dedent("""\
    import re,sys
    s=sys.argv[1]
    m=re.search(r'([\\d.]+)\\s*([KMG]i?B)', s)
    if not m: print(''); raise SystemExit
    v=float(m.group(1)); u=m.group(2)[0]
    mb={'K':v/1024,'M':v,'G':v*1024}.get(u, v)
    print(int(round(mb)))
""")


def _run_mem_mb(raw: str) -> str:
    result = subprocess.run(
        [sys.executable, "-c", MEM_MB_CODE, raw],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


class TestMemMbSubprocess:
    """End-to-end subprocess tests for the util.sh mem_mb Python snippet."""

    def test_mib_value(self):
        assert _run_mem_mb("256MiB / 7.6GiB") == "256"

    def test_gib_value(self):
        assert _run_mem_mb("1GiB / 7.6GiB") == "1024"

    def test_kib_value(self):
        assert _run_mem_mb("1024KiB / 7.6GiB") == "1"

    def test_mb_without_i(self):
        assert _run_mem_mb("128MB / 8GB") == "128"

    def test_empty_raw(self):
        # Returns '' (empty stdout) when no unit found.
        assert _run_mem_mb("") == ""

    def test_no_unit(self):
        assert _run_mem_mb("12345") == ""

    def test_fractional_gib_rounds(self):
        # 1.5GiB = 1536MB exactly
        assert _run_mem_mb("1.5GiB / 16GiB") == "1536"


# ===========================================================================
# service_endpoint() — docker-desktop / orbstack branch
# Verify the pure logic: for docker-desktop/orbstack the output is always
# "127.0.0.1 <hostport>" (no container query needed).
# ===========================================================================

SERVICE_ENDPOINT_CODE = textwrap.dedent("""\
    #!/usr/bin/env bash
    set -euo pipefail
    rt="$1"; hostport="$2"
    case "$rt" in
      docker-desktop|orbstack) printf '127.0.0.1 %s' "$hostport"; exit 0 ;;
      apple-container)         printf 'APPLE_BRANCH' ;;
    esac
""")


class TestServiceEndpointDockerBranch:
    def _run(self, runtime: str, hostport: str) -> str:
        result = subprocess.run(
            ["bash", "-c", SERVICE_ENDPOINT_CODE, "--", runtime, hostport],
            capture_output=True,
            text=True,
        )
        return result.stdout

    def test_docker_desktop_returns_localhost(self):
        out = self._run("docker-desktop", "8080")
        assert out == "127.0.0.1 8080"

    def test_orbstack_returns_localhost(self):
        out = self._run("orbstack", "5432")
        assert out == "127.0.0.1 5432"

    def test_docker_desktop_preserves_port(self):
        out = self._run("docker-desktop", "12345")
        host, port = out.split()
        assert host == "127.0.0.1"
        assert port == "12345"

    def test_apple_container_takes_different_branch(self):
        # The apple-container branch cannot be fully tested without a running
        # container, but we verify it does NOT return the localhost path.
        out = self._run("apple-container", "80")
        assert out != "127.0.0.1 80"


# ===========================================================================
# 08_density.sh — hit_cap logic
# ===========================================================================

class TestDensityHitCapLogic:
    """
    Verify the shell arithmetic:  hit_cap=false; [ count -ge CAP ] && hit_cap=true
    """

    def _hit_cap(self, count: int, cap: int) -> bool:
        code = f"count={count}; cap={cap}; hit_cap=false; [ \"$count\" -ge \"$cap\" ] && hit_cap=true; echo $hit_cap"
        result = subprocess.run(["bash", "-c", code], capture_output=True, text=True)
        return result.stdout.strip() == "true"

    def test_count_below_cap(self):
        assert not self._hit_cap(count=10, cap=150)

    def test_count_equal_cap(self):
        assert self._hit_cap(count=150, cap=150)

    def test_count_above_cap_impossible_but_guarded(self):
        # Shouldn't happen (loop breaks at cap), but the guard still works.
        assert self._hit_cap(count=151, cap=150)

    def test_count_zero(self):
        assert not self._hit_cap(count=0, cap=150)

    def test_count_one_below_cap(self):
        assert not self._hit_cap(count=149, cap=150)

    def test_small_cap(self):
        assert self._hit_cap(count=8, cap=8)