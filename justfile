# Benchmark task runner. `just` = list recipes.
# Install just: brew install just

reps := "10"
runtimes := "apple-container docker-desktop orbstack"
scenarios := "00_baseline 01_nginx 02_postgres 03_sysbench_cpu 04_fio_bindmount 05_iperf3 06_build 07_stack 08_density"

# Show which runtimes are installed and which docker engine is currently active.
doctor:
    @echo "== installed =="
    @command -v container >/dev/null && container --version || echo "apple container: ABSENT"
    @command -v docker >/dev/null && docker --version || echo "docker: ABSENT"
    @command -v orbctl >/dev/null && orbctl version 2>/dev/null | head -1 || echo "orbstack: ABSENT"
    @echo "== active docker engine =="
    @docker info --format '{{{{.Name}}' 2>/dev/null || echo "(docker daemon not reachable)"
    @echo "== env stamp =="
    @bash bench/env_stamp.sh

# Build the shared benchbox + sampleapp images on every runtime (own image store each).
# Scenarios 03/04/05 need benchbox; 06 builds sampleapp itself.
build-images:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{runtimes}}; do
      echo ">> building benchbox on $r"
      case "$r" in
        apple-container) cli=container ;;
        docker-desktop)  cli=docker; docker context use desktop-linux >/dev/null ;;
        orbstack)        cli=docker; docker context use orbstack >/dev/null ;;
      esac
      "$cli" build -t benchbox:latest bench/images/benchbox || echo "  benchbox build FAILED on $r"
    done

# Measure idle helper-process footprint for every runtime → results/raw/idle_footprint__*.jsonl
idle:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p results/raw
    for r in {{runtimes}}; do
      bash bench/idle_footprint.sh "$r" > "results/raw/idle_footprint__${r}.jsonl" && echo "idle: $r"
    done

# Run one scenario on one runtime.
bench runtime scenario reps=reps:
    bash bench/runner.sh {{runtime}} {{scenario}} {{reps}}

# Run every scenario across every runtime.
bench-all:
    #!/usr/bin/env bash
    set -euo pipefail
    for s in {{scenarios}}; do
      for r in {{runtimes}}; do
        echo ">> $s on $r"
        bash bench/runner.sh "$r" "$s" {{reps}} || true
      done
    done

# One-time: create the analysis venv and install charting deps.
setup-analysis:
    python3 -m venv .venv
    .venv/bin/pip install -q -r analysis/requirements.txt
    @echo "analysis venv ready (.venv)"

# Aggregate raw JSONL → stats.json, then render PNG charts.
# Uses the project venv if present (matplotlib lives there), else system python3.
report:
    #!/usr/bin/env bash
    set -euo pipefail
    py=python3; [ -x .venv/bin/python3 ] && py=.venv/bin/python3
    "$py" analysis/collect.py
    "$py" analysis/report.py

# Wipe results (keep .gitkeep dirs).
clean:
    rm -f results/raw/*.jsonl results/stats.json results/charts/*.png
