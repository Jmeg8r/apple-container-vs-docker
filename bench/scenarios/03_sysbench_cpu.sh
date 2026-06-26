#!/usr/bin/env bash
# Scenario 3 — CPU throughput inside a container (sysbench).
# Tests whether the per-VM model (Apple) carries CPU overhead vs a shared VM.
# Requires the benchbox image: `just build-images`.
set -euo pipefail
source "${ROOT}/bench/lib/runtime.sh"

IMG="benchbox:latest"
THREADS=4; SECONDS_RUN=10

out="$("$CLI" run --rm "$IMG" \
        sysbench cpu --threads="$THREADS" --time="$SECONDS_RUN" run 2>/dev/null)" \
  || { echo '{"error":"sysbench run failed (benchbox built?)"}'; exit 0; }

# "events per second:  1234.56"  → higher is better.
eps="$(printf '%s' "$out" | awk -F: '/events per second/{gsub(/ /,"",$2);print $2}')"
[ -z "$eps" ] && { echo '{"error":"could not parse sysbench output"}'; exit 0; }

printf '{"cpu_events_per_sec": %s}\n' "$eps"
