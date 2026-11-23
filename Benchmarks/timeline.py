"""Generate the same latest-100 history request from a synthetic 2,000-row thread in a 10,000-chat fleet.
Pass an output directory to save both synthetic pages for a native decoder benchmark.
"""
import json
from pathlib import Path
import sqlite3
import statistics
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
from hermes_mobile_bridge import timeline_page


def fixture(db):
    db.execute("CREATE TABLE sessions(id INTEGER PRIMARY KEY, last_active INTEGER)")
    db.execute("CREATE INDEX latest_chats ON sessions(last_active DESC)")
    db.executemany("INSERT INTO sessions VALUES(?,?)", ((i, i) for i in range(10000)))
    db.execute("CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id INTEGER, role TEXT, content TEXT, reasoning TEXT, tool_calls TEXT)")
    db.execute("CREATE INDEX history ON messages(session_id,id)")
    roles = ("user", "assistant", "tool", "assistant")
    for i in range(2000):
        role = roles[i % 4]
        content = "output " * 1800 if role == "tool" else f"Visible text {i}"
        reasoning = "working " * 600 if role == "assistant" else None
        calls = json.dumps([{"function": {"name": "search", "arguments": "argument " * 150}}]) if i % 4 == 1 else None
        db.execute("INSERT INTO messages VALUES(?,?,?,?,?,?)", (i, 9999, role, content, reasoning, calls))
    db.commit()
    rows = [dict(row) for row in db.execute("SELECT * FROM messages WHERE session_id=9999 ORDER BY id DESC LIMIT 100")][::-1]
    for row in rows:
        if row["tool_calls"]:
            row["tool_calls"] = json.loads(row["tool_calls"])
    return json.dumps({"data": rows}).encode()


def run():
    with sqlite3.connect(":memory:") as db:
        db.row_factory = sqlite3.Row
        raw = fixture(db)
    samples = []
    for _ in range(30):
        start = time.perf_counter()
        small = timeline_page(raw)
        samples.append(1000 * (time.perf_counter() - start))
    print(f"100 rows rich={len(raw)} bytes timeline={len(small)} bytes "
          f"unchanged_body=0 bytes projection_median={statistics.median(samples):.2f}ms")
    if len(sys.argv) == 2:
        out = Path(sys.argv[1])
        out.mkdir(exist_ok=True)
        (out / "raw.json").write_bytes(raw)
        (out / "timeline.json").write_bytes(small)


if __name__ == "__main__":
    run()
