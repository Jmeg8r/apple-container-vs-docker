#!/usr/bin/env bash
# Scenario 2 — time from `run` to Postgres accepting TCP, plus steady memory.
# Measures time-to-usable for a stateful service and its resident footprint.
set -euo pipefail
source "${ROOT}/bench/lib/healthcheck.sh"
source "${ROOT}/bench/lib/runtime.sh"
source "${ROOT}/bench/lib/util.sh"

IMG="$(img postgres)"
NAME="bench-pg-$$"; PORT="$(free_port)"
trap 'runtime_rm "$RUNTIME" "$NAME"' EXIT

t0="$(now_ms)"
"$CLI" run -d --name "$NAME" -e POSTGRES_PASSWORD=bench -p "${PORT}:5432" "$IMG" >/dev/null
read -r host hport <<<"$(service_endpoint "$RUNTIME" "$NAME" 5432 "$PORT")"
[ -z "$host" ] && { echo '{"error":"could not resolve service endpoint"}'; exit 0; }
wait_tcp "$host" "$hport" 60 || { echo '{"error":"postgres never accepted TCP"}'; exit 0; }
t1="$(now_ms)"

# Let it settle briefly, then sample resident memory (best-effort; may be null).
python3 -c 'import time;time.sleep(2)'
mem="$(mem_mb "$RUNTIME" "$NAME")"

if [ -n "$mem" ]; then
  printf '{"run_to_tcp_ms": %d, "steady_mem_mb": %d}\n' "$((t1 - t0))" "$mem"
else
  printf '{"run_to_tcp_ms": %d}\n' "$((t1 - t0))"
fi
