#!/usr/bin/env bash
# WHAT: Measure host memory held by a runtime's helper processes AT IDLE (no
#       containers running). This is the footprint you "pay" just for having the
#       runtime installed and ready — a known Apple `container` advantage to confirm.
# WHY:  Docker Desktop & OrbStack keep a VM + daemons resident; Apple `container`
#       tears VMs down with their containers, so its idle cost should be lower.
# NOTE: Best-effort attribution by process-name match. Documented as such in README.
#       Usage: idle_footprint.sh <apple-container|docker-desktop|orbstack>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RT="${1:?runtime required}"
case "$RT" in
  apple-container) pat='container-apiserver|container-core' ;;
  docker-desktop)  pat='com.docker|Docker Desktop|vpnkit' ;;
  orbstack)        pat='OrbStack|orbstack-helper|xbin/server' ;;
  *) echo "unknown runtime '$RT'" >&2; exit 1 ;;
esac

# Sum RSS (KB) of matching processes; convert to MB. ps RSS is in KB on macOS.
rss_kb="$(ps -axo rss,command | grep -iE "$pat" | grep -v grep \
          | awk '{sum+=$1} END{print sum+0}')"
mb=$(( rss_kb / 1024 ))
procs="$(ps -axo command | grep -iE "$pat" | grep -vc grep || true)"

env_stamp="$(bash "${ROOT}/bench/env_stamp.sh")"
python3 - "$RT" "$mb" "$procs" "$env_stamp" <<'PY'
import json, sys
rt, mb, procs, env = sys.argv[1:5]
print(json.dumps({"scenario": "idle_footprint", "runtime": rt,
                  "kind": "rep", "status": "ok",
                  "metrics": {"idle_helper_rss_mb": int(mb), "helper_proc_count": int(procs)},
                  "env": json.loads(env)}))
PY
