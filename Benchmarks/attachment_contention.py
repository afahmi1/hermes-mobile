"""Time an unrelated live-turn lookup during a real, fsynced 4 MiB attachment admission."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from statistics import median
import sys
from tempfile import TemporaryDirectory
import threading
from time import perf_counter
from unittest.mock import patch
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", type=Path, default=Path(__file__).resolve().parents[1] / "Bridge")
    args = parser.parse_args()
    sys.path.insert(0, str(args.bridge))
    import bridge_turns as turns

    attachment = dict(filename="sample.mp3", mime="audio/mpeg",
                      base64=base64.b64encode(b"x" * (4 * 1024 * 1024)).decode())
    stage = turns.bridge_media.stage
    entered = threading.Event()

    def observed_stage(frames, home):
        entered.set()
        return stage(frames, home)

    samples = []
    with TemporaryDirectory() as tmp, ThreadPoolExecutor(max_workers=1) as pool, \
            patch.object(turns.bridge_media, "stage", observed_stage), \
            patch.object(turns.asyncio, "run_coroutine_threadsafe", side_effect=lambda coro, loop: coro.close()):
        home = Path(tmp)
        other = turns.start_turn("default", home, "other", "hi", {})
        for trial in range(32):
            entered.clear()
            future = pool.submit(turns.start_primary, "default", home, str(trial), "audio", {}, uuid.uuid4(),
                                 None, home, lambda: None, None, [attachment])
            assert entered.wait(timeout=10)
            start = perf_counter()
            assert turns.get_turn(other.id) is other
            samples.append(1000 * (perf_counter() - start))
            turns.bridge_media.discard(future.result().media)
    print("Unrelated lookup ms, 31 measured runs after warmup:",
          "median", round(median(samples[1:]), 3), "p95", round(sorted(samples[1:])[29], 3))


if __name__ == "__main__":
    main()
