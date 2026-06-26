#!/usr/bin/env bash
# Scenario 7 — the real dev workload: Postgres + Redis on a shared network,
# brought up the MANUAL way (the only way Apple `container` can — no native
# Compose). Measures time-to-stack-ready and records the command count, which is
# the DX-tax the article contrasts against `docker compose up` (one command).
set -euo pipefail
source "${ROOT}/bench/lib/healthcheck.sh"
source "${ROOT}/bench/lib/runtime.sh"
source "${ROOT}/bench/lib/util.sh"

NET="benchstack-$$"
PG="stack-pg-$$"; RD="stack-redis-$$"
PG_PORT="$(free_port)"; RD_PORT="$(free_port)"
cleanup() { runtime_rm "$RUNTIME" "$PG"; runtime_rm "$RUNTIME" "$RD"; "$CLI" network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Count every CLI invocation needed to stand the stack up (the manual DX cost).
cmds=0
t0="$(now_ms)"
"$CLI" network create "$NET" >/dev/null 2>&1 || { echo '{"error":"network create failed"}'; exit 0; }; cmds=$((cmds+1))
"$CLI" run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD=bench -p "${PG_PORT}:5432" "$(img postgres)" >/dev/null || { echo '{"error":"postgres failed"}'; exit 0; }; cmds=$((cmds+1))
"$CLI" run -d --name "$RD" --network "$NET" -p "${RD_PORT}:6379" "$(img redis)" >/dev/null || { echo '{"error":"redis failed"}'; exit 0; }; cmds=$((cmds+1))

# Stack is "ready" when BOTH services accept connections (each reached natively).
read -r pg_host pg_p <<<"$(service_endpoint "$RUNTIME" "$PG" 5432 "$PG_PORT")"
read -r rd_host rd_p <<<"$(service_endpoint "$RUNTIME" "$RD" 6379 "$RD_PORT")"
{ [ -z "$pg_host" ] || [ -z "$rd_host" ]; } && { echo '{"error":"could not resolve endpoints"}'; exit 0; }
wait_tcp "$pg_host" "$pg_p" 60 || { echo '{"error":"postgres never ready"}'; exit 0; }
wait_tcp "$rd_host" "$rd_p" 30 || { echo '{"error":"redis never ready"}'; exit 0; }
t1="$(now_ms)"

printf '{"run_to_stack_ready_ms": %d, "manual_command_count": %d}\n' "$((t1 - t0))" "$cmds"
