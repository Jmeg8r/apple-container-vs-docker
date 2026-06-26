#!/usr/bin/env bash
# Scenario 1 — time from `run` to first HTTP 200 from nginx.
# Measures time-to-usable for a simple stateless service. Each runtime is reached
# its native way (Docker/OrbStack: published localhost port; Apple: routable IP).
set -euo pipefail
source "${ROOT}/bench/lib/healthcheck.sh"
source "${ROOT}/bench/lib/runtime.sh"
source "${ROOT}/bench/lib/util.sh"

IMG="$(img nginx)"
NAME="bench-nginx-$$"; PORT="$(free_port)"
trap 'runtime_rm "$RUNTIME" "$NAME"' EXIT

t0="$(now_ms)"
"$CLI" run -d --name "$NAME" -p "${PORT}:80" "$IMG" >/dev/null
read -r host hport <<<"$(service_endpoint "$RUNTIME" "$NAME" 80 "$PORT")"
[ -z "$host" ] && { echo '{"error":"could not resolve service endpoint"}'; exit 0; }
wait_http_200 "http://${host}:${hport}/" 60 || { echo '{"error":"nginx never returned 200"}'; exit 0; }
t1="$(now_ms)"

printf '{"run_to_http200_ms": %d}\n' "$((t1 - t0))"
