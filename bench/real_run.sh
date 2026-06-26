#!/usr/bin/env bash
# WHAT: The article's data run. Every scenario × every runtime at tuned rep counts,
#       scenario-outer/runtime-inner so each scenario's three runtimes run back-to-back
#       under similar thermal/cache conditions. Plus repeated idle-footprint samples.
# WHY:  One reproducible command produces the full dataset. NOT -e: an individual
#       rep/runtime failure is logged and the run continues (failures are data).
# USAGE: bash bench/real_run.sh   (DENSITY_CAP defaults to 40 to be gentle on the host)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LOG="results/real_run.log"; mkdir -p results
RUNTIMES="apple-container docker-desktop orbstack"
export DENSITY_CAP="${DENSITY_CAP:-40}"

log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

# scenario -> rep count (heavy scenarios get fewer reps).
declare -a PLAN=(
  "00_baseline:12" "01_nginx:12" "02_postgres:12"
  "03_sysbench_cpu:10" "04_fio_bindmount:10" "05_iperf3:10"
  "06_build:6" "07_stack:12" "08_density:3"
)

log "REAL RUN START (density cap=${DENSITY_CAP})"
for entry in "${PLAN[@]}"; do
  s="${entry%%:*}"; reps="${entry##*:}"
  for rt in $RUNTIMES; do
    log ">> ${s} on ${rt} (reps=${reps})"
    bash bench/runner.sh "$rt" "$s" "$reps" >>"$LOG" 2>&1 \
      || log "   !! ${s}/${rt} runner exited nonzero"
  done
done

# Idle footprint: 5 samples per runtime (snapshot metric; sample for stability).
log ">> idle_footprint x5 per runtime"
for rt in $RUNTIMES; do
  : > "results/raw/idle_footprint__${rt}.jsonl"
  for _ in 1 2 3 4 5; do
    bash bench/idle_footprint.sh "$rt" >> "results/raw/idle_footprint__${rt}.jsonl" 2>>"$LOG" || true
    python3 -c 'import time;time.sleep(1)'
  done
done

log "REAL RUN COMPLETE"
