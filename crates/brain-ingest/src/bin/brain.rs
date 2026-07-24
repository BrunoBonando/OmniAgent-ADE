//! `brain`: local CLI over the OmniAgent ADE knowledge graph (Task 2.3).
//! `brain ingest <root>` / `brain search <query>` / `brain stats`.
//!
//! Data dir resolution honors `OMNIAGENT_ADE_DATA_DIR` (see
//! `brain_core::Store::default_data_dir`), so
//! `OMNIAGENT_ADE_DATA_DIR=/tmp/ade-test brain ingest ~/code` never touches
//! the real `~/Library/Application Support/OmniAgent-ADE`.

use anyhow::Result;
use brain_core::Store;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "brain",
    version,
    about = "OmniAgent ADE local knowledge graph CLI"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Ingest every project found under root (immediate subdirs with .git
    /// or >=3 source files each become one project).
    Ingest {
        root: PathBuf,
        /// After the initial ingest, keep watching and re-ingest changed
        /// projects incrementally (Ctrl-C to stop).
        #[arg(long)]
        watch: bool,
    },
    /// Full-text search over node labels/summaries.
    Search {
        query: String,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// Print project/node counts for the whole brain.
    Stats,
    /// Drain pending enrichment jobs (project/community summaries) through
    /// the user's own `claude` CLI, headless. Offline or missing CLI: prints
    /// 0 drained, exits 0 — jobs stay queued for next time.
    Drain,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let data_dir = Store::default_data_dir();
    let store = Store::open(&data_dir)?;

    match cli.command {
        Command::Ingest { root, watch } => {
            let projects = brain_ingest::discover_projects(&root);
            if projects.is_empty() {
                println!("no projects found under {}", root.display());
                return Ok(());
            }

            let mut total = brain_ingest::IngestStats::default();
            for (name, path) in &projects {
                let stats = brain_ingest::ingest_project(&store, path, name)?;
                println!(
                    "  {name}: {} files, {} entities, {} edges, {} communities",
                    stats.files, stats.entities, stats.edges, stats.communities
                );
                total.files += stats.files;
                total.entities += stats.entities;
                total.edges += stats.edges;
                total.communities += stats.communities;
            }
            println!(
                "ingested {} project(s) under {}: {} files, {} entities, {} edges, {} communities",
                projects.len(),
                root.display(),
                total.files,
                total.entities,
                total.edges,
                total.communities
            );

            if watch {
                println!("watching for changes (Ctrl-C to stop)...");
                brain_ingest::watch::watch_roots(&store, &projects, 2_000)?;
            }
        }
        Command::Search { query, limit } => {
            let hits = store.search(&query, None, limit)?;
            if hits.is_empty() {
                println!("no matches for {query:?}");
            }
            for hit in hits {
                println!(
                    "{}\t{:?}\t{}\t{}",
                    hit.project,
                    hit.kind,
                    hit.label,
                    hit.path.unwrap_or_default()
                );
            }
        }
        Command::Stats => {
            let projects = store.list_projects()?;
            println!("projects: {}", projects.len());
            let mut total_nodes = 0usize;
            for p in &projects {
                let nodes = store.nodes_for_project(&p.project)?;
                total_nodes += nodes.len();
                println!("  {} ({}): {} nodes", p.label, p.project, nodes.len());
            }
            println!("total nodes across all projects: {total_nodes}");
        }
        Command::Drain => {
            let engine = brain_ingest::enrich::ClaudeEngine;
            let done = brain_ingest::enrich::drain_queue(&store, &data_dir, &engine)?;
            println!("drained {done} job(s)");
        }
    }
    Ok(())
}
