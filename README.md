# apple-container-vs-docker

A **reproducible, real-data benchmark** comparing three ways to run Linux containers
on an Apple Silicon Mac:

| Runtime | CLI | Model | Compose | DevContainers |
|---------|-----|-------|---------|---------------|
| **Apple `container`** v1.0 | `container` | one lightweight VM **per container** | ❌ (3rd-party bridges only) | ⚠️ incomplete |
| **Docker Desktop** | `docker` | one shared VM | ✅ | ✅ |
| **OrbStack** | `docker` | one shared lightweight VM | ✅ | ✅ |

This repo backs the ASTGL tutorial *"Apple Container vs Docker: when to use which on
Apple Silicon."* **Every claim in the article traces to a number or a logged failure
in `results/`.** No vibes.

> ⚠️ OrbStack and Docker Desktop both expose the `docker` CLI and **cannot run at the
> same time**. The harness switches the active engine between runs and stamps which one
> served each result.

## Test environment (the reference run)

Captured automatically into every result file by `bench/env_stamp.sh`. The reference
machine for the published article:

- **macOS 26.5.1 (Tahoe, build 25F80)** — full container networking (matters: macOS 15
  cannot do container-to-container networking with Apple `container`)
- **Apple M3 Ultra, 256 GB RAM** (Mac Studio)
- Docker 29.3.1 / Compose v5.1.0 · OrbStack `<tbd>` · Apple `container` `<tbd>`

## Methodology — the fairness controls

These are the controls that separate a real benchmark from a screenshot of one run:

1. **Images pinned by digest** (`images/manifests.lock`) — all runtimes pull identical
   OCI bytes.
2. **Versions + macOS build + chip + thermal state stamped into every result** for
   reproducibility.
3. **Cold vs warm reported separately** — never blended.
4. **N ≥ 10 reps; warmup run discarded; report median + p95 + stdev** — never a single
   cherry-picked number.
5. **Subprocess isolation per run** — clean child process per measurement, state torn
   down between reps (lesson from the DiffusionGemma harness: in-process state
   accumulation silently corrupts results).
6. **Resource-model asymmetry documented, not hidden** — Docker Desktop & OrbStack run a
   *shared* VM with a fixed CPU/RAM budget; Apple `container` runs a VM *per container*.
   We record each engine's allocated resources and call the asymmetry out.

## Scenarios

| # | Scenario | Isolates |
|---|----------|----------|
| 0 | `alpine` true | VM spin-up + teardown overhead (baseline) |
| 1 | `nginx` → first HTTP 200 | time-to-usable, simple service |
| 2 | `postgres:16` → `pg_isready` | time-to-usable + steady RAM, stateful service |
| 3 | `sysbench` CPU | per-VM CPU overhead |
| 4 | `fio` on a bind-mounted dir | Mac file-sync I/O (the dev-loop pain point) |
| 5 | `iperf3` host↔ctr & ctr↔ctr | network throughput + macOS 26 multi-net path |
| 6 | multi-stage Node+Go build | build speed + cache behavior |
| 7 | Postgres + Redis + web app | the real dev workload + the DX-tax (command count) |
| 8 | density ramp | how many containers before failure (256 GB headroom) |

Plus an **idle-footprint** measurement (nothing running) and a **feature-compatibility
matrix** filled in as we hit each gap.

## Quick start

```bash
just doctor        # verify which runtimes are installed + active
just bench-all     # run every scenario across every available runtime → results/raw/
just report        # aggregate JSONL → stats → PNG charts in results/charts/
```

Charts are emitted as **PNG** (Substack renders markdown tables badly — ASTGL house rule).

## Layout

```
bench/
  runner.sh            (runtime, scenario, reps) → JSONL, subprocess-isolated
  env_stamp.sh         machine/version/thermal stamp
  lib/runtime.sh       adapter: maps runtime → CLI + "ensure engine active"
  lib/healthcheck.sh   poll-to-ready helpers (TCP / pg_isready / curl 200)
  scenarios/           one script per workload 0–8
images/manifests.lock  pinned image digests
analysis/collect.py    JSONL → stats (median/p95/stdev)
analysis/report.py     stats → PNG charts + feature-matrix PNG
results/{raw,charts}/
article/               git-ignored draft for Substack
```

## License

MIT © James Cruce ([Jmeg8r](https://github.com/Jmeg8r))
