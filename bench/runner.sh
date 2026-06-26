#!/usr/bin/env bash
# WHAT: Top-level benchmark runner.
#       Usage: runner.sh <runtime> <scenario> [reps]
#       e.g.   runner.sh apple-container 00_baseline 10
# WHY:  One entry point that enforces every fairness control in one place:
#       engine activation, env stamping, subprocess isolation, warmup discard,
#       and structured JSONL output. Scenarios stay dumb; the runner is the brain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/bench/lib/runtime.sh"
source "${ROOT}/bench/lib/healthcheck.sh"

RUNTIME="${1:?runtime required (apple-container|docker-desktop|orbstack)}"
SCENARIO="${2:?scenario required (e.g. 00_baseline)}"
REPS="${3:-10}"
SCRIPT="${ROOT}/bench/scenarios/${SCENARIO}.sh"
OUT="${ROOT}/results/raw/${SCENARIO}__${RUNTIME}.jsonl"

[ -f "$SCRIPT" ] || { echo "no such scenario: $SCRIPT" >&2; exit 1; }
mkdir -p "${ROOT}/results/raw"

# Activate + verify the intended engine, or record a skip and bail honestly.
if ! err="$(runtime_activate "$RUNTIME" 2>&1)"; then
  echo "{\"scenario\":\"${SCENARIO}\",\"runtime\":\"${RUNTIME}\",\"status\":\"skipped\",\"reason\":$(printf '%s' "$err" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')}" >> "$OUT"
  echo "SKIP ${SCENARIO}/${RUNTIME}: ${err}" >&2
  exit 0
fi

ENV_STAMP="$(bash "${ROOT}/bench/env_stamp.sh")"

# rep 0 is a discarded warmup; reps 1..REPS are recorded.
for i in $(seq 0 "$REPS"); do
  label="rep"; [ "$i" -eq 0 ] && label="warmup"
  # Subprocess isolation: each rep is a clean child process. State from one rep
  # cannot bleed into the next (DiffusionGemma harness lesson).
  result_json="$(
    CLI="$(runtime_cli "$RUNTIME")" \
    RUNTIME="$RUNTIME" ROOT="$ROOT" \
    bash "$SCRIPT" 2>/dev/null
  )" || result_json='{"error":"scenario failed"}'

  python3 - "$SCENARIO" "$RUNTIME" "$i" "$label" "$result_json" "$ENV_STAMP" >> "$OUT" <<'PY'
import json, sys
scenario, runtime, idx, label, result, env = sys.argv[1:7]
try:    result = json.loads(result)
except Exception: result = {"raw": result}
print(json.dumps({
    "scenario": scenario, "runtime": runtime,
    "rep": int(idx), "kind": label, "status": "ok",
    "metrics": result, "env": json.loads(env),
}))
PY
done

echo "wrote ${OUT}"
