"""Benchmark the bridge's hot request paths against the real Hermes home.

Measures what one phone actually costs the bridge per poll tick and per
screen refresh: the bot list, the merged first page and a cursor page of the
chat inbox, and title search. Run with the same Python the bridge runs under:

    python3 Benchmarks/request_path.py
"""
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge

EXCLUDE = ("cron", "oneshot", "subagent", "tool")


def bench(name, fn, n=30):
    fn()  # warm any caches so the comparison is steady-state, including the 6s page cache
    samples = []
    for _ in range(n):
        start = time.perf_counter()
        out = fn()
        samples.append(1000 * (time.perf_counter() - start))
    samples.sort()
    unit = {"session_page": "chats"}.get(name, "")
    print(f"{name}: n={len(samples)} median={statistics.median(samples):.2f}ms "
          f"p95={samples[int(n * 0.95) - 1]:.2f}ms p99={samples[int(n * 0.99) - 1]:.2f}ms "
          f"rows={len(out) if isinstance(out, list) else '-'}")


def run():
    pids = bridge.profile_ids()
    print(f"profiles: {len(pids)} ({', '.join(pids)})")
    bench("bots()", lambda: bridge.bots())
    bench("all_sessions(first)", lambda: bridge.all_sessions(40, None, None, EXCLUDE, False, True))
    bench("session_page(first)", lambda: bridge.session_page(40, None, None, EXCLUDE, False, True))
    page = bridge.session_page(40, None, None, EXCLUDE, False, True)
    cursor = page["next"]
    bench("session_page(cursor)", lambda: bridge.session_page(40, cursor, None, EXCLUDE, False, True))
    token = bridge.make_token("bench")
    bench("token_claims(valid)", lambda: bridge.token_claims(token), n=200)
    bench("token_claims(bad sig)", lambda: bridge.token_claims(
        "hm2.eyJleHAiOjMzMzAwMDAwMDAsImRldiI6ImJlbmNoIiwiZGlkIjoiMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwIiwibWV0aG9kIjoicGFzc3dvcmQifQ.sig"), n=200)
    bench("search_sessions()", lambda: bridge.search_sessions("the"))


if __name__ == "__main__":
    run()
