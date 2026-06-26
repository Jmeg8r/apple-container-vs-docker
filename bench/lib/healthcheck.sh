#!/usr/bin/env bash
# WHAT: Poll-to-ready helpers. Measure time from `run` to first USABLE response.
# WHY:  "Container started" is not the same as "service is ready". We always
#       measure time-to-first-healthy so the comparison reflects real usability.
set -euo pipefail

# Poll a TCP port until it accepts a connection or we time out. Echo nothing;
# return 0 on success, 1 on timeout. Caller times the call.
wait_tcp() {
  local host="$1" port="$2" timeout="${3:-30}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if nc -z -G1 "$host" "$port" 2>/dev/null; then return 0; fi
  done
  return 1
}

# Poll an HTTP endpoint until it returns 200.
wait_http_200() {
  local url="$1" timeout="${2:-30}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" = "200" ]; then
      return 0
    fi
  done
  return 1
}

# High-resolution wall clock in milliseconds (no Date.now in shell, use python).
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
