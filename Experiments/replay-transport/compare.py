"""Compare previously published SSE backlogs over HTTP using the same turn and resume cursor.

Run with the path to the release-built hermes-replay-probe. The only input is synthetic.
"""
from concurrent.futures import ThreadPoolExecutor
import contextlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import statistics
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Bridge"))
from bridge_turns import Turn


def request(port, cursor):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    try:
        start = time.perf_counter()
        conn.request("GET", "/events", headers={"Last-Event-ID": str(cursor)})
        response = conn.getresponse()
        if response.status != 200:
            raise ValueError(response.status)
        first = response.read(1)
        first_ms = (time.perf_counter() - start) * 1000
        body = first + response.read()
        return body, first_ms
    finally:
        conn.close()


def measure(name, port, count, expected, pid):
    for readers in (1, 10, 50):
        elapsed, first = [], []
        with ThreadPoolExecutor(max_workers=readers) as workers:
            for _ in range(5):
                start = time.perf_counter()
                futures = [workers.submit(request, port, count // 2 - 1) for _ in range(readers)]
                rows = [future.result() for future in futures]
                elapsed.append((time.perf_counter() - start) * 1000)
                for body, ms in rows:
                    if body != expected:
                        raise ValueError("Replay bytes differ")
                    first.append(ms)
        rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)])) / 1024
        print(f"{name} readers={readers} batch_ms={statistics.median(elapsed):.1f} "
              f"first_byte_ms={statistics.median(first):.1f} rss_MiB={rss:.1f} gateway_calls=0", flush=True)


def reference():
    turn = Turn("default", Path("."), "fixture", "", {})
    turn.id = "fixture-turn"
    for line in sys.stdin:
        ev = json.loads(line)
        # Construct the exact payload that was supplied to the alternative implementation.
        turn.push(ev["event"], delta=ev["delta"])
    turn.finish()
    # Supply the canonical serialization (includes the publisher timestamp) to the comparison process.
    for ev in turn.events:
        print(json.dumps(ev, ensure_ascii=False, separators=(",", ":")))
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            offset = int(self.headers["Last-Event-ID"]) + 1
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            while True:
                batch, offset, done, gap = turn.replay(offset)
                if gap:
                    raise ValueError("unexpected checkpoint")
                self.wfile.write(b"".join(batch))
                if done:
                    return
        def log_message(self, *args):
            pass
    class Server(ThreadingHTTPServer):
        request_queue_size = 128
    with Server(("127.0.0.1", 0), Handler) as server:
        print(server.server_port, flush=True)
        server.serve_forever()


@contextlib.contextmanager
def child(command):
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        yield process
    finally:
        process.terminate()
        process.wait()


def main():
    count = 2000
    with child([sys.executable, __file__, "--reference"]) as py, child([sys.argv[1]]) as rust:
        for seq in range(count):
            py.stdin.write(json.dumps({"event": "message.delta", "delta": "x" * 96}) + "\n")
        py.stdin.close()
        canonical = [py.stdout.readline() for _ in range(count)]
        py_port = int(py.stdout.readline())
        rust.stdin.writelines(canonical)
        rust.stdin.close()
        rs_port = int(rust.stdout.readline())
        expected, _ = request(py_port, count // 2 - 1)
        ids = [int(line[4:]) for line in expected.splitlines() if line.startswith(b"id: ")]
        assert ids == list(range(count // 2, count))
        measure("python", py_port, count, expected, py.pid)
        measure("rust", rs_port, count, expected, rust.pid)


if __name__ == "__main__":
    reference() if sys.argv[1] == "--reference" else main()
