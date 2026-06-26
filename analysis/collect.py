#!/usr/bin/env python3
# WHAT: Aggregate raw JSONL results into per-(scenario, runtime, metric) stats.
# WHY:  A single run lies. We report median + p95 + stdev over the recorded reps,
#       with the warmup rep discarded, so the article quotes distributions not luck.
import json
import sys
from pathlib import Path
from statistics import median, pstdev

RAW = Path(__file__).resolve().parent.parent / "results" / "raw"
OUT = Path(__file__).resolve().parent.parent / "results" / "stats.json"


def percentile(values, p):
    """Nearest-rank percentile; values need not be pre-sorted."""
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, round((p / 100) * (len(s) - 1))))
    return s[k]


def main():
    # series[(scenario, runtime, metric)] = [values...]
    series, skips = {}, []
    for f in sorted(RAW.glob("*.jsonl")):
        for line in f.read_text().splitlines():
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec.get("status") == "skipped":
                skips.append({"scenario": rec["scenario"], "runtime": rec["runtime"],
                              "reason": rec.get("reason", "")})
                continue
            if rec.get("kind") == "warmup":          # discard warmup
                continue
            for metric, value in (rec.get("metrics") or {}).items():
                if isinstance(value, (int, float)):
                    series.setdefault((rec["scenario"], rec["runtime"], metric), []).append(value)

    stats = []
    for (scenario, runtime, metric), vals in sorted(series.items()):
        stats.append({
            "scenario": scenario, "runtime": runtime, "metric": metric,
            "n": len(vals),
            "median": median(vals),
            "p95": percentile(vals, 95),
            "stdev": pstdev(vals) if len(vals) > 1 else 0.0,
            "min": min(vals), "max": max(vals),
        })

    OUT.write_text(json.dumps({"stats": stats, "skipped": skips}, indent=2))
    print(f"{len(stats)} stat rows, {len(skips)} skips → {OUT}")
    if skips:
        print("SKIPPED (logged, not hidden):", file=sys.stderr)
        for s in skips:
            print(f"  {s['scenario']}/{s['runtime']}: {s['reason']}", file=sys.stderr)


if __name__ == "__main__":
    main()
