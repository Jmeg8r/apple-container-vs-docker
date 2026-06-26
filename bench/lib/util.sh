#!/usr/bin/env bash
# WHAT: Cross-runtime helpers used by scenarios. Defensive by design — secondary
#       metrics (IP, memory) return empty on failure so a scenario still reports
#       its PRIMARY timing metric rather than crashing the whole rep.
# WHY:  Apple `container` and Docker differ in inspect/stats output shape. We never
#       let a parsing quirk in a nice-to-have metric nuke a measurement.
set -euo pipefail

# Pick an unused TCP port on the host (avoids collisions between sequential runs).
free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("",0));print(s.getsockname()[1]);s.close()'
}

# Best-effort container IP. Docker exposes it via inspect templating; Apple
# `container` returns JSON we scrape for the first private address. Empty on miss.
container_ip() {
  local rt="$1" name="$2" cli ip; cli="$(runtime_cli "$rt")"
  case "$rt" in
    docker-desktop|orbstack)
      ip="$("$cli" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null)"
      ;;
    apple-container)
      # inspect shape isn't guaranteed stable; grep the first RFC1918 address.
      ip="$("$cli" inspect "$name" 2>/dev/null \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
            | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)"
      ;;
  esac
  printf '%s' "${ip:-}"
}

# Echo "<host> <port>" to reach a service, using each runtime's NATIVE access model:
#   - Docker Desktop / OrbStack publish ports to localhost  → 127.0.0.1:<hostport>
#   - Apple `container` gives each container a routable IP   → <ip>:<containerport>
# (Apple's `-p` publish is unreliable in v1.0; the routable IP is the real interface.)
# Retries until Apple's IP is assigned. Echoes empty host on failure.
service_endpoint() {
  local rt="$1" name="$2" cport="$3" hostport="${4:-}"
  case "$rt" in
    docker-desktop|orbstack) printf '127.0.0.1 %s' "$hostport"; return 0 ;;
    apple-container)
      local ip=""
      for _ in $(seq 1 40); do
        ip="$(container_ip "$rt" "$name")"; [ -n "$ip" ] && break
        python3 -c 'import time;time.sleep(0.25)'
      done
      printf '%s %s' "${ip}" "$cport"
      ;;
  esac
}

# Best-effort steady memory of a container in MB (integer). Empty on failure.
# Parses the first number out of stats' MemUsage column ("12.3MiB / 7.6GiB").
mem_mb() {
  local rt="$1" name="$2" cli raw; cli="$(runtime_cli "$rt")"
  raw="$("$cli" stats --no-stream --format '{{.MemUsage}}' "$name" 2>/dev/null | head -1)" || raw=""
  [ -z "$raw" ] && { printf ''; return 0; }
  python3 - "$raw" <<'PY' 2>/dev/null || printf ''
import re,sys
s=sys.argv[1]
m=re.search(r'([\d.]+)\s*([KMG]i?B)', s)
if not m: print(''); raise SystemExit
v=float(m.group(1)); u=m.group(2)[0]
mb={'K':v/1024,'M':v,'G':v*1024}.get(u, v)
print(int(round(mb)))
PY
}
