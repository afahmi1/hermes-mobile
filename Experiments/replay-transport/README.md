# Hermes replay transport experiment

This loopback-only Axum/Tokio process accepts one synthetic turn as newline-delimited JSON on standard input and serves SSE from an ephemeral port. It has a 2 MiB, ten-minute replay window, monotonic cursors, batched writes, keepalives, and an explicit expired-cursor response on connection. The Python fixture uses the shipped Turn implementation. Neither process contacts a gateway. Do not route a phone or real transcript to the experimental listener. It has no authentication, approval checkpoint, admission journal, or production deployment path.

From the project root on macOS or Linux:

```sh
cargo build --locked --release --manifest-path Experiments/replay-transport/Cargo.toml
python3 Experiments/replay-transport/compare.py Experiments/replay-transport/target/release/hermes-replay-probe
```

The driver publishes 2,000 synthetic deltas, reconnects halfway through, checks every response against the canonical bytes, and reports five-trial median batch time, median time to first byte, and resident process memory. RSS includes each language runtime. The client runs separately. Compare 1, 10 and 50 readers. The shipping bridge keeps the Python gateway adapter and uses shared wire frames. A switch to Rust still requires authenticated live ingestion, protocol parity across process loss, and operational testing.
