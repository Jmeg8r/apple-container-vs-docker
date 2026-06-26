#!/usr/bin/env bash
# Scenario 6 — multi-stage image build (Go), cold (no cache) and warm (cached).
# Measures build engine speed and cache effectiveness across runtimes.
set -euo pipefail
source "${ROOT}/bench/lib/healthcheck.sh"
source "${ROOT}/bench/lib/runtime.sh"

CTX="${ROOT}/bench/images/sampleapp"
TAG="sampleapp-bench:$$"

t0="$(now_ms)"
"$CLI" build --no-cache -t "$TAG" "$CTX" >/dev/null 2>&1 \
  || { echo '{"error":"cold build failed"}'; exit 0; }
t1="$(now_ms)"
# Warm build: same context, cache populated by the cold build above.
"$CLI" build -t "$TAG" "$CTX" >/dev/null 2>&1 \
  || { echo '{"error":"warm build failed"}'; exit 0; }
t2="$(now_ms)"

# Best-effort image cleanup (image rm flag parity varies; ignore errors).
"$CLI" image rm "$TAG" >/dev/null 2>&1 || "$CLI" rmi "$TAG" >/dev/null 2>&1 || true

printf '{"build_nocache_ms": %d, "build_cached_ms": %d}\n' "$((t1 - t0))" "$((t2 - t1))"
