// Loopback-only, single-turn protocol experiment. Input is newline-delimited Hermes events.
use std::{
    collections::VecDeque,
    convert::Infallible,
    io,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use axum::{
    body::{Body, Bytes},
    extract::State,
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use serde_json::Value;
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    sync::watch,
};

const BYTE_LIMIT: usize = 2 * 1024 * 1024;
const AGE_LIMIT: Duration = Duration::from_secs(600);

#[derive(Default)]
struct Journal {
    frames: VecDeque<(Instant, Bytes)>,
    head: u64,
    bytes: usize,
    closed: bool,
}

impl Journal {
    fn trim(&mut self, now: Instant) {
        while self.frames.front().is_some_and(|(when, _)| {
            self.bytes > BYTE_LIMIT || now.duration_since(*when) >= AGE_LIMIT
        }) {
            self.bytes -= self.frames.pop_front().unwrap().1.len();
        }
    }

    fn append(&mut self, raw: &str) -> io::Result<()> {
        let event: Value = serde_json::from_str(raw)?;
        if event["seq"].as_u64() != Some(self.head) || event["event"].as_str().is_none() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "expected contiguous numbered events",
            ));
        }
        let frame = Bytes::from(format!("id: {}\ndata: {}\n\n", self.head, raw));
        self.bytes += frame.len();
        self.head += 1;
        let now = Instant::now();
        self.frames.push_back((now, frame));
        self.trim(now);
        Ok(())
    }

    fn batch(&mut self, next: u64) -> Option<(Vec<Bytes>, bool)> {
        self.trim(Instant::now());
        let first = self.head - self.frames.len() as u64;
        if next < first || next > self.head {
            return None;
        }
        let start = (next - first) as usize;
        let stop = (start + 128).min(self.frames.len());
        Some((
            self.frames
                .range(start..stop)
                .map(|(_, bytes)| bytes.clone())
                .collect(),
            self.closed && stop == self.frames.len(),
        ))
    }
}

#[derive(Clone)]
struct Feed {
    journal: Arc<Mutex<Journal>>,
    changes: watch::Sender<()>,
}

async fn events(State(feed): State<Feed>, headers: HeaderMap) -> Response {
    let mut next = 0;
    if let Some(id) = headers.get("last-event-id") {
        let Some(cursor) = id
            .to_str()
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .and_then(|n| n.checked_add(1))
        else {
            return StatusCode::BAD_REQUEST.into_response();
        };
        next = cursor;
    }
    let mut changes = feed.changes.subscribe();
    let initial = feed.journal.lock().unwrap().batch(next);
    let Some(batch) = initial else {
        return StatusCode::GONE.into_response();
    };
    let stream = async_stream::stream! {
        let mut batch = batch;
        loop {
            let (frames, end) = batch;
            let empty = frames.is_empty();
            if !empty {
                next += frames.len() as u64;
                let mut payload = Vec::with_capacity(frames.iter().map(Bytes::len).sum());
                for frame in frames { payload.extend_from_slice(&frame); }
                yield Ok::<_, Infallible>(Bytes::from(payload));
            }
            if end { break; }
            if empty && tokio::time::timeout(Duration::from_secs(15), changes.changed()).await.is_err() {
                yield Ok(Bytes::from_static(b": keepalive\n\n"));
            }
            let result = feed.journal.lock().unwrap().batch(next);
            match result { Some(more) => batch = more, None => break }
        }
    };
    let mut response = Body::from_stream(stream).into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/event-stream"),
    );
    response
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> io::Result<()> {
    let feed = Feed {
        journal: Arc::new(Mutex::new(Journal::default())),
        changes: watch::channel(()).0,
    };
    let input = feed.clone();
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Err(err) = input.journal.lock().unwrap().append(&line) {
                eprintln!("Invalid fixture: {err}");
                std::process::exit(2);
            }
            input.changes.send_replace(());
        }
        input.journal.lock().unwrap().closed = true;
        input.changes.send_replace(());
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    println!("{}", listener.local_addr()?.port());
    axum::serve(
        listener,
        Router::new().route("/events", get(events)).with_state(feed),
    )
    .await
}
