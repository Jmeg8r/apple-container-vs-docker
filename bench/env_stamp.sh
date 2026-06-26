#!/usr/bin/env bash
# WHAT: Emit a JSON object describing the host + tool versions + thermal state.
# WHY:  Every result file embeds this so any run is reproducible and comparable.
#       A benchmark number without its environment is noise.
set -euo pipefail

ver() { command -v "$1" >/dev/null 2>&1 && "$@" 2>/dev/null | head -n1 || echo "absent"; }

# Thermal pressure tells us whether the machine was throttling during a run.
thermal="$(pmset -g therm 2>/dev/null | awk -F': ' '/CPU_Speed_Limit/{print $2}' | tr -d ' ')"
[ -z "${thermal}" ] && thermal="100"

cat <<JSON
{
  "captured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "macos": "$(sw_vers -productVersion) ($(sw_vers -buildVersion))",
  "chip": "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)",
  "ram_gb": $(sysctl -n hw.memsize | awk '{printf "%d", $1/1073741824}'),
  "cpu_speed_limit_pct": ${thermal},
  "versions": {
    "container": "$(ver container --version)",
    "docker": "$(ver docker --version)",
    "compose": "$(ver docker compose version)",
    "orbstack": "$(ver orbctl version)"
  }
}
JSON
