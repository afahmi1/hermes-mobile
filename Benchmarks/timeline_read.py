"""Compare gateway serialization and early projection, checking identical mobile bytes.
Run in the installed Hermes environment with python Benchmarks/timeline_read.py.
"""
import json
import sqlite3
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge

def samples(fn, n=30):
    fn()
    out = None
    taken = []
    for _ in range(n):
        start = time.perf_counter()
        out = fn()
        taken.append(1000 * (time.perf_counter() - start))
    taken.sort()
    return out, statistics.median(taken), taken[int(n * 0.95) - 1]


def main():
    db_path = bridge.profile_home("default") / "state.db"
    con = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    sid = con.execute(
        "SELECT session_id FROM messages WHERE active=1 GROUP BY session_id "
        "ORDER BY sum(length(coalesce(content,'')) + length(coalesce(reasoning,'')) "
        "+ length(coalesce(tool_calls,''))) DESC LIMIT 1").fetchone()[0]
    from contextlib import closing
    from hermes_state import SessionDB
    from gateway.platforms.api_server import APIServerAdapter
    con.close()

    def wide():
        with closing(SessionDB(db_path, read_only=True)) as db:
            assert db.get_session(sid)
            resolved = db.resolve_resume_session_id(sid)
            rows = db.get_messages(resolved, limit=100, offset=0, latest=True,
                                   include_compacted=False, include_ancestors=True)
            return json.dumps({"data": [APIServerAdapter._message_response(row) for row in rows]}).encode()

    wide_body = wide()
    projected, wide_p50, wide_p95 = samples(lambda: bridge.timeline_page(wide()))
    native_body, native_p50, native_p95 = samples(
        lambda: bridge.native_timeline_page("default", sid, 100, 0, True))
    print(f"gateway-shaped: median={wide_p50:.2f}ms p95={wide_p95:.2f}ms bytes={len(wide_body)}")
    if native_body is None:
        print("native timeline: refused (lineage or schema); gateway path unchanged")
        return
    print(f"native timeline: median={native_p50:.2f}ms p95={native_p95:.2f}ms bytes={len(native_body)}")
    print(f"speedup={wide_p50 / native_p50:.1f}x payload={len(wide_body) / len(native_body):.1f}x smaller")
    assert projected == native_body, "Fast and gateway transcript projections differ"
    same = json.loads(projected)["data"] == json.loads(native_body)["data"]
    print(f"same_rows_as_gateway_projection={same} projected_bytes={len(projected)}")


if __name__ == "__main__":
    main()
