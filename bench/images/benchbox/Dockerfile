# Shared micro-benchmark image: CPU (sysbench), disk (fio), network (iperf3).
# Reused by scenarios 03/04/05 so the workload binaries are identical across runtimes.
# Built per-runtime by `just build-images` (each runtime has its own image store).
FROM docker.io/library/ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      sysbench fio iperf3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Default to something harmless; scenarios override the command.
CMD ["sleep", "infinity"]
