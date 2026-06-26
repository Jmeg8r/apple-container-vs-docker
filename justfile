# Benchmark task runner. `just` = list recipes.
# Install just: brew install just

reps := "10"
runtimes := "apple-container docker-desktop orbstack"
scenarios := "00_baseline"   # add 01_nginx 02_postgres ... as scenarios land

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
