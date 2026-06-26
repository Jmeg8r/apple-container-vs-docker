#!/usr/bin/env python3
# WHAT: Turn aggregated stats into PNG charts ready to drop into the Substack article.
# WHY:  Markdown tables render badly on Substack (ASTGL house rule) — the deliverable
#       is always PNG graphics, grouped-bar per metric with runtimes side by side.
# DEPS: matplotlib (see analysis/requirements.txt)
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
STATS = ROOT / "results" / "stats.json"
CHARTS = ROOT / "results" / "charts"

# Stable colors per runtime so every chart in the article is visually consistent.
COLORS = {
    "apple-container": "#0a84ff",
    "docker-desktop": "#2496ed",
    "orbstack": "#f24e1e",
}

# Metric direction. Throughput/count metrics are higher-better; everything else
# (latencies, memory, build times) is lower-better. Keeps chart captions honest.
HIGHER_BETTER = ("_per_sec", "_mbps", "_iops", "max_containers", "_count")


def better_label(metric):
    return "higher is better" if metric.endswith(HIGHER_BETTER) or "max_" in metric \
        else "lower is better"


def main():
    CHARTS.mkdir(parents=True, exist_ok=True)
    data = json.loads(STATS.read_text())["stats"]

    # Group rows by (scenario, metric) → {runtime: median}
    grouped = {}
    for row in data:
        grouped.setdefault((row["scenario"], row["metric"]), {})[row["runtime"]] = row

    for (scenario, metric), by_rt in sorted(grouped.items()):
        runtimes = list(by_rt.keys())
        medians = [by_rt[r]["median"] for r in runtimes]
        p95s = [by_rt[r]["p95"] for r in runtimes]
        errs = [max(0, p - m) for m, p in zip(medians, p95s)]  # whisker to p95

        fig, ax = plt.subplots(figsize=(7, 4.2))
        ax.bar(runtimes, medians, yerr=errs, capsize=6,
               color=[COLORS.get(r, "#888") for r in runtimes])
        ax.set_title(f"{scenario} — {metric}\n(median, whisker = p95; {better_label(metric)})")
        ax.set_ylabel(metric)
        ax.spines[["top", "right"]].set_visible(False)
        fig.tight_layout()
        out = CHARTS / f"{scenario}__{metric}.png"
        fig.savefig(out, dpi=160)
        plt.close(fig)
        print(f"chart → {out}")


if __name__ == "__main__":
    main()
