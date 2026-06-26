#!/usr/bin/env bash
# WHAT: Scenario 0 — pure VM spin-up + teardown overhead.
#       Run `alpine` doing nothing, measure cold-ish start + teardown.
# WHY:  This is the floor. Everything else builds on how fast a runtime can
#       create and destroy a container with zero workload inside it.
# CONTRACT: scenarios receive $CLI, $RUNTIME, $ROOT in the env and must print a
#       single JSON object of metrics (milliseconds) to stdout. Nothing else.
set -euo pipefail
source "${ROOT}/bench/lib/healthcheck.sh"
source "${ROOT}/bench/lib/runtime.sh"
source "${ROOT}/bench/lib/util.sh"

# Digest-pinned (Apple `container` also requires registry-qualified names).
IMG="$(img alpine)"
NAME="bench-baseline-$$"

start="$(now_ms)"
"$CLI" run --name "$NAME" --rm "$IMG" true
end="$(now_ms)"

# Teardown timing (the --rm above already removed it; this guarantees cleanliness).
td_start="$(now_ms)"
runtime_rm "$RUNTIME" "$NAME"
td_end="$(now_ms)"

printf '{"start_to_exit_ms": %d, "teardown_ms": %d}\n' \
  "$((end - start))" "$((td_end - td_start))"
