# Findings

Reference rig: **M3 Ultra / 256 GB / macOS 26.5.1 (Tahoe)**. Apple `container` 1.0.0,
Docker Desktop 29.3.1, OrbStack 2.2.1. Run date: **2026-06-26**.

All images digest-pinned (`images/manifests.lock`). Every number below is the **median
of N≥10 reps** (warmup discarded, subprocess-isolated). Reproduce with `just bench-all`
then `bench/real_run.sh`. Charts in `results/charts/`.

## Behavioral facts (verified by hand)

- **Apple `container` requires fully-qualified image refs.** `container run alpine`
  fails; `docker.io/library/alpine:3.20` works. It accepts multi-arch **index-digest**
  refs and selects arm64 correctly.
- **Apple `container` does not use the publish-to-localhost model.** Its `-p` is
  unreliable in v1.0 (nginx's published port stayed closed while postgres's opened);
  the real interface is each container's **routable IP** (`192.168.64.x`), reachable
  directly from the host.
- **Docker Desktop does NOT route container IPs to the host;** OrbStack and Apple
  `container` do. (This broke a host-side readiness probe in scenario 5 — fixed by
  probing from inside the container network.)
- **`localhost` vs `127.0.0.1` matters** — `localhost` can resolve to IPv6 `::1` first,
  which published IPv4 ports don't answer.
- **No native Compose on Apple `container`.** Standing up Postgres+Redis is a manual
  `network create` + N×`run` (3 commands; scenario 7). Docker/OrbStack do it with one
  `docker compose up` (`bench/images/sampleapp/docker-compose.yml`).
- **`container stats --format '{{.MemUsage}}'`** is not parseable the way `docker stats`
  is, so per-container steady-RAM is Docker/OrbStack-only here (logged null for Apple,
  not faked).
- **Near-Docker CLI parity otherwise:** `-d`, `-v`, `--mount`, `--network`, `-c/-m`,
  multi-stage `build --target`, `inspect`, `--rosetta` (x86).

## Results — median of N≥10 (lower = better unless noted)

| Metric | Apple container | Docker Desktop | OrbStack | Apple vs best |
|---|---:|---:|---:|---|
| baseline start→exit (ms) | 1,071 | 394 | **359** | 3.0× slower |
| nginx → HTTP 200 (ms) | 1,095 | **290** | 293 | 3.8× slower |
| postgres → TCP (ms) | 2,081 | **292** | 461 | 7.1× slower |
| stack (Pg+Redis) ready (ms) | 1,963 | 653 | **646** | 3.0× slower |
| spawn 40 containers (ms) | 35,182 | 9,636 | **8,780** | 4.0× slower |
| cold build (ms) | 8,074 | **4,467** | 4,689 | 1.8× slower |
| **cached build (ms)** | **426** | 598 | 844 | **Apple fastest** |
| **CPU sysbench (ev/s, ↑)** | **38,459** | 36,372 | 33,547 | **Apple fastest** |
| bind-mount write (MB/s, ↑) | 32.6 | 96.7 | **548.5** | **16.8× slower** |
| bind-mount write (IOPS, ↑) | 8,337 | 24,754 | **140,404** | 16.8× slower |
| container↔container net (Mbps, ↑) | 11,216 | 52,764 | **84,618** | 7.5× slower |
| postgres steady RAM (MB) | — | 21 | 20 | (Apple unmeasured) |
| **idle footprint (MB)** | **51** | 1,124 | 1,631 | **22–32× smaller** |

> Density: all three reached the **cap of 40** (gentle-on-host guard) without failure,
> so the differentiator is *spawn time*, not a true ceiling. Apple's per-VM model makes
> 40 containers take ~35 s vs ~9 s — finding the real ceiling is future work.

## The story (confirmed at N≥10)

- **Apple `container` wins:** idle footprint (**22–32× smaller** — no resident VM),
  CPU-bound work (slight edge — per-VM adds no compute tax), and **cached builds**.
- **Apple `container` loses everywhere it creates or does I/O:** every startup/latency
  metric (3–7×), **bind-mount I/O (~17× vs OrbStack)**, container↔container networking
  (~7×), cold builds (1.8×), and container spawn time (4×) — all consequences of one
  lightweight VM per container.
- **OrbStack is the all-round speed pick** — fastest startup, *crushes* bind-mount I/O
  and networking — and keeps Compose + the docker CLI. Its cost is the **largest idle
  footprint** and the slowest cached build.
- **Docker Desktop sits in the middle** on most axes and remains the ecosystem default
  (Compose, DevContainers, broadest tooling).

### Decision framing for the article
- **Reach for Apple `container`** when you run **few long-lived containers** and care
  about isolation + idle footprint (e.g., a couple of always-on services on a laptop).
- **Avoid it** for the classic **mount-your-source-and-hot-reload** dev loop (bind-mount
  I/O is ~17× behind) and for **Compose-heavy multi-service** stacks (no native Compose).
- **OrbStack** is the low-friction "fast Docker" that keeps your existing workflow.
- **Docker Desktop** when you need the full ecosystem (DevContainers, broadest support).
