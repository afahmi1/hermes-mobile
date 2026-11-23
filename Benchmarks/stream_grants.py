"""Compare one stream-monitor tick using a private, disposable SQLite registry."""
import statistics
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
from bridge_devices import Devices


def measure(fn):
    samples = []
    for _ in range(41):
        start = time.perf_counter_ns()
        assert fn()
        samples.append((time.perf_counter_ns() - start) / 1e6)
    return statistics.median(samples[1:])


with tempfile.TemporaryDirectory() as directory:
    registry = Devices(Path(directory))
    now = int(time.time())
    claims = [dict(did=str(i), dev="Fixture", issued=now, exp=now + 600, method="local")
              for i in range(50)]
    for claim in claims:
        registry.issue(claim)
    for count, devices in ((1, 1), (10, 2), (50, 2), (50, 50)):
        streams = [claims[i % devices] for i in range(count)]
        expected = {c["did"] for c in streams}
        old = measure(lambda: all(registry.accepts(c, "") for c in streams))
        new = measure(lambda: registry.permitted(c["did"] for c in streams) == expected)
        print(f"{count} streams, {devices} devices: {old:.3f} -> {new:.3f} ms median")
