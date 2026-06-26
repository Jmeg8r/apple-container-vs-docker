#!/usr/bin/env bash
# Scenario 5 — container-to-container network throughput (iperf3).
# This exercises the macOS 26 multi-network path that does NOT work on macOS 15
# for Apple `container`. Server + client are separate containers on one network.
# Requires the benchbox image: `just build-images`.
set -euo pipefail
source "${ROOT}/bench/lib/runtime.sh"
source "${ROOT}/bench/lib/healthcheck.sh"
source "${ROOT}/bench/lib/util.sh"

IMG="benchbox:latest"
NET="benchnet-$$"; SRV="iperf-srv-$$"
cleanup() { runtime_rm "$RUNTIME" "$SRV"; "$CLI" network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

"$CLI" network create "$NET" >/dev/null 2>&1 || { echo '{"error":"network create failed"}'; exit 0; }
"$CLI" run -d --name "$SRV" --network "$NET" "$IMG" iperf3 -s >/dev/null \
  || { echo '{"error":"iperf3 server failed to start"}'; exit 0; }

# Resolve the server IP and wait for it to listen.
ip=""; for _ in $(seq 1 20); do ip="$(container_ip "$RUNTIME" "$SRV")"; [ -n "$ip" ] && break; python3 -c 'import time;time.sleep(0.5)'; done
[ -z "$ip" ] && { echo '{"error":"could not resolve server IP (container-to-container unsupported?)"}'; exit 0; }

out="$("$CLI" run --rm --network "$NET" "$IMG" iperf3 -c "$ip" -t 5 -J 2>/dev/null)" \
  || { echo '{"error":"iperf3 client failed (no container-to-container path?)"}'; exit 0; }

mbps="$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(round(d["end"]["sum_received"]["bits_per_second"]/1e6,1))
except Exception: print("")
' 2>/dev/null)"
[ -z "$mbps" ] && { echo '{"error":"could not parse iperf3 json"}'; exit 0; }
printf '{"net_throughput_mbps": %s}\n' "$mbps"
