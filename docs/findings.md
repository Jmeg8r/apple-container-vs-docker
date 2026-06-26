# Findings log

Two kinds of finding live here:
1. **Behavioral facts** — verified by hand during harness development. These are
   stable and quotable in the article *now*.
2. **Preliminary numbers** — from 1-rep smoke runs while validating scenarios. They
   show the harness produces meaningful signal, but the article must quote the real
   **N≥10** run, not these.

Reference rig: M3 Ultra / 256 GB / macOS 26.5.1. Apple `container` 1.0.0, Docker
Desktop 29.3.1, OrbStack 2.2.1.

## Behavioral facts (verified)

- **Apple `container` requires fully-qualified image refs.** `container run alpine`
  fails; `container run docker.io/library/alpine:3.20` works. Docker/OrbStack resolve
  bare names. (A migration friction for existing Dockerfiles/scripts.)
- **Apple `container` does not reliably publish ports to localhost.** `-p 18080:80` on
  nginx left `127.0.0.1:18080` closed, yet the container was serving on its own
  routable IP (`192.168.64.x:80` → 200). Postgres's published port *did* open — so the
  behavior is inconsistent. **The reliable interface is the container's IP**, which
  every container gets directly (Apple's design intent). Docker/OrbStack use the
  familiar published-localhost-port model.
- **`localhost` vs `127.0.0.1` matters.** Polling `http://localhost:PORT` can resolve
  to IPv6 `::1` first; use `127.0.0.1` for IPv4 services.
- **No native Compose on Apple `container`.** Standing up Postgres+Redis is a manual
  `network create` + N×`run` sequence (3 commands in scenario 7). Docker/OrbStack do it
  with one `docker compose up` against `bench/images/sampleapp/docker-compose.yml`. The
  3rd-party `container-compose` bridge (installed) is the partial workaround to test.
- **`container stats --format '{{.MemUsage}}'`** did not yield a parseable value the way
  `docker stats` does — per-container steady-RAM is currently Docker/OrbStack only in
  the harness (logged as null for Apple, not faked).
- **Apple `container` has near-Docker CLI parity** for the harness's needs: `-d`, `-v`,
  `--mount`, `--network`, `-c/-m` limits, multi-stage `build --target`, `inspect`,
  `--rosetta` (x86), `network create`.

## Preliminary smoke numbers (1 rep — NOT the article's data)

| Metric | Apple container | Docker Desktop | OrbStack |
|---|---|---|---|
| baseline start→exit (warm) | ~876 ms | ~272 ms | ~275 ms |
| nginx → HTTP 200 | ~768 ms | — | ~318 ms |
| postgres → TCP | ~1805 ms | — | ~292 ms |
| sysbench CPU (ev/s, higher=better) | 39,330 | — | 40,126 |
| fio bind-mount write (MB/s, higher=better) | **37.7** | — | **770** |
| iperf3 c↔c (Mbps, higher=better) | ~10,376 | — | ~91,546 |
| build cold / cached (ms) | 7251 / 365 | — | 4517 / 812 |
| stack ready (Pg+Redis) | ~1656 ms | — | ~472 ms |
| density (cap=8 smoke) time | 5649 ms | — | 1411 ms |
| **idle helper RAM** | **154 MB** | 1115 MB | 1782 MB |

### Early shape of the story (to be confirmed at N≥10)
- **Apple wins:** idle footprint (~7–11× smaller — no resident VM).
- **Apple ties:** CPU-bound work (per-VM model adds no compute tax).
- **Apple loses:** warm start latency, **bind-mount I/O (~20×)**, container↔container
  network (~9×), cold build — all consequences of one-VM-per-container.
- **DX gaps:** no Compose, no port-publish-to-localhost convention, FQ-ref requirement.

> The bind-mount result is the one to nail down: if confirmed, it means Apple
> `container` is a poor fit for the classic "mount your source tree and hot-reload"
> dev loop — exactly what many Mac developers do all day.
