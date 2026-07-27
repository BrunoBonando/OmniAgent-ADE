//! Empirical reproduction for the "ingestion makes the UI feel slow" bug
//! report: two separate `Store::open()` connections to the *same on-disk*
//! `brain.db` (this only reproduces on-disk — `:memory:` databases are each
//! connection's own private storage and never contend), one doing a
//! long-ish write loop (simulating `ingest_project`'s per-node/edge
//! upserts), the other doing simple reads concurrently (simulating a
//! UI-facing command like `brain_query`/`map_graph`).
//!
//! Run against the code as it exists at any given commit:
//!   cargo run -p brain-core --example concurrency_repro --release
//!
//! Prints: total writer wall-clock, count of successful vs. failed
//! (SQLITE_BUSY / other error) reads, and the max/percentile read latency —
//! the three numbers that distinguish "fine", "blocked with errors", and
//! "blocked but silently slow".

use brain_core::{now_ts, Node, NodeKind, Origin, Store};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const WRITE_COUNT: usize = 4000;

fn main() {
    let dir = tempfile::tempdir().expect("tempdir");
    let data_dir = dir.path().to_path_buf();

    // Seed the project node up front so the reader has something to find
    // from the very first poll.
    {
        let store = Store::open(&data_dir).expect("seed open");
        store
            .upsert_node(&Node {
                id: "repro".into(),
                kind: NodeKind::Project,
                project: "repro".into(),
                label: "repro".into(),
                path: None,
                summary: None,
                origin: Origin::Extracted,
                updated: now_ts(),
            })
            .expect("seed upsert");
    }

    let writer_done = Arc::new(AtomicBool::new(false));
    let writer_dir = data_dir.clone();
    let writer_done_for_writer = writer_done.clone();

    // Simulates `ingest_roots_in_background`'s write loop: thousands of
    // individual upsert_node calls, each its own connection.execute() call
    // (as `Store::upsert_node` does today, before any batching fix).
    let writer = std::thread::spawn(move || {
        let store = Store::open(&writer_dir).expect("writer open");
        let start = Instant::now();
        for i in 0..WRITE_COUNT {
            store
                .upsert_node(&Node {
                    id: format!("repro:file{i}.ts"),
                    kind: NodeKind::File,
                    project: "repro".into(),
                    label: format!("file{i}.ts"),
                    path: Some(format!("file{i}.ts")),
                    summary: None,
                    origin: Origin::Extracted,
                    updated: now_ts(),
                })
                .expect("upsert_node");
        }
        writer_done_for_writer.store(true, Ordering::SeqCst);
        start.elapsed()
    });

    // Give the writer a head start so it's actually mid-flight once the
    // reader starts polling.
    std::thread::sleep(Duration::from_millis(20));

    let reader_dir = data_dir.clone();
    let reader = std::thread::spawn(move || {
        let store = Store::open(&reader_dir).expect("reader open");
        let mut latencies: Vec<Duration> = Vec::new();
        let mut errors: Vec<String> = Vec::new();
        while !writer_done.load(Ordering::SeqCst) {
            let t0 = Instant::now();
            // Simulates a UI-facing read command (brain_query / map_graph /
            // settings_get all boil down to a `Store` read like this).
            match store.list_projects() {
                Ok(_) => latencies.push(t0.elapsed()),
                Err(e) => errors.push(e.to_string()),
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        (latencies, errors)
    });

    let write_elapsed = writer.join().expect("writer thread panicked");
    let (mut latencies, errors) = reader.join().expect("reader thread panicked");
    latencies.sort();

    println!("=== concurrency_repro ===");
    println!("writer: {WRITE_COUNT} upsert_node calls in {write_elapsed:?}");
    println!(
        "reader: {} successful reads, {} failed reads (SQLITE_BUSY or other error)",
        latencies.len(),
        errors.len()
    );
    if !errors.is_empty() {
        println!("first error: {}", errors[0]);
        let busy = errors
            .iter()
            .filter(|e| e.contains("locked") || e.contains("busy"))
            .count();
        println!(
            "of which look like a lock/busy error: {busy}/{}",
            errors.len()
        );
    }
    if let Some(max) = latencies.last() {
        println!("reader max latency: {max:?}");
    }
    if !latencies.is_empty() {
        let p50 = latencies[latencies.len() / 2];
        println!("reader p50 latency: {p50:?}");
    }
    let over_100ms = latencies.iter().filter(|d| d.as_millis() > 100).count();
    println!("reader reads over 100ms: {over_100ms}");
    let over_1s = latencies.iter().filter(|d| d.as_millis() > 1000).count();
    println!("reader reads over 1s: {over_1s}");
}
