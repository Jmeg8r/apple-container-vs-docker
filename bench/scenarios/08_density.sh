#!/usr/bin/env bash
# Scenario 8 — container density: spawn lightweight containers until one fails or
# we hit DENSITY_CAP. Apple's one-VM-per-container model is expected to top out
# sooner than the shared-VM runtimes; 256 GB RAM gives plenty of headroom to find
# the real ceiling. CAP is a runaway guard — if we hit it, that's reported, not
# treated as "infinite".
set -euo pipefail
source "${ROOT}/bench/lib/healthcheck.sh"
source "${ROOT}/bench/lib/runtime.sh"

IMG="docker.io/library/alpine:3.20"
CAP="${DENSITY_CAP:-150}"
PREFIX="dens-$$"
cleanup() {
  ids="$("$CLI" list --all --quiet 2>/dev/null | grep "$PREFIX" || \
         "$CLI" ps -aq --filter "name=${PREFIX}" 2>/dev/null || true)"
  for n in $("$CLI" ps -a --format '{{.Names}}' 2>/dev/null | grep "$PREFIX" || true); do runtime_rm "$RUNTIME" "$n"; done
  # Apple `container` lists by name; remove any we created.
  for i in $(seq 1 "$CAP"); do runtime_rm "$RUNTIME" "${PREFIX}-${i}" 2>/dev/null || true; done
}
trap cleanup EXIT

t0="$(now_ms)"; count=0
for i in $(seq 1 "$CAP"); do
  if "$CLI" run -d --name "${PREFIX}-${i}" "$IMG" sleep 600 >/dev/null 2>&1; then
    count=$((count+1))
  else
    break   # first failure = the ceiling for this run
  fi
done
t1="$(now_ms)"

hit_cap=false; [ "$count" -ge "$CAP" ] && hit_cap=true
printf '{"max_containers": %d, "hit_cap": %s, "time_to_ceiling_ms": %d}\n' \
  "$count" "$hit_cap" "$((t1 - t0))"
