#!/usr/bin/env bash
# Scenario 4 — disk I/O on a HOST bind mount (the Mac dev-loop pain point).
# Docker Desktop's bind mounts historically suffer on macOS via the file-sync
# layer; this measures whether Apple `container` / OrbStack do better.
# Requires the benchbox image: `just build-images`.
set -euo pipefail
source "${ROOT}/bench/lib/runtime.sh"

IMG="benchbox:latest"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/fiobench.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# Random-write over a bind-mounted host dir; buffered (virtiofs may reject O_DIRECT).
out="$("$CLI" run --rm -v "${SCRATCH}:/data" "$IMG" \
        fio --name=w --rw=randwrite --bs=4k --size=64M --numjobs=1 \
            --runtime=10 --time_based --directory=/data \
            --ioengine=psync --output-format=json 2>/dev/null)" \
  || { echo '{"error":"fio run failed (benchbox built? bind mount supported?)"}'; exit 0; }

# Parse IOPS + bandwidth (KB/s → MB/s) from fio JSON.
metrics="$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); w=d["jobs"][0]["write"]
    print(json.dumps({"write_iops": round(w["iops"],1),
                      "write_bw_mbps": round(w["bw"]/1024,1)}))
except Exception:
    print("")
' 2>/dev/null)"
[ -z "$metrics" ] && { echo '{"error":"could not parse fio json"}'; exit 0; }
echo "$metrics"
