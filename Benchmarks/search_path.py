"""Compare the mobile title/message search before and after the trigram-index switch.

Runs the same query twice against the installed Hermes state.db files: once through the
legacy LIKE scan, once through Hermes's own messages_fts_trigram index. Every pair is
checked for identical profile/session results before a timing is reported.

    HERMES_HOME=~/.hermes python3 Benchmarks/search_path.py
    python3 Benchmarks/search_path.py --json

The bridge only reads state.db. Queries are fixed strings; no chat content is printed.
"""
import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge

TERMS = ("kubernetes", "video", "hermes", "the", "refactor", "permission", "grafana", "sqlite")
ROUNDS = 12


def timed(fn):
    samples = []
    for _ in range(ROUNDS):
        start = time.perf_counter()
        out = fn()
        samples.append(1000 * (time.perf_counter() - start))
    samples.sort()
    return {"p50": statistics.median(samples),
            "p95": samples[min(len(samples) - 1, int(len(samples) * 0.95))],
            "rows": len(out), "results": [(r.get("profile"), r.get("id")) for r in out]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", help="emit machine-readable results")
    args = parser.parse_args()

    rows = []
    for term in TERMS:
        # Warm both paths once so the comparison measures the query, not page-cache warmup.
        bridge.search_sessions(term, prefer_fts=False)
        bridge.search_sessions(term, prefer_fts=True)
        old = timed(lambda: bridge.search_sessions(term, prefer_fts=False))
        new = timed(lambda: bridge.search_sessions(term, prefer_fts=True))
        same = old["results"] == new["results"]
        rows.append({"term": term, "same": same, "legacy_p50_ms": old["p50"],
                     "indexed_p50_ms": new["p50"], "legacy_p95_ms": old["p95"],
                     "indexed_p95_ms": new["p95"],
                     "speedup": old["p50"] / new["p50"] if new["p50"] else None,
                     "rows": new["rows"]})

    if args.json:
        print(json.dumps({"rounds": ROUNDS, "terms": rows}, indent=2))
        return 0 if all(r["same"] for r in rows) else 1

    print(f"profiles: {len(bridge.profile_ids())}, rounds: {ROUNDS}")
    print("term        rows  legacy p50/p95   indexed p50/p95   speedup  results")
    for r in rows:
        speed = "%.1fx" % r["speedup"] if r["speedup"] else "-"
        print("%-11s %4d  %7.2f/%7.2f  %8.2f/%7.2f  %7s  %s" % (
            r["term"], r["rows"], r["legacy_p50_ms"], r["legacy_p95_ms"],
            r["indexed_p50_ms"], r["indexed_p95_ms"], speed,
            "same" if r["same"] else "DIFFERENT"))
    legacy = statistics.median(r["legacy_p50_ms"] for r in rows)
    indexed = statistics.median(r["indexed_p50_ms"] for r in rows)
    print("median across terms: %.2f ms -> %.2f ms (%.1fx)" % (legacy, indexed, legacy / indexed))
    return 0 if all(r["same"] for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
