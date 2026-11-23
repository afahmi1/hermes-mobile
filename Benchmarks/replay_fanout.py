"""Compare the old SSE handler with bounded, shared replay frames on synthetic turns.

python3 Benchmarks/replay_fanout.py [--http]
Without --http measure publication + fanout into memory. With --http run concurrent
localhost readers against prefilled turns, including connection setup, HTTP, and SSE
delivery; no Hermes, iOS, authentication or model provider participates.

Wall/CPU medians exclude verification. Every trial verifies the sequence of every reader.
"""
from concurrent.futures import ThreadPoolExecutor
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import statistics
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
from bridge_turns import Turn

EVENTS = 2000


def publish(shared):
    turn = Turn("default", Path("."), "benchmark", "", {})
    turn.id = "turn_" + "0" * 32
    old = []
    for seq in range(EVENTS):
        delta = "sample-%05d " % seq + ("x" * 72)
        if shared:
            turn.push("message.delta", delta=delta)
        else:
            with turn.cond:
                old.append({"event": "message.delta", "seq": seq, "turn_id": turn.id,
                            "session_id": turn.sid, "timestamp": time.time(), "delta": delta})
                turn.cond.notify_all()
    turn.finish()
    return turn, old


def deliver(shared, turn, old, write):
    if shared:
        offset = 0
        while offset < EVENTS:
            frames, offset, _, gap = turn.replay(offset, 0)
            assert not gap
            write(b"".join(frames))
    else:
        with turn.cond:
            batch = old[:]
        for event in batch:
            write(("id: %d\ndata: %s\n\n" % (event["seq"], json.dumps(event))).encode())


def times():
    return time.perf_counter(), time.process_time()


def measure(readers, shared, http_mode):
    if not http_mode:
        wall, cpu = times()
        turn, old = publish(shared)
        captures = [bytearray() for _ in range(readers)]
        for capture in captures:
            deliver(shared, turn, old, capture.extend)
        end, end_cpu = times()
    else:
        turn, old = publish(shared)

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                deliver(shared, turn, old, self.wfile.write)

            def log_message(self, fmt, *args):
                pass

        class Server(ThreadingHTTPServer):
            request_queue_size = 128

        with Server(("127.0.0.1", 0), Handler) as server:
            serve = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
            serve.start()
            ready = threading.Barrier(readers + 1)
            go = threading.Event()

            def read():
                client = http.client.HTTPConnection(*server.server_address, timeout=30)
                ready.wait()
                go.wait()
                try:
                    client.request("GET", "/events")
                    response = client.getresponse()
                    assert response.status == 200
                    return response.read()
                finally:
                    client.close()

            try:
                with ThreadPoolExecutor(max_workers=readers) as pool:
                    jobs = [pool.submit(read) for _ in range(readers)]
                    ready.wait()
                    wall, cpu = times()
                    go.set()
                    captures = [f.result() for f in jobs]
                    end, end_cpu = times()
            finally:
                server.shutdown()
                serve.join()
    duplicate_ids = 0
    for capture in captures:
        ids = [int(frame[4:frame.index(b"\n")]) for frame in capture.split(b"\n\n") if frame]
        duplicate_ids += len(ids) - len(set(ids))
        assert ids == list(range(EVENTS))
    return end - wall, end_cpu - cpu, sum(map(len, captures)), duplicate_ids


if __name__ == "__main__":
    http_mode = "--http" in sys.argv
    print("readers encoder wall_ms cpu_ms bytes duplicates")
    for n in (1, 10, 50):
        for shared in (False, True):
            samples = [measure(n, shared, http_mode) for _ in range(3 if http_mode else 5)]
            wall, cpu, size, duplicates = map(statistics.median, zip(*samples))
            print(n, "shared" if shared else "previous", round(wall*1000, 2), round(cpu*1000, 2),
                  int(size), int(duplicates), flush=True)
